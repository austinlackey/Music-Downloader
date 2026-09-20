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
    @State private var showingUnavailable = false
    @State private var showingAddSong = false
    @State private var showingMetadataTable = false
    @State private var isRefreshing = false
    @State private var trackPendingDelete: Track?
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

            if job.tracks.isEmpty && job.discoveredFiles.isEmpty {
                ContentUnavailableView(
                    "Loading tracks…",
                    systemImage: "magnifyingglass",
                    description: Text("Fetching playlist metadata from YouTube.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Found-on-disk files sit above the playlist rather than
                    // behind a disclosure: the whole point is that the user
                    // sees them and decides, and a row they have to go looking
                    // for is a row they won't act on.
                    if !job.discoveredFiles.isEmpty {
                        Section {
                            ForEach(job.discoveredFiles) { file in
                                discoveredRow(file)
                            }
                        } header: {
                            discoveredHeader
                        }
                    }

                    Section {
                        ForEach(sortedFilteredTracks, id: \.element.id) { idx, track in
                            TrackRow(track: track, index: idx + 1)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if track.fileURL != nil {
                                        inspectedTrack = track
                                    }
                                }
                                .contextMenu { trackMenu(track) }
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
                if !job.isActive {
                    Button {
                        showingAddSong = true
                    } label: {
                        Label("Add Song", systemImage: "plus.circle")
                    }
                    .help("Paste a YouTube link to add one song to this playlist")
                }
            }
            ToolbarItem(placement: .automatic) {
                if !job.isActive {
                    Button {
                        refreshFolder()
                    } label: {
                        Label("Refresh Folder", systemImage: "arrow.clockwise")
                    }
                    .disabled(job.syncFolderURL == nil || isRefreshing)
                    .help(job.folderSyncUnavailableReason
                          ?? "Check the folder for songs added or removed outside the app")
                }
            }
            ToolbarItem(placement: .automatic) {
                if !job.isActive && !job.tracks.isEmpty {
                    Button {
                        showingMetadataTable = true
                    } label: {
                        Label("Metadata Table", systemImage: "tablecells")
                    }
                    .help("Add custom fields — movie, year, director — across the whole set")
                }
            }
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
        .sheet(isPresented: $showingMetadataTable) {
            BulkMetadataSheet(job: job)
        }
        .sheet(isPresented: $showingMergeReview) {
            MergeReviewView(job: job)
        }
        .sheet(isPresented: $showingAddSong) {
            AddSongSheet(job: job)
        }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { trackPendingDelete != nil },
                set: { if !$0 { trackPendingDelete = nil } }
            ),
            presenting: trackPendingDelete
        ) { track in
            Button("Move to Trash", role: .destructive) {
                trackPendingDelete = nil
                Task {
                    await store.deleteTrack(track, from: job, settings: settings)
                    validatePaths()
                }
            }
            Button("Cancel", role: .cancel) { trackPendingDelete = nil }
        } message: { track in
            Text(deleteConfirmationMessage(for: track))
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
            // Songs get added to and removed from these folders in Finder, so
            // opening the playlist is exactly when we should look.
            refreshFolder()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                validatePaths()
                refreshFolder()
            }
        }
    }

    // MARK: - Search & Sort

    private var sortedFilteredTracks: [(offset: Int, element: Track)] {
        // Dead entries are reported in their own banner, not mixed into the
        // song list — they have no file, no metadata, and nothing to act on.
        let listable = job.availableTracks
        let filtered: [(offset: Int, element: Track)]
        if searchText.isEmpty {
            filtered = Array(listable.enumerated()).map { (offset: $0.offset, element: $0.element) }
        } else {
            let query = searchText.lowercased()
            filtered = Array(listable.enumerated())
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

    /// Reconciles the folder against the track list, then re-derives the
    /// banners from what the scan found.
    private func refreshFolder() {
        // A download in flight is *supposed* to be putting new files in this
        // folder; reporting its own output as an unexpected find would be
        // noise at best.
        guard !isRefreshing, !job.isActive else { return }
        isRefreshing = true
        Task {
            await store.refreshFolder(job: job, settings: settings)
            validatePaths()
            isRefreshing = false
        }
    }

    // MARK: - Per-song menu

    /// The right-click menu on a song row.
    ///
    /// Splits the two ways of getting rid of a song, because they are not the
    /// same decision: leaving a playlist is cheap and reversible, and losing
    /// the file is neither.
    @ViewBuilder
    private func trackMenu(_ track: Track) -> some View {
        if track.fileURL != nil, !track.isFileMissing {
            Button("Inspect & Re-match…") { inspectedTrack = track }
            Button("Show in Finder") { store.revealTrackInFinder(track) }
            Divider()
        }

        if track.isFileMissing || track.status == .failed || track.status == .unavailable {
            Button("Download Again") {
                store.redownloadTrack(track, in: job, settings: settings)
            }
            Divider()
        }

        Button("Remove from Playlist") {
            store.removeTrack(track, from: job)
            validatePaths()
        }
        if track.fileURL != nil, !track.isFileMissing {
            Button("Move File to Trash…", role: .destructive) {
                trackPendingDelete = track
            }
        }
    }

    private func deleteConfirmationMessage(for track: Track) -> String {
        let name = track.metadata?.title ?? track.title
        let inLibrary = track.fileURL.map {
            $0.standardizedFileURL.path.hasPrefix(settings.libraryRoot.standardizedFileURL.path + "/")
        } ?? false
        if inLibrary {
            return "“\(name)” moves to the Trash and leaves your library and this playlist. Other playlists that use it will show it as missing."
        }
        return "“\(name)” moves to the Trash and leaves this playlist."
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

    /// Songs the playlist still lists but whose files are gone from the folder.
    ///
    /// Offers both ways out — fetch them again, or accept the deletion and
    /// drop them from the playlist — because either can be what the user meant
    /// when they moved the file.
    private var missingFilesBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text("\(missingFileCount) song\(missingFileCount == 1 ? "" : "s") missing from the folder")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Download Again") {
                for track in job.missingTracks {
                    store.redownloadTrack(track, in: job, settings: settings)
                }
                validatePaths()
            }
            .controlSize(.small)
            Button("Remove from Playlist", role: .destructive) {
                store.removeTracks(job.missingTracks, from: job)
                validatePaths()
            }
            .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Header for the found-on-disk section, with the bulk action.
    private var discoveredHeader: some View {
        let count = job.discoveredFiles.count
        return HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
            Text("\(count) new file\(count == 1 ? "" : "s") in this folder")
                .fontWeight(.semibold)
            Text("— not in the playlist yet. Adding one keeps the tags it already has.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Add All") {
                addAllDiscovered()
            }
            .controlSize(.small)
            Button("Ignore") {
                job.discoveredFiles = []
            }
            .controlSize(.small)
            .help("Hide these until the next refresh")
        }
        .font(.caption)
        .foregroundStyle(.blue)
    }

    /// One found-on-disk file, laid out to line up with the song rows below it.
    private func discoveredRow(_ file: DiscoveredFile) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "doc.badge.plus")
                .foregroundStyle(.blue)
                .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .lineLimit(1)
                Text(file.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            Text(file.artist ?? "—")
                .font(.subheadline)
                .foregroundStyle(file.artist != nil ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
                .padding(.trailing, 8)

            Text(file.album ?? "—")
                .font(.subheadline)
                .foregroundStyle(file.album != nil ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
                .padding(.trailing, 8)

            Button("Add") {
                Task {
                    await store.adoptDiscoveredFile(file, into: job, settings: settings)
                    validatePaths()
                }
            }
            .controlSize(.small)
            .frame(width: 98, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Add to Playlist") {
                Task {
                    await store.adoptDiscoveredFile(file, into: job, settings: settings)
                    validatePaths()
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
    }

    private func addAllDiscovered() {
        let files = job.discoveredFiles
        Task {
            for file in files {
                await store.adoptDiscoveredFile(file, into: job, settings: settings)
            }
            validatePaths()
        }
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

            if job.unavailableCount > 0 {
                unavailableBanner
            }

            if !job.isActive, job.failedCount > 0 {
                failedBanner
            }

            if let failure = job.failureKind, job.status == .failed {
                outdatedDownloaderBanner(failure)
            } else if let error = job.errorMessage, job.status == .failed {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// A run that failed because the bundled yt-dlp aged out.
    ///
    /// Replaces the raw stderr dump, which for this failure is dozens of
    /// identical "HTTP Error 403: Forbidden" lines — technically the truth, but
    /// it reads as "this app is broken" and hides the one thing that fixes it.
    ///
    /// Strictly one line, for the same reason `unavailableBanner` is: `header`
    /// has no scroll view of its own, so a banner that wraps pushes the track
    /// list off-screen and widens the detail column until the sidebar
    /// collapses. The full explanation lives in the tooltip.
    private func outdatedDownloaderBanner(_ failure: RunFailureKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: failure.symbolName)
            Text(failure.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Check for Updates…") {
                NotificationCenter.default.post(
                    name: .checkForUpdatesRequested,
                    object: nil
                )
            }
            .controlSize(.small)
        }
        .font(.caption)
        .help(failure.explanation)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Songs the download choked on. Separate from `unavailableBanner`
    /// because the fix is different: these videos still exist, so fetching
    /// them again is the first thing to try.
    ///
    /// Both buttons clear the run's failed badge once nothing is left failing
    /// — the whole point of offering them here rather than one row at a time.
    ///
    /// One line, for the reason the banners around it are: `header` has no
    /// scroll view, so a banner that wraps pushes the track list off-screen.
    private var failedBanner: some View {
        let failed = job.failedTracks
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(failed.count) song\(failed.count == 1 ? "" : "s") didn't download")
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Download Again") {
                for track in failed {
                    store.redownloadTrack(track, in: job, settings: settings)
                }
            }
            .controlSize(.small)
            .help("Try these songs again")

            Button("Remove from Playlist", role: .destructive) {
                store.removeTracks(failed, from: job)
                validatePaths()
            }
            .controlSize(.small)
            .help("Drop these entries so the playlist reflects what you actually have")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Playlists outlive their videos. State that plainly instead of leaving
    /// yt-dlp's raw stderr on screen, which reads like the download broke.
    ///
    /// The list lives in a popover rather than expanding inline: `header` sits
    /// above the track List with no scroll view of its own, so growing it
    /// pushes the songs off-screen, and untruncated titles drag the detail
    /// column's ideal width wide enough to collapse the sidebar.
    private var unavailableBanner: some View {
        let count = job.unavailableCount
        let ageRestricted = job.unavailableTracks(of: .ageRestricted)
        return HStack(spacing: 8) {
            Image(systemName: job.hasAgeRestrictedTracks
                  ? "person.crop.circle.badge.exclamationmark"
                  : "eye.slash")
            Text("\(count) song\(count == 1 ? "" : "s") YouTube wouldn't serve")
                .lineLimit(1)

            Button {
                showingUnavailable = true
            } label: {
                HStack(spacing: 2) {
                    Text("Details")
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingUnavailable, arrowEdge: .bottom) {
                unavailableList
            }

            Spacer(minLength: 8)

            // The age gate is the one cause a retry can clear, so it gets its
            // own button rather than being lumped in with the dead videos.
            if !ageRestricted.isEmpty {
                Button(settings.cookiesFromBrowser == nil
                       ? "Retry (needs cookies)"
                       : "Retry \(ageRestricted.count) Age-Restricted") {
                    for track in ageRestricted {
                        store.redownloadTrack(track, in: job, settings: settings)
                    }
                }
                .controlSize(.small)
                .disabled(settings.cookiesFromBrowser == nil)
                .help(settings.cookiesFromBrowser == nil
                      ? "Turn on browser cookies in Settings (⌘,) so YouTube will serve these"
                      : "Fetch these again using your \(settings.cookieBrowser.capitalized) YouTube session")
            }

            Button("Remove from Playlist", role: .destructive) {
                store.removeTracks(job.unavailableTracks, from: job)
            }
            .controlSize(.small)
            .help("Drop these entries from the playlist for good")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Fixed width so long titles wrap inside the popover instead of widening
    /// it, and a capped scroll height so a badly rotted playlist stays usable.
    private var unavailableList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(UnavailableKind.allCases, id: \.self) { kind in
                    let tracks = job.unavailableTracks(of: kind)
                    if !tracks.isEmpty {
                        unavailableSection(kind: kind, tracks: tracks)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 360, height: 320)
    }

    /// One cause, its explanation, and the songs it accounts for.
    ///
    /// Read-only: the actions live on the banner, where a click is one step
    /// away rather than two.
    @ViewBuilder
    private func unavailableSection(kind: UnavailableKind, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                Text(kind.groupTitle)
                    .font(.headline)
                Spacer()
                Text("\(tracks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(kind.groupExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                ForEach(tracks) { track in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title.isEmpty ? track.id : track.title)
                            .font(.caption)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reason = track.unavailableReason {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
