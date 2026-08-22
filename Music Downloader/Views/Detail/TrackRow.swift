import SwiftUI

struct TrackRow: View {
    @Environment(PlaybackController.self) private var playback
    let track: Track
    let index: Int

    var body: some View {
        HStack(spacing: 0) {
            // # column
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Image(systemName: leadingSymbolName)
                    .foregroundStyle(leadingTint)
                    .symbolEffect(.pulse, options: .repeating, isActive: isInFlight)
                    .frame(width: 16)
            }
            .frame(width: 60, alignment: .leading)

            // Title column (flexible)
            HStack(spacing: 8) {
                artworkThumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.metadata?.title ?? track.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Show progress / error inline under title
                    inlineSecondary
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // Artist column
            Text(track.metadata?.artist ?? "—")
                .font(.subheadline)
                .foregroundStyle(track.metadata?.artist != nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 140, alignment: .leading)
                .padding(.trailing, 8)

            // Album column
            VStack(alignment: .leading, spacing: 0) {
                Text(track.metadata?.album ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(track.metadata?.album != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let year = track.metadata?.year {
                    Text(year)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)
            .padding(.trailing, 8)

            // Status column
            statusLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .leading)

            // Play button
            playButton
                .frame(width: 28)
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
    private var artworkThumbnail: some View {
        if let url = track.metadata?.coverArtURL, track.enrichmentStatus == .enriched {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if track.fileURL != nil, track.status == .completed, !track.isFileMissing {
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
    private var inlineSecondary: some View {
        if track.isFileMissing {
            Text("File missing from disk")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if track.status == .failed, let message = track.errorMessage {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if track.status == .unavailable, let reason = track.unavailableReason {
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if track.status == .downloading {
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
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if track.isFileMissing {
            Text("Missing")
                .foregroundStyle(.orange)
        } else {
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
            case .unavailable:
                Text((track.unavailableKind ?? .removed).displayName)
                    .foregroundStyle(.secondary)
            case .pending, .fetchingMetadata:
                Text("Queued")
            case .staged, .merging, .merged:
                // Job-level states; a track never carries them itself, but the
                // enum is shared so they have to be handled.
                Text(track.status.displayName)
            }
        }
    }

    private var leadingSymbolName: String {
        if track.isFileMissing { return "questionmark.folder" }
        if track.status == .unavailable, let kind = track.unavailableKind {
            return kind.symbolName
        }
        // Still downloading → show download status. Done → show enrichment status.
        if track.status != .completed { return track.status.symbolName }
        return track.enrichmentStatus.symbolName
    }

    private var leadingTint: Color {
        if track.isFileMissing { return .orange }
        if track.status != .completed { return track.status.tint }
        return track.enrichmentStatus.tint
    }

    private var isInFlight: Bool {
        track.status == .downloading || track.enrichmentStatus.isInFlight
    }
}
