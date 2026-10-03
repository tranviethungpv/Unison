import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SapocheCore

@MainActor
final class FakePlatform: PlatformServices {
    var deviceName = "Test phone"
    var deviceModel = "iPhone"
    var isMetered = false
    let calm = StateFlow<Bool>(false)
    let output = StateFlow<AudioOutput>(AudioOutput(kind: "speaker", name: ""))
    var outputPicked = 0
    var shared: [String] = []
    var exported: [(String, String)] = []
    var toImport: String?

    func pickOutput() { outputPicked += 1 }

    func share(_ text: String) { shared.append(text) }

    func exportFile(name: String, contents: String) async throws -> Bool {
        exported.append((name, contents))
        return true
    }

    func importFile() async throws -> String? { toImport }

    func whileInBackground(_ work: @escaping () async -> Void) async { await work() }
}

@MainActor
final class FakeSocket: Socket {
    var sent: [String] = []
    var cancelled = false
    let events: SocketEvents
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String], events: SocketEvents) {
        self.url = url
        self.headers = headers
        self.events = events
    }

    func send(_ text: String) -> Bool {
        sent.append(text)
        return true
    }

    func cancel() { cancelled = true }
    func close(code: Int, reason: String) { cancelled = true }

    /// What the server does.
    func open() { events.socketOpened() }
    func receive(_ text: String) { events.socketMessage(text) }
}

@MainActor
final class FakeSockets: SocketFactory {
    var opened: [FakeSocket] = []

    func open(url: URL, headers: [String: String], events: SocketEvents) -> Socket {
        let socket = FakeSocket(url: url, headers: headers, events: events)
        opened.append(socket)
        return socket
    }
}

final class FakeResolver: StreamResolver, @unchecked Sendable {
    var results: [TrackInfo] = [TrackInfo(videoId: "vid00000001", title: "Found", artist: "Someone", thumbUrl: nil, durationSec: 200)]
    var asked: [String] = []

    func search(_ query: String, limit: Int, songsOnly: Bool) async throws -> [TrackInfo] {
        asked.append("search \(query) songs=\(songsOnly)")
        return results
    }

    func resolve(_ videoId: String) async throws -> Resolved {
        let track = TrackInfo(videoId: videoId, title: "Resolved \(videoId)", artist: "A", thumbUrl: nil, durationSec: 200)
        let source = AudioSource(url: "https://example.invalid/\(videoId)", mimeType: "audio/mp4", bitrateKbps: 128, contentLength: 10, itag: 140)
        return Resolved(track: track, best: source, all: [source], userAgent: "test-agent")
    }

    func searchPlaylists(_ query: String, limit: Int) async throws -> [PlaylistRef] {
        [PlaylistRef(id: "PLabc", title: "Mix", uploader: "Me", thumbUrl: nil, songCount: 3)]
    }

    func playlist(_ playlistId: String, limit: Int) async throws -> Playlist {
        Playlist(title: "Listed", tracks: results)
    }

    func related(_ videoId: String, limit: Int) async throws -> [TrackInfo] { results }
    func suggest(_ query: String) async throws -> [String] { ["\(query) one", "\(query) two"] }
}

/// Writes ten bytes wherever it is asked to, like a transfer that worked.
struct FakeFetcher: FileFetcher {
    func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
        try Data(repeating: 7, count: 10).write(to: file)
        return 10
    }
}

@MainActor
final class BridgeTests: XCTestCase {
    private var time: VirtualTime!
    private var dir: URL!
    private var engine: FakePlayer!
    private var platform: FakePlatform!
    private var sockets: FakeSockets!
    private var prefs: MemoryStore!
    private var controller: GroupController!
    private var bridge: Bridge!
    private var resolver: FakeResolver!
    private var http: FakeHTTP!
    private var events: [[String: Any]] = []
    private var libraryChanges = Counter()

