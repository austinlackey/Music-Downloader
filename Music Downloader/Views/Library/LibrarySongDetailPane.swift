import AppKit
import SwiftUI

struct LibrarySongDetailPane: View {
    let entry: LibraryEntry
    let memberships: [LibraryPlaylistMembership]
    let libraryRoot: URL
    let onClose: () -> Void

    private var fileURL: URL {
        libraryRoot.appendingPathComponent(entry.file)
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)

            HStack(alignment: .top, spacing: 22) {
                metadataSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                fileSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                playlistSection
                    .frame(width: 250, alignment: .topLeading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.36), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.artist.isEmpty ? "Unknown Artist" : entry.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(!fileExists)
                .help("Show in Finder")

                if let geniusURL = entry.geniusURL.flatMap(URL.init(string:)) {
                    Button {
                        NSWorkspace.shared.open(geniusURL)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help("Open on Genius")
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var artwork: some View {
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
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            placeholderArtwork
                .frame(width: 54, height: 54)
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                Image(systemName: fileExists ? "music.note" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(fileExists ? Color.accentColor : Color.orange)
            }
    }

    private var metadataSection: some View {
        section("Metadata") {
            detailRow("Title", entry.name)
            detailRow("Artist", entry.artist)
            detailRow("Album", entry.album)
            detailRow("Year", entry.year)
            detailRow("Release", entry.releaseDate)
            detailRow("Genius ID", entry.geniusID.map(String.init))
        }
    }

    private var fileSection: some View {
        section("File") {
            detailRow("Status", fileExists ? "Available" : "Missing")
            detailRow("Duration", LibraryRow.formatDuration(entry.durationSeconds))
            detailRow("Size", Self.formatBytes(entry.fileSize))
            detailRow("Added", Self.formatDate(entry.addedAt))
            detailRow("Exported", entry.exportedAt.map(Self.formatDate) ?? "Not yet exported")
            detailRow("Path", entry.file)
        }
    }

    private var playlistSection: some View {
        section("Appears In") {
            if memberships.isEmpty {
                Text("No merged playlists reference this song.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memberships) { membership in
                            HStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(membership.name)
                                        .lineLimit(1)
                                    Text("#\(membership.position) of \(membership.totalCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 104)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(Self.presentedValue(value))
                .font(.subheadline)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func presentedValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        return value
    }

    private static func formatDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func formatBytes(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
