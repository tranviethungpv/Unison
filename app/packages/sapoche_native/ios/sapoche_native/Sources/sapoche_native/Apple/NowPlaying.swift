import Foundation
import MediaPlayer
import UIKit

/// What the lock screen, Control Center and headphone buttons show and do: the song that plays and play, pause, next,
/// previous and the slider. While joined to a room these control the whole room, and outside one the personal queue,
/// because they go through the [GroupController] like the buttons of the app.
@MainActor
final class NowPlaying {
    private let controller: GroupController
    private let engine: PlayerEngine
    private var shownVideoId: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var artworkCache: [String: UIImage] = [:]

    /// What the lock screen was last given and when. The system moves the time on by itself while the rate says the song
    /// plays, so the same song, state and length at the time they should be at are not given again: in a room the
    /// player changes twice a second (its drift), and each of those woke the lock screen for nothing, screen off or on.
    private var given: (signature: String, positionMs: Int64, at: TimeInterval)?

    init(controller: GroupController, engine: PlayerEngine) {
        self.controller = controller
        self.engine = engine
        connectButtons()
    }

    // ------------------------------------------------------------------ buttons

    private func connectButtons() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller.requestPlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller.requestPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.engine.wantsSound { self.controller.requestPause() } else { self.controller.requestPlay() }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller.requestNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller.requestPrev() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let ms = Int64(event.positionTime * 1000)
            Task { @MainActor in self?.controller.requestSeek(ms) }
            return .success
        }
        // Skipping by seconds is not what these buttons are for
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    // ------------------------------------------------------------------ what is shown

    /// Brings the lock screen up to date with the player; called whenever the player or the queue changed.
    func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let item = engine.loadedItem ?? shownItem() else {
            center.nowPlayingInfo = nil
            shownVideoId = nil
            artwork = nil
            given = nil
            return
        }
        let info = engine.playerInfo()
        if shownVideoId != item.videoId {
            shownVideoId = item.videoId
            artwork = nil
            loadArtwork(item)
        }
        let duration = info.durationMs > 0 ? info.durationMs : item.durMs
        let signature = "\(item.videoId)|\(item.title)|\(item.artist)|\(info.playing)|\(duration)|\(artwork != nil)"
        let now = ProcessInfo.processInfo.systemUptime
        if let given, given.signature == signature {
            let expected = given.positionMs + (info.playing ? Int64((now - given.at) * 1000) : 0)
            if abs(expected - info.positionMs) < 1500 { return }
        }
        given = (signature: signature, positionMs: info.positionMs, at: now)
        var fields: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if duration > 0 { fields[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000 }
        if let artwork { fields[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = fields
    }

    /// The song the queue is on while the player has nothing loaded (after a restart), so the lock screen is not blank.
    private func shownItem() -> QueueItem? {
        let view = controller.view.value
        if view.roomCode != nil { return view.snapshot.state?.current }
        return view.local.queue.isEmpty ? nil : view.local.current
    }

    private func loadArtwork(_ item: QueueItem) {
        artworkTask?.cancel()
        guard let address = item.thumb, let url = URL(string: address) else { return }
        if let image = artworkCache[address] {
            show(image, for: item.videoId)
            return
        }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            guard let self, !Task.isCancelled else { return }
            if self.artworkCache.count > 20 { self.artworkCache.removeAll() }
            self.artworkCache[address] = image
            self.show(image, for: item.videoId)
        }
    }

    private func show(_ image: UIImage, for videoId: String) {
        guard shownVideoId == videoId else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        refresh()
    }
}