    override func setUp() async throws {
        time = VirtualTime()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakePlayer(time: time)
        platform = FakePlatform()
        sockets = FakeSockets()
        prefs = MemoryStore()
        resolver = FakeResolver()
        http = FakeHTTP()
        events = []
        let changes = libraryChanges
        let store = try LibraryStore(path: ":memory:", onChange: { [weak self] in
            changes.bump()
            Task { @MainActor in self?.bridge?.libraryChanged() }
        })
        let streams = StreamCache(resolver: resolver)
        let files = MediaFiles(downloadsDir: dir.appendingPathComponent("d"), playDir: dir.appendingPathComponent("p"), playLimitBytes: 1 << 20)
        let media = MediaLibrary(files: files, streams: streams, fetcher: FakeFetcher())
        let music = MusicFeed(music: MusicClient { _, _ in JSON.parse("{}")! }, lyricsClient: LyricsClient { _ in nil }, lyricsStore: LyricsStore(dir: dir.appendingPathComponent("l")))
        let suggestions = SuggestionFeed(store: store, resolver: resolver, music: music)
        let downloader = Downloader(store: store, fetch: { try await media.download($0) })
        let prefs = prefs!
        controller = GroupController(engine: engine, prefs: prefs, queueFile: QueueFile(url: dir.appendingPathComponent("queue.json")),
                                     config: { ServerConfig.load(prefs) }, time: time, sockets: sockets)
        bridge = Bridge(controller: controller, prefs: prefs, platform: platform, store: store, resolver: resolver, streams: streams,
                        music: music, suggestions: suggestions, media: media, files: files, downloader: downloader, http: http, time: time)
        bridge.start { [weak self] text in
            if let object = JSON.parse(text)?.object { self?.events.append(object) }
        }
        bridge.setVisible(true)
    }

    override func tearDown() async throws {
        bridge.stop()
        controller.release()
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ method: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await bridge.handle(method, args)
    }

    /// The answer to a command, as the kind of value the screen expects.
    private func result<T>(_ method: String, _ args: [String: Any] = [:], as type: T.Type) async throws -> T {
        let answer = try await bridge.handle(method, args)
        return try XCTUnwrap(answer as? T, "\(method) gave \(String(describing: answer))")
    }

    private func song(_ n: Int) -> [String: Any] {
        ["videoId": "video00000\(n)", "title": "Song \(n)", "artist": "Artist", "thumb": NSNull(), "durMs": 200_000]
    }

    private func states() -> [[String: Any]] { events.filter { $0["type"] as? String == "state" } }

