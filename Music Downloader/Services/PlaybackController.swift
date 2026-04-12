import AppKit
import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Single-track audio playback wrapper around `AVAudioPlayer`.
///
/// Lives in the environment so playback persists across job selection changes
/// (start a track in Playlist A, switch to Playlist B, keep hearing A).
@Observable
@MainActor
final class PlaybackController {
    /// The track currently loaded into the player, or nil if the player is idle.
    private(set) var currentTrack: Track?

    /// Current playhead in seconds. Updated ~10×/sec while playing.
    private(set) var currentTime: TimeInterval = 0

    /// Total length of the current track in seconds.
    private(set) var duration: TimeInterval = 0

    /// True when the underlying `AVAudioPlayer` is in a playing state.
    private(set) var isPlaying: Bool = false

    /// Last playback error surfaced to the UI.
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    init() {
        setupRemoteCommandCenter()
    }

    // MARK: - Commands

    /// Start (or resume) playback for `track`. If `track` is already loaded,
    /// just resumes. Otherwise loads the new file and begins playing from 0.
    func play(_ track: Track) {
        guard let url = track.fileURL else {
            errorMessage = "Track file not found on disk."
            return
        }

        // Same track → resume.
        if currentTrack?.id == track.id, let player = self.player {
            player.play()
            isPlaying = true
            updatePlaybackState()
            startTimer()
            return
        }

        stopInternal()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()

            self.player = player
            self.currentTrack = track
            self.duration = player.duration
            self.currentTime = 0
            self.isPlaying = true
            self.errorMessage = nil
            startTimer()
            updateNowPlayingInfo()
            updatePlaybackState()
        } catch {
            self.errorMessage = "Couldn't play file: \(error.localizedDescription)"
            self.currentTrack = nil
            self.player = nil
            self.isPlaying = false
        }
    }

    /// Pause the currently playing track (keeps it loaded).
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updatePlaybackState()
    }

    /// If `track` is currently loaded and playing, pauses; otherwise plays it.
    func toggle(_ track: Track) {
        if currentTrack?.id == track.id, isPlaying {
            pause()
        } else {
            play(track)
        }
    }

    /// Stop and unload the current track. Clears the player bar.
    func stop() {
        stopInternal()
        clearNowPlayingInfo()
        currentTrack = nil
        currentTime = 0
        duration = 0
    }

    /// Seek the playhead to `time` (seconds). Clamped to [0, duration].
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
        updateNowPlayingElapsedTime()
    }

    // MARK: - Queries used by views

    /// True if the given track is the one currently loaded AND playing.
    func isPlaying(_ track: Track) -> Bool {
        currentTrack?.id == track.id && isPlaying
    }

    /// True if the given track is the one currently loaded (playing or paused).
    func isCurrent(_ track: Track) -> Bool {
        currentTrack?.id == track.id
    }

    // MARK: - Private

    private func stopInternal() {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func startTimer() {
        stopTimer()
        // 10 Hz is smooth enough for a scrubber without burning CPU.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Called by the timer while a track is playing to update `currentTime`
    /// and detect natural end-of-file.
    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime

        if !player.isPlaying && isPlaying {
            // Natural end of file (AVAudioPlayer stopped on its own).
            isPlaying = false
            currentTime = duration
            stopTimer()
            clearNowPlayingInfo()
        }
    }

    // MARK: - Now Playing / Remote Commands

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let track = self.currentTrack, !self.isPlaying else { return }
                self.play(track)
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let track = self.currentTrack else { return }
                self.toggle(track)
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seek(to: positionEvent.positionTime)
            }
            return .success
        }

        // No playlist-level skip in this app.
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        let meta = track.metadata

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: meta?.title ?? track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = meta?.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = meta?.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Load artwork asynchronously from cover art URL.
        if let coverURL = meta?.coverArtURL {
            Task.detached {
                guard let (data, _) = try? await URLSession.shared.data(from: coverURL),
                      let image = NSImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run {
                    guard var current = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                    current[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }
        }
    }

    private func updateNowPlayingElapsedTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updatePlaybackState() {
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        updateNowPlayingElapsedTime()
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
