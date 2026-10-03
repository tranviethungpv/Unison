import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the phone itself has to offer that the rest does not know how to get.
@MainActor
protocol PlatformServices: AnyObject {
    /// What the person called this phone in its settings, or its model.
    var deviceName: String { get }
    var deviceModel: String { get }

    /// On mobile data (or not knowing): songs are not fetched without asking.
    var isMetered: Bool { get }

    /// The phone is warm or saving power: the screen should move less and work nobody waits for is put off.
    var calm: StateFlow<Bool> { get }

    /// Where the sound goes now: the phone's speaker, headphones, a Bluetooth device, AirPlay.
    var output: StateFlow<AudioOutput> { get }

    /// Opens the system's list of places to play to.
    func pickOutput()

    /// Opens the share sheet with [text].
    func share(_ text: String)

    /// Saves [contents] to a file the person picks. False when they backed out.
    func exportFile(name: String, contents: String) async throws -> Bool

    /// The text of a file the person picks; nil when they backed out.
    func importFile() async throws -> String?

    /// Runs [work] and asks the system to let it finish if the app goes to the background meanwhile.
    func whileInBackground(_ work: @escaping () async -> Void) async
}

/// Where the sound goes. [kind] is `speaker`, `headphones`, `bluetooth`, `airplay`, `car` or `other`; [name] is what the
/// device calls itself, and is empty for the phone's own speaker.
struct AudioOutput: Equatable {
    var kind: String
    var name: String
}

/// What went wrong with a command, as the UI is told: [code] is stable, [message] is for a person.
struct BridgeError: Error, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

/// Everything the Flutter UI can ask of the native side, and the stream of room state it gets back. The player and the
/// room connection live in [GroupController]; this only steers and observes them.
@MainActor
final class Bridge {
    private let controller: GroupController
    private let prefs: KeyValueStore
    private let platform: PlatformServices
    private let store: LibraryStore
    private let resolver: StreamResolver
    private let streams: StreamCache
    private let music: MusicFeed
    private let suggestions: SuggestionFeed
    private let media: MediaLibrary
    private let files: MediaFiles
    private let downloader: Downloader
    private let http: HTTPClient
    private let time: TimeSource
    private let scope = Scope()

    private var sink: ((String) -> Void)?
    private var observing: Scope?
    private var visible = false

    /// An invitation that arrived before the UI was listening.
    private var pendingInvite: String?
    private var pendingSetup: String?

    /// Last structure of the room sent, so an unchanged room is not sent again.
    private var lastState: String?
    private var lastStructure: GroupController.View?

    /// The library changed while the screen was off; the UI is told when it comes back.
    private var libraryDirty = false

    private var lastRenew: Int64 = 0
    private var draining: [Bool: Job] = [:]
    private var drainAgain: Set<Bool> = []
    private var calmSubscription: Subscription?
    private var outputSubscription: Subscription?

    init(controller: GroupController, prefs: KeyValueStore, platform: PlatformServices, store: LibraryStore, resolver: StreamResolver,
         streams: StreamCache, music: MusicFeed, suggestions: SuggestionFeed, media: MediaLibrary, files: MediaFiles,
         downloader: Downloader, http: HTTPClient, time: TimeSource? = nil) {
        self.controller = controller
        self.prefs = prefs
        self.platform = platform
        self.store = store
        self.resolver = resolver
        self.streams = streams
        self.music = music
        self.suggestions = suggestions
        self.media = media
        self.files = files
        self.downloader = downloader
        self.http = http
        self.time = time ?? SystemTime.shared
        // The screen slows its small moving parts down while the phone is warm
        calmSubscription = platform.calm.observe { [weak self] calm in
            guard let self, self.visible else { return }
            self.emit(UiJson.calm(calm))
        }
        outputSubscription = platform.output.observe { [weak self] output in
            guard let self, self.visible else { return }
            self.emit(UiJson.output(output))
        }
    }

    private var settings: ServerConfig { ServerConfig.load(prefs) }
    private var autoDownload: Bool { prefs.bool(Self.keyAutoDownload, default: false) }
    private var language: String { prefs.string("language") ?? "en" }
    private var videoHeight: Int { Int(prefs.int64("video_height") ?? 720) }

    // ------------------------------------------------------------------ lifecycle

    /// The library changed: the screen reads it again when it looks.
    func libraryChanged() {
        if visible { emit(UiJson.library()) } else { libraryDirty = true }
    }