    /// Lets the library and the other actors answer.
    private func settle() async {
        for _ in 0..<20 {
            await time.settle()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testTheProfileTellsWhatTheUIAsksFor() async throws {
        let profile = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(profile["name"] as? String, "Test phone")
        XCTAssertEqual(profile["device"] as? String, "iPhone")
        XCTAssertEqual(profile["autoplay"] as? Bool, true)
        XCTAssertEqual(profile["configured"] as? Bool, false)
        XCTAssertEqual(profile["server"] as? String, "")

        _ = try await call("configure", ["server": " sapoche.example.dev/ "])
        _ = try await call("configure", ["key": "secret"])
        let again = try await result("profile", as: [String: Any].self)
        XCTAssertEqual(again["server"] as? String, "https://sapoche.example.dev")
        XCTAssertEqual(again["configured"] as? Bool, true)
        XCTAssertEqual(again["key"] as? Bool, true)
        XCTAssertNil(again["secret"])
    }

    func testTheFirstStateIsSentWhenTheScreenListens() async throws {
        let first = try XCTUnwrap(states().first)
        XCTAssertEqual(first["phase"] as? String, "idle")
        XCTAssertTrue(first["room"] is NSNull)
        XCTAssertEqual((first["queue"] as? [Any])?.count, 0)
    }

    func testAddingASongOutsideARoomPlaysItAndTellsTheScreen() async throws {
        _ = try await call("add", song(1))
        await time.advance(100)
        XCTAssertEqual(engine.loaded?.title, "Song 1")
        XCTAssertTrue(engine.playing)
        let state = try XCTUnwrap(states().last)
        XCTAssertEqual(state["phase"] as? String, "paused", "outside a room whether it plays is the player's business")
        let queue = try XCTUnwrap(state["queue"] as? [[String: Any]])
        XCTAssertEqual(queue.map { $0["title"] as? String }, ["Song 1"])
        XCTAssertEqual(state["index"] as? Int, 0)
        XCTAssertTrue(state["room"] is NSNull)

        _ = try await call("addMany", ["tracks": [song(2), song(3)], "next": false])
        await time.advance(100)
        let queued = try XCTUnwrap(states().last?["queue"] as? [[String: Any]])
        XCTAssertEqual(queued.count, 3)
        _ = try await call("pause")
        XCTAssertFalse(engine.playing)
        _ = try await call("next")
        await time.advance(100)
        XCTAssertEqual(engine.loaded?.title, "Song 2")
    }

    func testThePositionIsSentWhileTheScreenIsOn() async throws {
        _ = try await call("add", song(1))
        await time.advance(2500)
        let positions = events.filter { $0["type"] as? String == "position" }
        XCTAssertFalse(positions.isEmpty)
        let last = try XCTUnwrap(positions.last)
        XCTAssertEqual(last["playing"] as? Bool, true)
        XCTAssertGreaterThan(JSON(last["positionMs"]).int64 ?? 0, 1000)
        XCTAssertEqual(JSON(last["durationMs"]).int64, 200_000)
    }

    func testTheCacheFolderIsNamed() async throws {
        let folder = try await call("cacheFolder") as? String
        XCTAssertFalse(folder?.isEmpty ?? true)
    }

    func testNoPositionIsSentWhileTheSongStandsStill() async throws {
        _ = try await call("add", song(1))
        await time.advance(1500)
        _ = try await call("pause")
        await time.advance(100)
        let paused = events.filter { $0["type"] as? String == "position" }.count
        await time.advance(5000)
        XCTAssertEqual(events.filter { $0["type"] as? String == "position" }.count, paused)
    }

    func testNothingIsSentWhileTheScreenIsOff() async throws {
        bridge.setVisible(false)
        let before = events.count
        _ = try await call("add", song(1))
        await time.advance(3000)
        XCTAssertEqual(events.count, before)
        bridge.setVisible(true)
        XCTAssertEqual(states().last?["queue"].flatMap { ($0 as? [Any])?.count }, 1, "the screen catches up when it returns")
    }

    func testSearchAndSuggestionsAndLookupGoToYouTube() async throws {
        let found = try await result("search", ["query": " lofi ", "songsOnly": true], as: [[String: Any]].self)
        XCTAssertEqual(found.first?["title"] as? String, "Found")
        XCTAssertEqual(JSON(found.first?["durMs"]).int64, 200_000)
        XCTAssertEqual(resolver.asked, ["search lofi songs=true"])
        let blank = try await call("search", ["query": "  "]) as? [Any]
        XCTAssertEqual(blank?.count, 0)

        let words = try await result("suggest", ["query": "lofi"], as: [String].self)
        XCTAssertEqual(words, ["lofi one", "lofi two"])

        let video = try await result("lookup", ["text": "https://youtu.be/bNp9pn0ni3I"], as: [String: Any].self)
        XCTAssertEqual((video["tracks"] as? [[String: Any]])?.first?["title"] as? String, "Resolved bNp9pn0ni3I")
        let list = try await result("lookup", ["text": "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"], as: [String: Any].self)
        XCTAssertEqual(list["title"] as? String, "Listed")
        let words2 = try await call("lookup", ["text": "just words"])
        XCTAssertNil(words2)
        let lists = try await result("searchPlaylists", ["query": "mix"], as: [[String: Any]].self)
        XCTAssertEqual(lists.first?["id"] as? String, "PLabc")
        XCTAssertEqual(JSON(lists.first?["count"]).int, 3)
    }

    func testLikesHistoryAndPlaylistsAreKeptAndTheScreenIsTold() async throws {
        _ = try await call("libraryLike", song(1).merging(["on": true]) { $1 })
        let liked = try await result("libraryLiked", as: [[String: Any]].self)
        XCTAssertEqual(liked.map { $0["videoId"] as? String }, ["video000001"])
        XCTAssertTrue(events.contains { $0["type"] as? String == "library" })

        let id = try await result("playlistCreate", ["name": "Road", "tracks": [song(1), song(2)]], as: Int64.self)
        _ = try await call("playlistAdd", ["id": id, "tracks": [song(2), song(3)]])
        let tracks = try await result("playlistTracks", ["id": id], as: [[String: Any]].self)
        XCTAssertEqual(tracks.count, 3)
        _ = try await call("playlistMove", ["id": id, "videoId": "video000003", "to": 0])
        _ = try await call("playlistRename", ["id": id, "name": "Trip"])
        let lists = try await result("playlists", as: [[String: Any]].self)
        XCTAssertEqual(lists.first?["name"] as? String, "Trip")
        XCTAssertEqual(lists.first?["count"] as? Int, 3)
        _ = try await call("playlistRemove", ["id": id, "videoId": "video000001"])
        _ = try await call("playlistDelete", ["id": id])
        let none = try await result("playlists", as: [Any].self)
        XCTAssertEqual(none.count, 0)
    }

    func testBackupExportAndImportGoThroughTheFilePicker() async throws {
        _ = try await call("libraryLike", song(1).merging(["on": true]) { $1 })
        let counts = try await result("backupExport", as: [String: Any].self)
        XCTAssertEqual(counts["liked"] as? Int, 1)
        let (name, text) = try XCTUnwrap(platform.exported.first)
        XCTAssertTrue(name.hasPrefix("sapoche-library-") && name.hasSuffix(".json"))
        XCTAssertTrue(text.contains("\"app\":\"sapoche\""))

        platform.toImport = text
        let restored = try await result("backupImport", as: [String: Any].self)
        XCTAssertEqual(restored["liked"] as? Int, 0, "restoring what is already there changes nothing")
        platform.toImport = "not a backup"
        do {
            _ = try await call("backupImport")
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.message, "Not a Sapoche backup")
        }
        platform.toImport = nil
        let cancelled = try await call("backupImport")
        XCTAssertNil(cancelled)
    }

    func testADownloadIsQueuedFetchedAndListed() async throws {
        let answer = try await call("download", ["tracks": [song(1)], "allowMetered": false]) as? String
        XCTAssertEqual(answer, "queued")
        await settle()
        let list = try await result("downloads", as: [[String: Any]].self)
        XCTAssertEqual(list.first?["state"] as? String, "done")
        XCTAssertEqual(JSON(list.first?["bytes"]).int64, 10)
        let storage = try await result("storage", as: [String: Any].self)
        XCTAssertEqual(storage["downloadCount"] as? Int, 1)
        XCTAssertEqual(JSON(storage["downloadBytes"]).int64, 10)
        XCTAssertEqual(storage["playLimitMb"] as? Int, 256)

        _ = try await call("downloadRemove", ["videoId": "video000001"])
        let empty = try await result("downloads", as: [Any].self)
        XCTAssertEqual(empty.count, 0)
    }

    func testMobileDataIsAskedAboutBeforeDownloading() async throws {
        platform.isMetered = true
        let answer = try await call("download", ["tracks": [song(1)], "allowMetered": false]) as? String
        XCTAssertEqual(answer, "metered")
        let forced = try await call("download", ["tracks": [song(1)], "allowMetered": true]) as? String
        XCTAssertEqual(forced, "queued")
    }

    func testTheSleepTimerIsSentToTheScreen() async throws {
        _ = try await call("sleep", ["mode": "time", "minutes": 10])
        let sleeps = events.filter { $0["type"] as? String == "sleep" }
        XCTAssertEqual(sleeps.last?["mode"] as? String, "time")
        XCTAssertNotNil(sleeps.last?["endsAt"] as? Int64)
        _ = try await call("sleep", ["mode": "off"])
        XCTAssertEqual(events.filter { $0["type"] as? String == "sleep" }.last?["mode"] as? String, "off")
    }

    func testTheScreenIsToldWhereTheSoundGoesAndCanOpenTheList() async throws {
        let outputs = { self.events.filter { $0["type"] as? String == "output" } }
        XCTAssertEqual(outputs().last?["kind"] as? String, "speaker")
        platform.output.set(AudioOutput(kind: "bluetooth", name: "AirPods Pro"))
        XCTAssertEqual(outputs().last?["kind"] as? String, "bluetooth")
        XCTAssertEqual(outputs().last?["name"] as? String, "AirPods Pro")
        _ = try await call("pickOutput")
        XCTAssertEqual(platform.outputPicked, 1)
    }

    func testARoomCannotBeEnteredBeforeTheServerIsSet() async throws {
        do {
            _ = try await call("join", ["code": "ABC234", "name": "Me"])
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "not_configured")
        }
        do {
            _ = try await call("createRoom", ["name": "Me"])
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "not_configured")
        }
        do {
            _ = try await call("kick", ["id": "x"])
            XCTFail("expected a refusal")
        } catch is GroupController.NoRoom {
            // not in a room
        }
    }

    func testCreatingAndJoiningARoomFollowsTheServer() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev", "key": "k3y"])
        http.answer("/rooms", text: #"{"code":"ABC234"}"#)
        let code = try await call("createRoom", ["name": "Me"]) as? String
        XCTAssertEqual(code, "ABC234")
        let created = try XCTUnwrap(http.calls.first { $0.url.hasSuffix("/rooms") })
        XCTAssertEqual(created.headers["x-sapoche-key"], "k3y")

        await time.advance(10)
        let socket = try XCTUnwrap(sockets.opened.last)
        XCTAssertEqual(socket.url.absoluteString, "wss://sapoche.example.dev/room/ABC234")
        XCTAssertEqual(socket.headers["X-Sapoche-Key"], "k3y")
        socket.open()
        let join = try XCTUnwrap(JSON.parse(socket.sent.first ?? "")?.object)
        XCTAssertEqual(join["t"] as? String, "join")
        XCTAssertEqual(join["name"] as? String, "Me")
        XCTAssertEqual(join["create"] as? Bool, true)

        let room = #"""
        {"t":"state","serverNow":1000,"you":"dev-a","protocol":6,
         "state":{"queue":[{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":200000,"addedBy":"dev-a"}],
                  "index":0,"phase":"paused","startedAt":0,"positionMs":0,"epoch":2,"repeat":"off","name":"Party","ownerId":"dev-a","guestControl":"all"},
         "members":[{"id":"dev-a","name":"Me","ready":true,"owner":true}]}
        """#
        socket.receive(room.replacingOccurrences(of: "\n", with: ""))
        await time.advance(100)
        let state = try XCTUnwrap(states().last)
        XCTAssertEqual(state["room"] as? String, "ABC234")
        XCTAssertEqual(state["name"] as? String, "Party")
        XCTAssertEqual(state["ownerId"] as? String, "dev-a")
        XCTAssertEqual(state["connection"] as? String, "connected")
        XCTAssertEqual((state["queue"] as? [[String: Any]])?.first?["id"] as? String, "q1")
        XCTAssertEqual((state["members"] as? [[String: Any]])?.first?["owner"] as? Bool, true)

        // In a room the buttons go to the room
        socket.sent.removeAll()
        _ = try await call("play")
        _ = try await call("seek", ["ms": 5000])
        _ = try await call("roomName", ["name": "New"])
        XCTAssertEqual(socket.sent.compactMap { JSON.parse($0)?.at("t").string }, ["play", "seek", "room.name"])

        // The room tells this phone to get ready, then to start
        socket.receive(#"{"t":"prepare","epoch":3,"index":0,"item":{"id":"q1","videoId":"video000001","title":"Song 1","artist":"A","durMs":200000,"addedBy":"dev-a"},"seekToMs":0}"#)
        await settle()
        XCTAssertEqual(engine.loaded?.id, "q1")
        XCTAssertTrue(socket.sent.contains { $0.contains("\"ready\"") && $0.contains("\"epoch\":3") })

        _ = try await call("leave")
        XCTAssertTrue(socket.sent.contains { $0.contains("\"bye\"") })
        await time.advance(100)
        XCTAssertTrue(states().last?["room"] is NSNull)
    }

    func testAnInvitationLinkReachesTheScreen() async throws {
        _ = try await call("configure", ["server": "https://sapoche.example.dev"])
        bridge.onLink(URL(string: "sapoche://join/abc234")!)
        bridge.onLink(URL(string: "https://sapoche.example.dev/join/XYZ789")!)
        bridge.onLink(URL(string: "https://elsewhere.example/join/NOPE22")!)
        bridge.onLink(URL(string: "sapoche://join/bad")!)
        let codes = events.filter { $0["type"] as? String == "invite" }.compactMap { $0["code"] as? String }
        XCTAssertEqual(codes, ["ABC234", "XYZ789"])
    }

    func testASetupLinkReachesTheScreenWhoeverIsListening() async throws {
        let link = "sapoche://setup?server=https%3A%2F%2Fsapoche.example.dev&key=k3y"
        // Opened before the screen listens: it is held, and given when it does
        bridge.stop()
        bridge.onLink(URL(string: link)!)
        events.removeAll()
        bridge.start { [weak self] text in
            if let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { self?.events.append(json) }
        }
        XCTAssertEqual(events.filter { $0["type"] as? String == "setup" }.compactMap { $0["link"] as? String }, [link])
        // Opened while it listens: it is given at once
        bridge.onLink(URL(string: link)!)
        XCTAssertEqual(events.filter { $0["type"] as? String == "setup" }.count, 2)
        XCTAssertNil(prefs.string("server_key"), "nothing is kept until the person agrees")
    }

    func testUnknownCommandsAreRefusedWithAMessage() async throws {
        do {
            _ = try await call("dance")
            XCTFail("expected a refusal")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "failed")
        }
    }

    func testTheScreenCanWriteInTheLog() async throws {
        _ = try await call("note", ["line": "frames=120 display=120Hz"])
        let lines = try await result("log", as: [String].self)
        XCTAssertTrue(lines.contains { $0.hasSuffix("ui: frames=120 display=120Hz") })
    }

    func testTheLogHoldsWhatWasDone() async throws {
        EventLog.d("test", "something happened")
        let lines = try await result("log", as: [String].self)
        XCTAssertTrue(lines.contains { $0.hasSuffix("test: something happened") })
    }
}

@MainActor
final class GroupControllerTests: XCTestCase {
    private var time: VirtualTime!
    private var engine: FakePlayer!
    private var controller: GroupController!
    private var asked: [String] = []
    private var dir: URL!

    override func setUp() async throws {
        time = VirtualTime()
        engine = FakePlayer(time: time)
        asked = []
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let more = TrackRef(videoId: "more0000001", title: "More", artist: "A", thumb: nil, durMs: 200_000)
        controller = GroupController(
            engine: engine, prefs: MemoryStore(), queueFile: QueueFile(url: dir.appendingPathComponent("queue.json")),
            config: { ServerConfig() }, time: time,
            moreLike: { [unowned self] id, _, _ in
                self.asked.append(id)
                return [more]
            }
        )
    }

    override func tearDown() async throws {
        controller.release()
        try? FileManager.default.removeItem(at: dir)
    }

    private func song(_ n: Int) -> TrackRef {
        TrackRef(videoId: "video00000\(n)", title: "Song \(n)", artist: "A", thumb: nil, durMs: 200_000)
    }

    func testWhenTheQueueRunsOutTheMusicCarriesOnWithSongsLikeTheLastOne() async {
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        engine.onEnded?()
        await time.advance(100)
        XCTAssertEqual(asked, ["video000001"])
        XCTAssertEqual(controller.local.snapshot.value.queue.map(\.videoId), ["video000001", "more0000001"])
        XCTAssertEqual(engine.loaded?.videoId, "more0000001")
    }

    func testTurningAutoplayOffLetsTheQueueEnd() async {
        controller.autoplayOn = false
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        engine.onEnded?()
        await time.advance(100)
        XCTAssertEqual(asked, [])
        XCTAssertTrue(controller.local.snapshot.value.finished)
    }

    func testTheSleepTimerAtTheEndOfTheLastSongStopsTheMusicInsteadOfCarryingOn() async {
        controller.requestAddMany([song(1)], playNext: false)
        await time.advance(100)
        controller.sleep.startAtSongEnd()
        XCTAssertTrue(engine.pauseAtSongEnd)
        // What the player does at the end of the last song: reports it, then that it paused for the timer
        engine.onEnded?()
        engine.onSongEndPause?()
        await time.advance(100)
        XCTAssertEqual(asked, [], "the timer was still set when the queue ran out, so nothing carries on")
        XCTAssertEqual(controller.sleep.state.value, .off)
        XCTAssertFalse(engine.pauseAtSongEnd)
        XCTAssertFalse(engine.playing)
    }

    func testTheSleepTimerAtTheEndOfASongPausesThisDeviceAndNothingElse() async {
        controller.requestAddMany([song(1), song(2)], playNext: false)
        await time.advance(100)
        controller.sleep.startAtSongEnd()
        engine.onSongEndPause?()
        await time.advance(100)
        XCTAssertFalse(engine.playing)
        XCTAssertEqual(controller.local.snapshot.value.index, 0, "the next song waits for the person to press play")
    }

    func testTheRoomIsNotRejoinedLongAfterTheAppWasLeft() {
        let prefs = MemoryStore()
        prefs.set("ABC234", for: "room_code")
        prefs.set(Int64(Date().timeIntervalSince1970 * 1000) - 11 * 60_000, for: "room_last_active")
        let late = GroupController(engine: FakePlayer(time: time), prefs: prefs, queueFile: QueueFile(url: dir.appendingPathComponent("a.json")),
                                   config: { ServerConfig(server: "https://x") }, time: time, sockets: FakeSockets())
        late.recoverRoom()
        XCTAssertNil(late.roomCode)
        XCTAssertNil(prefs.string("room_code"), "a room left that long ago is forgotten")
        late.release()
    }

    func testTheRoomIsRejoinedRightAfterTheAppWasEnded() {
        let prefs = MemoryStore()
        prefs.set("ABC234", for: "room_code")
        prefs.set("Me", for: "room_name")
        prefs.set(Int64(Date().timeIntervalSince1970 * 1000) - 60_000, for: "room_last_active")
        let sockets = FakeSockets()
        let soon = GroupController(engine: FakePlayer(time: time), prefs: prefs, queueFile: QueueFile(url: dir.appendingPathComponent("b.json")),
                                   config: { ServerConfig(server: "https://x") }, time: time, sockets: sockets)
        soon.recoverRoom()
        XCTAssertEqual(soon.roomCode, "ABC234")
        soon.release()
    }
}
