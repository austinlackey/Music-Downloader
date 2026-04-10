import SwiftUI

struct TrackRow: View {
    @Environment(PlaybackController.self) private var playback
    let track: Track
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            // Status icon: prefer enrichment state once download is complete.
            Image(systemName: leadingSymbolName)
                .foregroundStyle(leadingTint)
                .symbolEffect(.pulse, options: .repeating, isActive: isInFlight)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                // Primary line: enriched "Artist — Title", else fall back to title.
                if let metadata = track.metadata, track.enrichmentStatus == .enriched {
                    HStack(spacing: 6) {
                        Text(metadata.artist)
                            .fontWeight(.medium)
                        Text("—")
                            .foregroundStyle(.secondary)
                        Text(metadata.title)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    Text(track.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Secondary line: either progress bar, album name, or status.
                secondaryLine
            }

            Spacer()

            statusLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            playButton
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            playback.isCurrent(track)
                ? Color.accentColor.opacity(0.08)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    @ViewBuilder
    private var playButton: some View {
        if track.fileURL != nil, track.status == .completed {
            Button {
                playback.toggle(track)
            } label: {
                Image(systemName: playback.isPlaying(track)
                      ? "pause.circle.fill"
                      : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying(track) ? "Pause" : "Play")
        } else {
            // Placeholder to keep row layout stable.
            Color.clear.frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if track.status == .downloading {
            ProgressView(value: track.progress)
                .progressViewStyle(.linear)
                .controlSize(.mini)
        } else if track.enrichmentStatus == .searching || track.enrichmentStatus == .writing || track.enrichmentStatus == .matched {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(height: 10)
                Text(track.enrichmentStatus.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if case .failed(let msg) = track.enrichmentStatus {
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let album = track.metadata?.album, track.enrichmentStatus == .enriched {
            Text(album + (track.metadata?.year.map { " • \($0)" } ?? ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch track.status {
        case .downloading:
            Text("\(Int(track.progress * 100))%")
        case .completed:
            switch track.enrichmentStatus {
            case .enriched:              Text("Tagged")
            case .failed:                Text("Error")
            case .searching, .writing, .matched: Text("Working…")
            default:                     Text("Done")
            }
        case .failed:
            Text("Failed")
        case .cancelled:
            Text("Cancelled")
        case .pending, .fetchingMetadata:
            Text("Queued")
        }
    }

    private var leadingSymbolName: String {
        // Still downloading → show download status. Done → show enrichment status.
        if track.status != .completed { return track.status.symbolName }
        return track.enrichmentStatus.symbolName
    }

    private var leadingTint: Color {
        if track.status != .completed { return track.status.tint }
        return track.enrichmentStatus.tint
    }

    private var isInFlight: Bool {
        track.status == .downloading || track.enrichmentStatus.isInFlight
    }
}