    func setVisible(_ value: Bool) {
        if value {
            lastState = nil // a UI that just came back wants the full picture again
            lastStructure = nil
            if libraryDirty {
                libraryDirty = false
                emit(UiJson.library())
            }
            emit(UiJson.calm(platform.calm.value))
            emit(UiJson.output(platform.output.value))
            for avatar in controller.picturesSeen() { emit(UiJson.avatar(avatar)) }
            controller.resumeRoom()
            // A phone that was in a pocket may have lost the connection without noticing
            controller.networkChanged(changed: false)
            renewSuggestionsIfDue()
            if autoDownload { kickDownloads(waiting: true) }
        }
        visible = value
        controller.setUiVisible(value)
        if value {
            emitState()
            emitPosition()
        }
    }

    /// Handles an invitation, `sapoche://join/CODE` or the https link of the server's invitation page, and a setup link,
    /// `sapoche://setup?server=…&key=…`, which another phone shows as a QR code; anything else is ignored. The screen
    /// checks a setup link and asks before using it.
    func onLink(_ url: URL) {
        if url.scheme == "sapoche" && url.host == "setup" {
            let link = url.absoluteString
            if sink != nil { emit(UiJson.setup(link)) } else { pendingSetup = link }
            return
        }
        let own = url.scheme == "sapoche" && url.host == "join"
        let host = URL(string: settings.server)?.host
        let web = url.scheme == "https" && host != nil && url.host == host && url.pathComponents.dropFirst().first == "join"
        guard own || web else { return }
        let code = url.lastPathComponent.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.inviteCode(code) else { return }
        if sink != nil { emit(UiJson.invite(code)) } else { pendingInvite = code }
    }

    /// Brings the suggestions up to date when the person opens the app, at most twice an hour and not on a metered
    /// connection: they are shown from what was kept, so there is no hurry and no reason to spend data.
    private func renewSuggestionsIfDue() {
        let now = time.nowMs()
        if lastRenew != 0 && now - lastRenew < Self.renewEveryMs { return }
        if platform.isMetered || platform.calm.value { return }
        lastRenew = now
        let suggestions = suggestions
        scope.launch { _ = try? await suggestions.renew(force: false) }
    }

    // ------------------------------------------------------------------ state stream

    func start(sink: @escaping (String) -> Void) {
        self.sink = sink
        lastState = nil
        lastStructure = nil
        if let code = pendingInvite {
            pendingInvite = nil
            emit(UiJson.invite(code))
        }
        if let link = pendingSetup {
            pendingSetup = nil
            emit(UiJson.setup(link))
        }
        emit(UiJson.calm(platform.calm.value))
        emit(UiJson.output(platform.output.value))
        observing?.cancel()
        let observing = Scope()
        self.observing = observing
        observing.collect(controller.view) { [weak self] _ in self?.emitStateIfChanged() }
        observing.collect(controller.errors) { [weak self] error in self?.emit(UiJson.error(code: error.code, message: error.message)) }
        observing.collect(controller.notices) { [weak self] notice in self?.emit(UiJson.notice(notice)) }
        // A screen that starts listening is told the pictures that came while nobody looked
        for avatar in controller.picturesSeen() { emit(UiJson.avatar(avatar)) }
        observing.collect(controller.avatars) { [weak self] avatar in
            guard let self, self.visible else { return }
            self.emit(UiJson.avatar(avatar))
        }
        observing.collect(controller.sleep.state) { [weak self] state in self?.emit(UiJson.sleep(state)) }
        // Play, pause and seek should show at once instead of at the next tick
        observing.collect(controller.playerChanged) { [weak self] _ in self?.emitPosition() }
        observing.launch { [weak self] in
            // No ticking at all while the screen is off, and none while the song stands still: a pause, a seek or a
            // song that ends is pushed at once by `playerChanged`, and a screen that comes back is told where things are
            while let self {
                if self.controller.playerInfo().playing { self.emitPosition() }
                guard await self.time.wait(ms: Self.positionTickMs) else { return }
            }
        }
        emitState()
        emitPosition()
    }

    func stop() {
        sink = nil
        observing?.cancel()
        observing = nil
    }

    private func emit(_ json: String) {
        sink?(json)
    }

    private func emitPosition() {
        guard visible, sink != nil else { return }
        emit(UiJson.position(controller.view.value, controller.playerInfo()))
    }

    /// Drift and speed change every half second and are not part of the state; and nothing is built or sent while the
    /// screen is off, the UI catches up when it returns.
    private func emitStateIfChanged() {
        guard visible, sink != nil else { return }
        var structure = controller.view.value
        structure.snapshot.driftMs = nil
        structure.snapshot.speed = 1
        if structure == lastStructure { return }
        lastStructure = structure
        emitState()
    }

