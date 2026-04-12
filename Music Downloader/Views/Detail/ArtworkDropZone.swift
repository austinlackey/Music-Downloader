import SwiftUI
import UniformTypeIdentifiers

/// Displays album artwork with drag-and-drop and click-to-browse support
/// for replacing the image.
struct ArtworkDropZone: View {
    /// Current cover art data (JPEG/PNG bytes), if any. Takes priority over URL.
    let artworkData: Data?

    /// Fallback: cover art URL (e.g. from Genius). Used when artworkData is nil.
    let artworkURL: URL?

    /// Whether the zone accepts interaction (true in edit mode).
    let isEditable: Bool

    /// Called when the user provides new artwork (via drop or file picker).
    let onArtworkChanged: (Data) -> Void

    @State private var isTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))

            if let artworkData, let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                placeholder
            }
        }
        .frame(width: 160, height: 160)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.2),
                    lineWidth: isTargeted ? 2 : 0.5
                )
        )
        .onDrop(of: [.image], isTargeted: $isTargeted) { providers in
            guard isEditable else { return false }
            return handleDrop(providers)
        }
        .onTapGesture {
            guard isEditable else { return }
            showFilePicker = true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .opacity(isEditable ? 1 : 0.8)
        .help(isEditable ? "Click to browse or drag an image to set artwork" : "")
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Drag Artwork\nHere")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data {
                    DispatchQueue.main.async {
                        onArtworkChanged(data)
                    }
                }
            }
            return true
        }
        return false
    }

    // MARK: - File picker handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if let data = try? Data(contentsOf: url) {
            onArtworkChanged(data)
        }
    }
}
