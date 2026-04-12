import SwiftUI
import UniformTypeIdentifiers

/// Per-track inspector with interactive waveform, metadata view/edit, and
/// artwork management. Default view shows Genius matches; edit mode enables
/// direct field editing.
struct TrackInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback

    @Bindable var track: Track
    let job: DownloadJob

    // Genius match selection (view mode)
    @State private var selectedHitID: Int?
    @State private var customQuery: String = ""
    @State private var isResearching = false

    // Edit mode state
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editArtist = ""
    @State private var editAlbum = ""
    @State private var editYear = ""
    @State private var editGenre = ""
    @State private var editComments = ""
    @State private var editArtworkData: Data?
    @State private var artworkChanged = false

    var body: some View {
        VStack(spacing: 0) {
            // Waveform at top
            WaveformView(track: track)
                .padding(20)

            Divider()

            // File info row
            fileInfoRow
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    // Left: tags
                    VStack(alignment: .leading, spacing: 16) {
                        tagsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right: artwork
                    ArtworkDropZone(
                        artworkData: isEditing ? editArtworkData : nil,
                        artworkURL: track.metadata?.coverArtURL
                            ?? track.alternativeMatches.first?.songArtImageURL,
                        isEditable: isEditing,
                        onArtworkChanged: { data in
                            editArtworkData = data
                            artworkChanged = true
                        }
                    )
                }
                .padding(20)

                if !isEditing {
                    VStack(alignment: .leading, spacing: 16) {
                        alternativesSection
                        researchSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }

            Divider()

            actionsSection
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 660, height: 720)
        .onAppear {
            selectedHitID = track.metadata?.geniusID
                ?? track.alternativeMatches.first?.id
        }
    }

    // MARK: - File info row

    private var fileInfoRow: some View {
        HStack(spacing: 16) {
            if let url = track.fileURL {
                HStack(spacing: 4) {
                    Text("File:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    HStack(spacing: 4) {
                        Text("Size:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                    }
                }

                HStack(spacing: 4) {
                    Text("Format:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.pathExtension.uppercased())
                        .font(.caption)
                }
            }

            Spacer()

            Button {
                store.revealTrackInFinder(track)
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Tags section

    @ViewBuilder
    private var tagsSection: some View {
        HStack {
            sectionLabel("Tags")
            Spacer()
            Button {
                if isEditing {
                    // Cancel edit
                    isEditing = false
                    artworkChanged = false
                } else {
                    enterEditMode()
                }
            } label: {
                Text(isEditing ? "Cancel" : "Edit")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }

        if isEditing {
            editableFields
        } else {
            readOnlyFields
        }
    }

    // MARK: - Read-only fields (view mode)

    @ViewBuilder
    private var readOnlyFields: some View {
        let metadata = track.metadata

        VStack(alignment: .leading, spacing: 6) {
            infoRow(label: "Title", value: metadata?.title ?? track.title)
            infoRow(label: "Artist", value: metadata?.artist ?? "—")
            infoRow(label: "Album", value: metadata?.album ?? "—")
            infoRow(label: "Year", value: metadata?.year ?? "—")
            infoRow(label: "Genre", value: metadata?.genre ?? "—")
            if let comments = metadata?.comments, !comments.isEmpty {
                infoRow(label: "Comments", value: comments)
            }
        }

        if let geniusURL = metadata?.geniusURL {
            Link(destination: geniusURL) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("View on Genius")
                }
                .font(.caption)
            }
        }

        HStack(spacing: 6) {
            Image(systemName: track.enrichmentStatus.symbolName)
                .foregroundStyle(track.enrichmentStatus.tint)
            Text(track.enrichmentStatus.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Editable fields (edit mode)

    @ViewBuilder
    private var editableFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            editRow(label: "Title", text: $editTitle)
            editRow(label: "Artist", text: $editArtist)
            editRow(label: "Album", text: $editAlbum)
            editRow(label: "Year", text: $editYear)
            editRow(label: "Genre", text: $editGenre)

            HStack(alignment: .top, spacing: 10) {
                Text("Comments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .padding(.top, 4)
                TextEditor(text: $editComments)
                    .font(.caption)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func editRow(label: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func enterEditMode() {
        let m = track.metadata
        editTitle = m?.title ?? track.title
        editArtist = m?.artist ?? ""
        editAlbum = m?.album ?? ""
        editYear = m?.year ?? ""
        editGenre = m?.genre ?? ""
        editComments = m?.comments ?? ""
        editArtworkData = nil
        artworkChanged = false
        isEditing = true
    }

    // MARK: - Alternatives (view mode only)

    @ViewBuilder
    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Alternative Matches")

            if track.alternativeMatches.isEmpty {
                Text("No alternatives available. Search with a custom query below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(track.alternativeMatches) { hit in
                        HitRow(
                            hit: hit,
                            isSelected: selectedHitID == hit.id,
                            onSelect: { selectedHitID = hit.id }
                        )
                        if hit.id != track.alternativeMatches.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Re-search (view mode only)

    @ViewBuilder
    private var researchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Search Again")
            HStack(spacing: 8) {
                TextField("Custom query (e.g. \"Artist Title\")", text: $customQuery)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isResearching)
                Button {
                    Task { await researchWithCustomQuery() }
                } label: {
                    if isResearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .disabled(isResearching || customQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Actions bar

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 8) {
            if !isEditing {
                if track.originalFilename != nil,
                   track.fileURL?.deletingPathExtension().lastPathComponent != track.originalFilename {
                    Button {
                        store.revertFilename(track, in: job)
                    } label: {
                        Label("Revert Filename", systemImage: "arrow.uturn.backward")
                    }
                }
            }

            Spacer()

            Button("Close") { dismiss() }

            if isEditing {
                Button {
                    saveEdits()
                } label: {
                    Label("Save", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button {
                    applySelected()
                } label: {
                    Label("Apply Match", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
        }
    }

    // MARK: - Save edits

    private func saveEdits() {
        let metadata = SongMetadata(
            title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: editArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: editAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editAlbum.trimmingCharacters(in: .whitespacesAndNewlines),
            year: editYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editYear.trimmingCharacters(in: .whitespacesAndNewlines),
            coverArtURL: track.metadata?.coverArtURL,
            geniusID: track.metadata?.geniusID,
            geniusURL: track.metadata?.geniusURL,
            genre: editGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editGenre.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: editComments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editComments.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let artwork = artworkChanged ? editArtworkData : nil
        store.saveManualMetadata(
            track: track,
            in: job,
            metadata: metadata,
            coverArtData: artwork,
            settings: settings
        )
        isEditing = false
        artworkChanged = false
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canApply: Bool {
        guard let selectedHitID else { return false }
        if track.enrichmentStatus == .enriched,
           track.metadata?.geniusID == selectedHitID {
            return false
        }
        return track.alternativeMatches.contains(where: { $0.id == selectedHitID })
    }

    private func applySelected() {
        guard let id = selectedHitID,
              let hit = track.alternativeMatches.first(where: { $0.id == id })
        else { return }
        store.applyMatch(hit, to: track, in: job, settings: settings)
    }

    private func researchWithCustomQuery() async {
        let query = customQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isResearching = true
        defer { isResearching = false }

        let token = settings.geniusToken
        guard !token.isEmpty else {
            track.enrichmentStatus = .failed(GeniusError.missingToken.localizedDescription)
            return
        }

        do {
            let service = GeniusService()
            let hits = try await service.search(query: query, token: token)
            track.alternativeMatches = Array(hits.prefix(5))
            selectedHitID = hits.first?.id
        } catch {
            track.enrichmentStatus = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Hit row

private struct HitRow: View {
    let hit: GeniusHitResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AsyncImage(url: hit.songArtImageThumbnailURL ?? hit.songArtImageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(hit.primaryArtist.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}
