import SwiftUI

/// Per-track detail + override UI. Opened from JobDetailView by tapping a
/// completed track. Shows the current Genius match, alternative hits, and
/// actions to re-match or revert the filename.
struct TrackInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @Bindable var track: Track
    let job: DownloadJob

    @State private var selectedHitID: Int?
    @State private var customQuery: String = ""
    @State private var isResearching = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let metadata = track.metadata, track.enrichmentStatus == .enriched {
                        currentMatchSection(metadata: metadata)
                    }

                    alternativesSection

                    researchSection

                    actionsSection
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 620)
        .onAppear {
            selectedHitID = track.metadata?.geniusID
                ?? track.alternativeMatches.first?.id
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            coverArt
                .frame(width: 96, height: 96)
                .background(Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                if let artist = track.metadata?.artist {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: track.enrichmentStatus.symbolName)
                        .foregroundStyle(track.enrichmentStatus.tint)
                    Text(track.enrichmentStatus.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var coverArt: some View {
        if let url = track.metadata?.coverArtURL
            ?? track.alternativeMatches.first?.songArtImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var displayTitle: String {
        track.metadata?.title ?? track.title
    }

    // MARK: - Current match

    @ViewBuilder
    private func currentMatchSection(metadata: SongMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Current Metadata")
            infoGrid(metadata: metadata)

            if let geniusURL = metadata.geniusURL {
                Link(destination: geniusURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("View on Genius")
                    }
                    .font(.caption)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func infoGrid(metadata: SongMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow(label: "Title", value: metadata.title)
            infoRow(label: "Artist", value: metadata.artist)
            if let album = metadata.album { infoRow(label: "Album", value: album) }
            if let year = metadata.year   { infoRow(label: "Year", value: year) }
            infoRow(label: "Filename",
                    value: track.fileURL?.lastPathComponent ?? "—")
        }
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

    // MARK: - Alternatives

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

    // MARK: - Re-search

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

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 8) {
            if track.originalFilename != nil,
               track.fileURL?.deletingPathExtension().lastPathComponent != track.originalFilename {
                Button {
                    store.revertFilename(track, in: job)
                } label: {
                    Label("Revert Filename", systemImage: "arrow.uturn.backward")
                }
            }

            Spacer()

            Button("Close") { dismiss() }

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

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private var canApply: Bool {
        guard let selectedHitID else { return false }
        // Allow re-applying if selection differs from current metadata OR
        // current enrichment failed.
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