    private func emitState() {
        guard sink != nil else { return }
        let state = UiJson.state(controller.view.value, trimMs: controller.trimMs, video: controller.videoMode, videoHeight: videoHeight)
        if state == lastState { return }
        lastState = state
        emit(state)
    }

    // ------------------------------------------------------------------ commands

    func handle(_ method: String, _ args: [String: Any]) async throws -> Any? {
        func string(_ key: String) -> String { args[key] as? String ?? "" }
        func bool(_ key: String) -> Bool { args[key] as? Bool == true }
        func int(_ key: String) -> Int { JSON(args[key]).int ?? 0 }
        func int64(_ key: String) -> Int64 { JSON(args[key]).int64 ?? 0 }
        func tracks(_ key: String = "tracks") -> [TrackRef] {
            (args[key] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(TrackRef.init(map:)) }
        }
        func track(_ map: [String: Any]?) throws -> TrackRef {
            guard let map, let found = TrackRef(map: map) else { throw BridgeError(code: "failed", message: "Not a song") }
            return found
        }

        switch method {
        case "profile":
            let name = prefs.string(Self.keyRoomName) ?? String(platform.deviceName.prefix(Self.maxNameChars))
            return [
                "name": name, "device": platform.deviceModel, "trimMs": controller.trimMs, "videoHeight": videoHeight,
                "server": settings.server, "autoplay": controller.autoplayOn, "configured": settings.isSet, "key": !settings.key.isEmpty,
            ] as [String: Any]
        case "configure":
            // What is left out stays as it was
            var config = settings
            if let server = args["server"] as? String { config.server = ServerConfig.clean(server) }
            if let key = args["key"] as? String { config.key = key.trimmingCharacters(in: .whitespacesAndNewlines) }
            config.save(to: prefs)
            return nil
        case "cacheFolder":
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
        case "smooth", "updateCheck", "updateAllowInstalls":
            return nil // the display and updates are the system's business on iOS
        case "updateDownload", "updateInstall":
            return nil
        case "pickOutput":
            platform.pickOutput()
            return nil
        case "setLanguage":
            prefs.set(string("code").isEmpty ? "en" : string("code"), for: "language")
            return nil
        case "setAutoplay":
            controller.autoplayOn = bool("on")
            return nil
        case "forYou":
            return try await suggestions.forYou().map { $0.toMap() }
        case "discover":
            return try await suggestions.discover().map { $0.toMap() }
        case "contextMix":
            let mix = try await suggestions.contextMix()
            return ["bucket": mix.bucket, "tracks": mix.tracks.map { $0.toMap() }] as [String: Any]
        case "block":
            // A song is blocked by its video id, an artist by the name of the first artist credited
            if bool("artistOnly") {
                try await store.block(kind: SuggestionFeed.artist, key: Taste.artistKey(string("artist")), label: Taste.artistLabel(string("artist")))
            } else {
                try await store.block(kind: SuggestionFeed.song, key: string("videoId"), label: string("title"))
            }
            return nil
        case "unblock":
            try await store.unblock(kind: string("kind"), key: string("key"))
            return nil
        case "blocked":
            return try await store.blocked().map { ["kind": $0.kind, "key": $0.key, "label": $0.label] as [String: Any] }
        case "refreshSuggestions":
            _ = try await suggestions.renew(force: true)
            return try await suggestions.forYou().map { $0.toMap() }
        case "seedLists":
            return try await suggestions.seedLists().map { ["seed": $0.seed, "tracks": $0.tracks.map { $0.toMap() }] as [String: Any] }
        case "musicTrending":
            return MusicJson.shelves(try await music.trending(language))
        case "musicSearch":
            return try await music.search(string("query"), songs: bool("songs")).map(MusicJson.track)
        case "musicNext":
            return MusicJson.next(try await music.watchNext(string("videoId")))
        case "musicRelated":
            return MusicJson.related(try await music.related(string("videoId")))
        case "musicArtist":
            return MusicJson.artist(try await music.artist(string("id")))
        case "musicSearchPage":
            return MusicJson.searchPage(try await music.searchPage(string("query"), params: args["params"] as? String))
        case "musicSearchMore":
            return MusicJson.searchPage(try await music.searchMore(string("token")))
        case "musicCollection":
            return MusicJson.collection(try await music.collection(string("id")))
        case "musicMore":
            return MusicJson.continuation(try await music.more(string("token")))
        case "lyrics":
            return MusicJson.lyrics(try await music.lyrics(videoId: string("videoId"), title: string("title"), artist: string("artist"),
                                                           durationSec: int64("durMs") / 1000))
        case "suggest":
            return await suggest(string("query"))
        case "searchPlaylists":
            return try await searchPlaylists(string("query"))
        case "search":
            return try await search(string("query"), songsOnly: bool("songsOnly"))
        case "lookup":
            return try await lookup(string("text"))
        case "roomInfo":
            return await roomInfo(string("code"))
        case "libraryLiked":
            return try await store.liked().map { $0.track.toMap() }
        case "libraryRecent":
            return try await store.recent().map { $0.track.toMap().merging(["at": $0.at, "plays": $0.plays]) { $1 } }
        case "libraryLike":
            let on = bool("on")
            try await store.setLiked(try track(args), on)
            if on && autoDownload { kickDownloads(waiting: true) }
            return nil
        case "libraryClearHistory":
            try await store.clearHistory()
            return nil
        case "downloads":
            return try await store.downloads().map { $0.track.toMap().merging(["state": $0.state, "bytes": $0.bytes]) { $1 } }
        case "download":
            // Songs the person asked for go on any network, but mobile data is asked about first
            if platform.isMetered && !bool("allowMetered") { return "metered" }
            try await store.requestDownloads(tracks())
            kickDownloads(waiting: false)
            return "queued"
        case "downloadRemove":
            let videoId = string("videoId")
            try await store.removeDownload(videoId)
            files.removeDownload(videoId)
            return nil
        case "downloadClear":
            try await store.clearDownloads()
            files.clearDownloads()
            return nil
        case "storage":
            let done = try await store.downloads().filter { $0.state == LibraryStore.done }.count
            return [
                "playBytes": files.playBytes(), "playLimitMb": Int(prefs.int64(Self.keyCacheLimit) ?? Self.defaultCacheMb),
                "downloadBytes": files.downloadBytes(), "downloadCount": done, "autoDownload": autoDownload,
            ] as [String: Any]
        case "clearPlayCache":
            files.clearPlay()
            return nil
        case "setCacheLimit":
            let mb = int64("mb") > 0 ? int64("mb") : Self.defaultCacheMb
            prefs.set(mb, for: Self.keyCacheLimit)
            files.setPlayLimit(mb * 1024 * 1024)
            return nil
        case "setAutoDownload":
            prefs.set(bool("on"), for: Self.keyAutoDownload)
            if bool("on") { kickDownloads(waiting: true) } else { draining[true]?.cancel() }
            return nil
        case "playlists":
            return try await store.playlists().map {
                ["id": $0.id, "name": $0.name, "count": $0.count, "thumb": $0.thumb ?? NSNull(), "updatedAt": $0.updatedAt] as [String: Any]
            }
        case "playlistTracks":
            return try await store.playlistTracks(int64("id")).map { $0.toMap() }
        case "playlistCreate":
            return try await store.createPlaylist(string("name"), tracks())
        case "playlistRename":
            try await store.renamePlaylist(int64("id"), string("name"))
            return nil
        case "playlistDelete":
            try await store.deletePlaylist(int64("id"))
            return nil
        case "playlistAdd":
            return try await store.addToPlaylist(int64("id"), tracks())
        case "playlistRemove":
            try await store.removeFromPlaylist(int64("id"), string("videoId"))
            return nil
        case "playlistMove":
            try await store.movePlaylistItem(int64("id"), string("videoId"), toIndex: int("to"))
            return nil
        case "backupExport":
            return try await exportBackup()
        case "backupImport":
            return try await importBackup()
        case "share":
            platform.share(string("text"))
            return nil
        case "log":
            return EventLog.shared.snapshot()
        case "note":
            EventLog.d("ui", string("line"))
            return nil
        default:
            break
        }

        switch method {
        case "createRoom":
            let code = try await createRoom()
            controller.join(code: code, name: string("name"), create: true)
            return code
        case "join":
            guard settings.isSet else { throw BridgeError(code: "not_configured", message: "Set the server first") }
            controller.join(code: string("code").trimmingCharacters(in: .whitespaces).uppercased(), name: string("name"), create: false)
        case "leave":
            controller.leave()
        case "sleep":
            switch string("mode") {
            case "time": controller.sleep.startIn(minutes: int("minutes"))
            case "song": controller.sleep.startAtSongEnd()
            default: controller.sleep.cancel()
            }
        case "setAvatar":
            controller.setAvatar(args["data"] as? String)
        case "rename":
            controller.rename(string("name").trimmingCharacters(in: .whitespacesAndNewlines))
        case "setTrim":
            controller.setTrim(int64("ms"))
            // The trim is part of the state the UI shows, but the room itself did not change
            lastState = nil
            emitState()
        case "videoMode":
            controller.setVideoMode(bool("on"))
            // The mode is part of the state the UI shows, but the room itself did not change
            lastState = nil
            emitState()
        case "videoVisible":
            controller.setVideoVisible(bool("visible"))
        case "videoSurface":
            do {
                return try controller.videoSurface()
            } catch {
                throw BridgeError(code: "unavailable", message: error.localizedDescription)
            }
        case "videoQuality":
            prefs.set(int64("height") > 0 ? int64("height") : 720, for: "video_height")
            lastState = nil
            emitState()
        case "solo":
            try requireRoom()
            if bool("on") { controller.goSolo() } else { controller.rejoin() }
        case "keepPlaying":
            try requireRoom()
            controller.keepPlaying()
        case "kick":
            try requireRoom()
            controller.requestKick(string("id"))
        case "roomName":
            try requireRoom()
            controller.requestRoomName(string("name"))
        case "roomSettings":
            try requireRoom()
            controller.requestRoomSettings(string("guestControl"))
        case "play": controller.requestPlay()
        case "pause": controller.requestPause()
        case "next": controller.requestNext()
        case "prev": controller.requestPrev()
        case "seek": controller.requestSeek(int64("ms"))
        case "jump": controller.requestJump(string("id"))
        case "clear": controller.requestClearQueue()
        case "shuffle": controller.requestShuffle()
        case "radio": controller.requestRadio(string("videoId"))
        case "repeat": controller.requestRepeat(string("mode"))
        case "addMany": controller.requestAddMany(tracks(), playNext: bool("next"))
        case "swap": controller.requestSwap(string("id"), try track(args["track"] as? [String: Any]))
        case "remove": controller.requestRemove(string("id"))
        case "move": controller.requestMove(string("id"), int("to"))
        case "add": controller.requestAddMany([try track(args)], playNext: bool("next"))
        default:
            throw BridgeError(code: "failed", message: "Unknown command \(method)")
        }
        return nil
    }

