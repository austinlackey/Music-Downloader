import SwiftUI

enum TrackSortField: String, CaseIterable {
    case number = "#"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case status = "Status"
}

enum SortDirection {
    case ascending, descending
    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct JobDetailView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Bindable var job: DownloadJob

    @State private var inspectedTrack: Track?
    @State private var showingEnrichConfirm = false
    @State private var showingClearConfirm = false
    @State private var showingRemoveConfirm = false
    @State private var showingMergeReview = false
    @State private var showingSongList = false
    @State private var folderMissing = false
    @State private var missingFileCount = 0
    @State private var searchText = ""
    @State private var sortField: TrackSortField = .number
    @State private var sortDirection: SortDirection = .ascending
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)

            Divider()

            if folderMissing {
                missingFolderBanner
                    .padding(20)
            } else if missingFileCount > 0 {
                missingFilesBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if job.tracks.isEmpty {
                ContentUnavailableView(
                    "Loading tracks…",
                    systemImage: "magnifyingglass",
                    description: Text("Fetching playlist metadata from YouTube.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(sortedFilteredTracks, id: \.element.id) { idx, track in
                            TrackRow(track: track, index: idx + 1)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if track.fileURL != nil {
                                        inspectedTrack = track
                                    }
                                }
                                .contextMenu {
                                    if track.fileURL != nil {
                                        Button("Inspect & Re-match…") {
                                            inspectedTrack = track
                                        }
                                        Button("Show in Finder") {
                                            store.revealTrackInFinder(track)
                                        }
                                    }
                                }
                        }
                    } header: {
                        columnHeader
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .searchable(text: $searchText, prompt: "Search tracks…")
            }
        }
        .navigationTitle(job.playlistTitle)
        .navigationSubtitle(job.status.displayName)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if !job.isActive && hasEnrichedTracks {
                    Button {
                        showingSongList = true
                    } label: {
                        Label("Export Song List", systemImage: "list.bullet.rectangle")
                    }
                    .help("Copy a pasteable song list for BingoBite")
                }
            }
            ToolbarItem(placement: .automatic) {
                if !job.isActive && hasEnrichedTracks {
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Label("Clear Metadata", systemImage: "arrow.uturn.backward")
                    }
                    .help("Revert all filenames and clear Genius metadata")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if job.isActive {
                    Button(role: .destructive) {
                        store.cancel(job)
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                } else if job.awaitsMerge {
                    // A staged job's next step is merging, not enriching —
                    // though enrichment is still available from the menu below.
                    Button {
                        showingMergeReview = true
                    } label: {
                        Label("Review & Merge…", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Check these tracks against your library, then merge them in")
                } else {
                    Button {
                        showingEnrichConfirm = true
                    } label: {
                        Label(enrichButtonTitle, systemImage: "sparkles")
                    }
                    .disabled(!canEnrich)
                    .help(enrichButtonHelp)
                }
            }
            if job.awaitsMerge {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingEnrichConfirm = true
                    } label: {
                        Label(enrichButtonTitle, systemImage: "sparkles")
                    }
                    .disabled(!canEnrich)
                    .help("Enrich before merging so duplicate detection can use Genius data")
                }
            }
        }
        .sheet(isPresented: $showingMergeReview) {
            MergeReviewView(job: job)
        }
        .sheet(isPresented: $showingSongList) {
            PlaylistTextExportSheet(job: job)
        }
        .alert("Clear All Metadata?", isPresented: $showingClearConfirm) {
            Button("Clear", role: .destructive) {
                store.clearAllMetadata(job: job, settings: settings)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will revert all filenames to their original names and remove all Genius metadata. You can re-enrich afterwards.")
        }
        .alert("Enrich Metadata?", isPresented: $showingEnrichConfirm) {
            Button("Enrich", role: .none) {
                store.enrich(job: job, settings: settings, force: shouldForceReenrich)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(enrichConfirmationMessage)
        }
        .sheet(item: $inspectedTrack) { track in
            TrackInspectorSheet(track: track, job: job)
        }
        .alert("Remove from List?", isPresented: $showingRemoveConfirm) {
            Button("Remove", role: .destructive) {
                store.remove(job)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The download folder no longer exists. Remove this job from the list?")
        }
        .onAppear {
            validatePaths()
            Task {
                await store.hydrateLibraryReferences(job: job, settings: settings)
                validatePaths()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { validatePaths() }
        }
    }

    // MARK: - Search & Sort

    private var sortedFilteredTracks: [(offset: Int, element: Track)] {
        let filtered: [(offset: Int, element: Track)]
        if searchText.isEmpty {
            filtered = Array(job.tracks.enumerated()).map { (offset: $0.offset, element: $0.element) }
        } else {
            let query = searchText.lowercased()
            filtered = Array(job.tracks.enumerated())
                .map { (offset: $0.offset, element: $0.element) }
                .filter { _, track in
                    track.title.lowercased().contains(query)
                    || (track.metadata?.artist.lowercased().contains(query) ?? false)
                    || (track.metadata?.album?.lowercased().contains(query) ?? false)
                }
        }

        let sorted = filtered.sorted { a, b in
            let result: Bool
            switch sortField {
            case .number:
                result = a.offset < b.offset
            case .title:
                let tA = a.element.metadata?.title ?? a.element.title
                let tB = b.element.metadata?.title ?? b.element.title
                result = tA.localizedCaseInsensitiveCompare(tB) == .orderedAscending
            case .artist:
                let artA = a.element.metadata?.artist ?? ""
                let artB = b.element.metadata?.artist ?? ""
                result = artA.localizedCaseInsensitiveCompare(artB) == .orderedAscending
            case .album:
                let albA = a.element.metadata?.album ?? ""
                let albB = b.element.metadata?.album ?? ""
                result = albA.localizedCaseInsensitiveCompare(albB) == .orderedAscending
            case .status:
                result = a.element.status.sortOrder < b.element.status.sortOrder
            }
            return sortDirection == .ascending ? result : !result
        }
        return sorted
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            sortButton(.number)
                .frame(width: 60, alignment: .leading)
            sortButton(.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            sortButton(.artist)
                .frame(width: 140, alignment: .leading)
                .padding(.trailing, 8)
            sortButton(.album)
                .frame(width: 140, alignment: .leading)
                .padding(.trailing, 8)
            sortButton(.status)
                .frame(width: 70, alignment: .leading)
            Text(trackSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 28)
        }
    }

    private func sortButton(_ field: TrackSortField) -> some View {
        Button {
            if sortField == field {
                sortDirection.toggle()
            } else {
                sortField = field
                sortDirection = .ascending
            }
        } label: {
            HStack(spacing: 3) {
                Text(field.rawValue)
                    .font(.caption)
                    .fontWeight(sortField == field ? .semibold : .regular)
                if sortField == field {
                    Image(systemName: sortDirection == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(sortField == field ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func validatePaths() {
        folderMissing = job.isFolderMissing
        missingFileCount = job.tracks.filter(\.isFileMissing).count
    }

    // MARK: - Missing banners

    private var missingFolderBanner: some View {
        VStack(spacing: 10) {
            Label("Folder not found", systemImage: "folder.badge.questionmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The download folder has been deleted or moved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove from List", role: .destructive) {
                showingRemoveConfirm = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingFilesBanner: some View {
        Label(
            "\(missingFileCount) file\(missingFileCount == 1 ? "" : "s") missing from disk",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var trackSummary: String {
        let total = job.totalCount
        let done = job.completedCount
        let enriched = job.tracks.filter { $0.enrichmentStatus == .enriched }.count
        if enriched > 0 {
            return "\(done) downloaded · \(enriched) tagged · \(total) total"
        }
        return "\(done) of \(total) complete"
    }

    private var pendingEnrichCount: Int {
        job.tracks.filter {
            $0.fileURL != nil
                && $0.status == .completed
                && !$0.isFileMissing
                && $0.enrichmentStatus != .enriched
                && $0.enrichmentStatus != .skipped
        }.count
    }

    private var reEnrichCount: Int {
        job.tracks.filter {
            $0.fileURL != nil && $0.status == .completed && !$0.isFileMissing
        }.count
    }

    private var hasEnrichedTracks: Bool {
        job.tracks.contains { $0.enrichmentStatus == .enriched || $0.metadata != nil }
    }

    private var canEnrich: Bool {
        (pendingEnrichCount > 0 || reEnrichCount > 0)
            && !settings.geniusToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enrichButtonTitle: String {
        let enrichedCount = job.tracks.filter { $0.enrichmentStatus == .enriched }.count
        if enrichedCount > 0 && pendingEnrichCount > 0 {
            return "Enrich Remaining"
        }
        if pendingEnrichCount == 0 && reEnrichCount > 0 {
            return "Re-enrich Metadata"
        }
        return "Enrich Metadata"
    }

    private var enrichButtonHelp: String {
        if settings.geniusToken.isEmpty {
            return "Set your Genius API token in Settings first (⌘,)"
        }
        if pendingEnrichCount == 0 {
            return reEnrichCount > 0
                ? "Re-run Genius matching and rewrite tags for \(reEnrichCount) file\(reEnrichCount == 1 ? "" : "s")"
                : "No file-backed tracks are available to enrich"
        }
        return "Auto-match \(pendingEnrichCount) track\(pendingEnrichCount == 1 ? "" : "s") on Genius and inject tags"
    }

    private var shouldForceReenrich: Bool {
        pendingEnrichCount == 0 && reEnrichCount > 0
    }

    private var enrichConfirmationMessage: String {
        if shouldForceReenrich {
            return "This will re-search Genius for \(reEnrichCount) file-backed track\(reEnrichCount == 1 ? "" : "s"), rewrite ID3 tags with artist/album/cover art, and rename files using your template."
        }
        return "This will search Genius for \(pendingEnrichCount) track\(pendingEnrichCount == 1 ? "" : "s"), inject ID3 tags with artist/album/cover art, and rename files using your template."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: job.status.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(job.status.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: job.isActive)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.playlistTitle)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    Text(job.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                statusBadge
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: job.overallProgress) {
                    HStack {
                        Text("Overall Progress")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(job.overallProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .progressViewStyle(.linear)
                .tint(job.status.tint)
            }

            if let error = job.errorMessage, job.status == .failed {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var statusBadge: some View {
        Text(job.status.displayName.uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(job.status.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(job.status.tint)
    }
}
