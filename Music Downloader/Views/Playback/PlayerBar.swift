import SwiftUI

/// Persistent mini-player attached to the bottom of the main window.
/// Appears whenever `PlaybackController.currentTrack != nil`.
struct PlayerBar: View {
    @Environment(PlaybackController.self) private var playback

    /// Local state for the scrubber so dragging doesn't fight with the
    /// 10 Hz currentTime updates coming from the player.
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .center, spacing: 14) {
                coverArt
                trackInfo
                playPauseButton
                scrubberSection
                closeButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Cover art

    @ViewBuilder
    private var coverArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))

            if let url = playback.currentTrack?.metadata?.coverArtURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primaryLabel)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(secondaryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 150, idealWidth: 200, maxWidth: 260, alignment: .leading)
    }

    private var primaryLabel: String {
        guard let track = playback.currentTrack else { return "—" }
        return track.metadata?.title ?? track.title
    }

    private var secondaryLabel: String {
        guard let track = playback.currentTrack else { return "" }
        if let artist = track.metadata?.artist { return artist }
        return "Not enriched"
    }

    // MARK: - Play / pause

    private var playPauseButton: some View {
        Button {
            guard let track = playback.currentTrack else { return }
            playback.toggle(track)
        } label: {
            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")
    }

    // MARK: - Scrubber + time labels

    private var scrubberSection: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: {
                        isScrubbing ? scrubValue : min(playback.currentTime, max(playback.duration, 0.0001))
                    },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(playback.duration, 0.0001),
                onEditingChanged: handleScrubEdit
            )
            .controlSize(.small)
            .disabled(playback.duration <= 0)

            HStack {
                Text(format(isScrubbing ? scrubValue : playback.currentTime))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-" + format(max(0, playback.duration - (isScrubbing ? scrubValue : playback.currentTime))))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(format(playback.duration))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240)
    }

    private func handleScrubEdit(_ editing: Bool) {
        if editing {
            scrubValue = playback.currentTime
            isScrubbing = true
        } else {
            playback.seek(to: scrubValue)
            isScrubbing = false
        }
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            playback.stop()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Stop and close player")
    }

    // MARK: - Time formatting

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