    private func requireRoom() throws {
        if !controller.isActive { throw GroupController.NoRoom() }
    }

    // ------------------------------------------------------------------ rooms

    /// What the server says about a room before joining it; nil when it cannot be reached.
    private func roomInfo(_ code: String) async -> [String: Any]? {
        let clean = code.trimmingCharacters(in: .whitespaces).uppercased()
        let config = settings
        guard Self.inviteCode(clean), config.isSet, let url = URL(string: "\(config.server)/room/\(clean)/info") else { return nil }
        var request = URLRequest(url: url)
        config.authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let reply = try? await http.send(request), (200..<300).contains(reply.status), let json = JSON.parse(data: reply.data) else { return nil }
        return [
            "exists": json.at("exists").bool ?? false, "name": json.at("name").string ?? NSNull(), "members": json.at("members").int ?? 0,
            "playing": json.at("playing").bool ?? false, "title": json.at("title").string ?? NSNull(),
        ]
    }

    private func createRoom() async throws -> String {
        let config = settings
        guard config.isSet, let url = URL(string: "\(config.server)/rooms") else {
            throw BridgeError(code: "not_configured", message: "Set the server first")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        config.authHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let reply = try await http.send(request)
        guard (200..<300).contains(reply.status) else {
            throw BridgeError(code: "failed", message: reply.status == 401 ? "The server turned the key down" : "The server answered \(reply.status)")
        }
        guard let code = JSON.parse(data: reply.data)?.at("code").string else { throw BridgeError(code: "failed", message: "The server gave no room code") }
        return code
    }

    // ------------------------------------------------------------------ search

    private func search(_ query: String, songsOnly: Bool) async throws -> [[String: Any]] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return try await resolver.search(query.trimmingCharacters(in: .whitespaces), limit: Self.searchLimit, songsOnly: songsOnly).map { $0.toMap() }
    }

