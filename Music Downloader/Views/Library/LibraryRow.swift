import SwiftUI

/// One song in the library list. Column widths match `TrackRow` so the two
/// lists read as the same table.
struct LibraryRow: View {
    let entry: LibraryEntry
    let libraryRoot: URL

    /// The ledger records what was merged; the file can still be deleted by
    /// hand afterwards. Checked per row because the library list is short-lived
    /// and a stale "missing" badge is worse than the stat call.
    private var fileExists: Bool {
        FileManager.default.fileExists(
            atPath: libraryRoot.appendingPathComponent(entry.file).path
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !fileExists {
                    Text("File is missing from the library folder")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.artist)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(entry.album ?? "—")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(Self.formatDuration(entry.durationSeconds))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if fileExists,
           let rawURL = entry.coverArtURL,
           let url = URL(string: rawURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderArtwork
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            placeholderArtwork
                .frame(width: 28, height: 28)
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                Image(systemName: fileExists ? "music.note" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fileExists ? Color.secondary : Color.orange)
            }
    }

    static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
