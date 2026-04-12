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
                        creditsSection
                        songFactsSection
                        relationshipsSection
                        mediaLinksSection
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
        VStack(alignment: .leading, spacing: 6) {
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

            if let original = track.originalFilename,
               original != track.fileURL?.deletingPathExtension().lastPathComponent {
                HStack(spacing: 4) {
                    Text("Original:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(original)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
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
            if let featured = metadata?.featuredArtists, !featured.isEmpty {
                infoRow(label: "Featured", value: featured.joined(separator: ", "))
            }
            if let producers = metadata?.producerArtists, !producers.isEmpty {
                infoRow(label: "Producers", value: producers.joined(separator: ", "))
            }
            if let writers = metadata?.writerArtists, !writers.isEmpty {
                infoRow(label: "Writers", value: writers.joined(separator: ", "))
            }
            if let language = metadata?.language, !language.isEmpty {
                infoRow(label: "Language", value: language)
            }
            if let location = metadata?.recordingLocation, !location.isEmpty {
                infoRow(label: "Recorded", value: location)
            }
            if let releaseDate = metadata?.releaseDate, !releaseDate.isEmpty {
                infoRow(label: "Released", value: releaseDate)
            }
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

    // MARK: - Song Facts (view mode only)

    @ViewBuilder
    private var songFactsSection: some View {
        let desc = track.metadata?.songDescription
        let annotations = track.metadata?.annotations ?? []
        let hasFacts = (desc != nil && !desc!.isEmpty) || !annotations.isEmpty

        if hasFacts {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Song Facts")

                if let desc, !desc.isEmpty {
                    DisclosureGroup("About This Song") {
                        Text(desc)
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(.caption.weight(.medium))
                }

                let verified = annotations.filter(\.verified)
                let accepted = annotations.filter { !$0.verified }

                if !verified.isEmpty {
                    DisclosureGroup("Artist Annotations (\(verified.count))") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(verified.enumerated()), id: \.offset) { _, fact in
                                annotationFactView(fact)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption.weight(.medium))
                }

                if !accepted.isEmpty {
                    DisclosureGroup("Top Annotations (\(accepted.count))") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(accepted.enumerated()), id: \.offset) { _, fact in
                                annotationFactView(fact)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption.weight(.medium))
                }
            }
        }
    }

    private func annotationFactView(_ fact: AnnotationFact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\"\(fact.fragment.prefix(120))\"")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(fact.body)
                .font(.caption)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(fact.authors)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if fact.verified {
                    Label("Verified", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                } else {
                    Text("\(fact.votes) votes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
        }
    }

    // MARK: - Credits (view mode only)

    @ViewBuilder
    private var creditsSection: some View {
        if let credits = track.metadata?.credits, !credits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Credits")

                DisclosureGroup("Performance Credits (\(credits.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                            HStack(alignment: .top, spacing: 6) {
                                Text(credit.role + ":")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 80, alignment: .trailing)
                                Text(credit.artists.joined(separator: ", "))
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    // MARK: - Song Relationships (view mode only)

    @ViewBuilder
    private var relationshipsSection: some View {
        if let relationships = track.metadata?.songRelationships, !relationships.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Song Relationships")

                DisclosureGroup("Connections (\(relationships.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(relationships.enumerated()), id: \.offset) { _, rel in
                            HStack(alignment: .top, spacing: 6) {
                                Text(Self.formatRelationshipType(rel.type) + ":")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 80, alignment: .trailing)
                                Text("\"\(rel.title)\" by \(rel.artist)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    /// Convert snake_case relationship types to readable labels.
    private static func formatRelationshipType(_ type: String) -> String {
        switch type {
        case "samples":         "Samples"
        case "sampled_in":      "Sampled in"
        case "interpolates":    "Interpolates"
        case "interpolated_by": "Interpolated by"
        case "cover_of":        "Cover of"
        case "covered_by":      "Covered by"
        case "remix_of":        "Remix of"
        case "remixed_by":      "Remixed by"
        case "live_version_of": "Live version of"
        case "performed_live_as": "Performed live as"
        default:                type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - Media Links (view mode only)

    @ViewBuilder
    private var mediaLinksSection: some View {
        if let links = track.metadata?.mediaLinks, !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Listen On")

                FlowLayout(spacing: 8) {
                    ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                        Link(destination: link.url) {
                            HStack(spacing: 4) {
                                Image(systemName: Self.iconForProvider(link.provider))
                                Text(Self.displayNameForProvider(link.provider))
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private static func iconForProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "spotify":      "arrow.up.right.square"
        case "apple_music":  "arrow.up.right.square"
        case "youtube":      "play.rectangle"
        case "soundcloud":   "arrow.up.right.square"
        default:             "link"
        }
    }

    private static func displayNameForProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "spotify":      "Spotify"
        case "apple_music":  "Apple Music"
        case "youtube":      "YouTube"
        case "soundcloud":   "SoundCloud"
        default:             provider.replacingOccurrences(of: "_", with: " ").capitalized
        }
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
                ? nil : editComments.trimmingCharacters(in: .whitespacesAndNewlines),
            songDescription: track.metadata?.songDescription,
            annotations: track.metadata?.annotations,
            featuredArtists: track.metadata?.featuredArtists,
            producerArtists: track.metadata?.producerArtists,
            writerArtists: track.metadata?.writerArtists,
            credits: track.metadata?.credits,
            recordingLocation: track.metadata?.recordingLocation,
            language: track.metadata?.language,
            releaseDate: track.metadata?.releaseDate,
            mediaLinks: track.metadata?.mediaLinks,
            songRelationships: track.metadata?.songRelationships
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
            let hits = try await service.search(query: query, token: token, stripNoise: false)
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

// MARK: - Flow layout for media link pills

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x - spacing)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), origins)
    }
}