    /// Completions of a half-typed search; empty when YouTube cannot be reached, since they are only a help.
    private func suggest(_ query: String) async -> [String] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let found = try? await resolver.suggest(query.trimmingCharacters(in: .whitespaces))
        return Array((found ?? []).prefix(Self.suggestionLimit))
    }

    private func searchPlaylists(_ query: String) async throws -> [[String: Any]] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return try await resolver.searchPlaylists(query.trimmingCharacters(in: .whitespaces), limit: Self.searchLimit).map {
            ["id": $0.id, "title": $0.title, "uploader": $0.uploader, "thumb": $0.thumbUrl ?? NSNull(), "count": $0.songCount] as [String: Any]
        }
    }

    /// Turns pasted text into tracks: a playlist link gives its songs, a video link (or a bare video id) gives one song,
    /// anything else gives nil.
    private func lookup(_ text: String) async throws -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = YoutubeLinks.playlistId(trimmed) {
            let playlist = try await resolver.playlist(id, limit: Self.playlistLimit)
            return ["title": playlist.title, "tracks": playlist.tracks.map { $0.toMap() }]
        }
        guard let id = YoutubeLinks.videoId(trimmed) else { return nil }
        return ["title": NSNull(), "tracks": [try await streams.track(id).toMap()]]
    }

    // ------------------------------------------------------------------ downloads

    /// Works through the songs on the list, in the background of the app when it has to be. Asking while a run is going
    /// on makes it look again at the end, so what was added meanwhile is not left behind.
    private func kickDownloads(waiting: Bool) {
        if draining[waiting]?.isActive == true {
            drainAgain.insert(waiting)
            return
        }
        let downloader = downloader
        let store = store
        let platform = platform
        draining[waiting] = scope.launch { [weak self] in
            var tries = 0
            while let self {
                // Liked songs saved by themselves: not on mobile data, and not while the phone is warm, they can wait
                if waiting {
                    if self.platform.isMetered || self.platform.calm.value || !self.autoDownload { return }
                    try await store.requestDownloads(try await store.likedToDownload(), waiting: true)
                }
                var result = Downloader.Result(done: 0, retryLater: false)
                await platform.whileInBackground {
                    result = (try? await downloader.drain(waiting: waiting)) ?? result
                }
                EventLog.d("download", "run done: \(result.done) songs\(result.retryLater ? ", some to try again" : "")")
                if self.drainAgain.remove(waiting) != nil { continue }
                if result.retryLater && tries < Self.downloadRetries {
                    guard await self.time.wait(ms: Self.downloadRetryMs << Int64(tries)) else { return }
                    tries += 1
                    continue
                }
                return
            }
        }
    }

    // ------------------------------------------------------------------ backup

    private func exportBackup() async throws -> [String: Any]? {
        let backup = try await store.backup()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let text = LibraryBackup.toJson(backup, at: now)
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        guard try await platform.exportFile(name: "sapoche-library-\(day.string(from: Date())).json", contents: text) else { return nil }
        return ["liked": backup.liked.count, "playlists": backup.playlists.count, "listens": backup.listens.count]
    }

    private func importBackup() async throws -> [String: Any]? {
        guard let text = try await platform.importFile() else { return nil }
        if text.utf8.count > Self.maxBackupBytes { throw BridgeError(code: "failed", message: "Too big to be a Sapoche backup") }
        let backup: LibraryStore.Backup
        do {
            backup = try LibraryBackup.fromJson(text)
        } catch {
            throw BridgeError(code: "failed", message: error.localizedDescription)
        }
        let restored = try await store.restore(backup)
        if restored.liked > 0 && autoDownload { kickDownloads(waiting: true) }
        return ["liked": restored.liked, "playlists": restored.playlists, "listens": restored.listens]
    }

    // ------------------------------------------------------------------ helpers

    static func inviteCode(_ text: String) -> Bool {
        text.count == 6 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    private static let keyAutoDownload = "auto_download"
    private static let keyCacheLimit = "cache_limit_mb"
    private static let keyRoomName = "room_name"
    private static let defaultCacheMb: Int64 = 256

    /// The longest name the UI lets a person type.
    private static let maxNameChars = 24
    private static let positionTickMs: Int64 = 1000
    private static let searchLimit = 20
    private static let suggestionLimit = 6
    private static let playlistLimit = 50
    private static let renewEveryMs: Int64 = 30 * 60_000
    private static let downloadRetries = 3
    private static let downloadRetryMs: Int64 = 60_000
    private static let maxBackupBytes = 16 * 1024 * 1024
}

extension TrackInfo {
    fileprivate func toMap() -> [String: Any] {
        ["videoId": videoId, "title": title, "artist": artist, "thumb": thumbUrl ?? NSNull(), "durMs": durationSec * 1000]
    }
}
