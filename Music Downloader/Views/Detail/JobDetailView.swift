import SwiftUI

struct JobDetailView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Bindable var job: DownloadJob

    @State private var inspectedTrack: Track?
    @State private var showingEnrichConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)

            Divider()

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
                        ForEach(Array(job.tracks.enumerated()), id: \.element.id) { idx, track in
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
                        HStack {
                            Text("Tracks")
                            Spacer()
                            Text(trackSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .navigationTitle(job.playlistTitle)
        .navigationSubtitle(job.status.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if job.isActive {
                    Button(role: .destructive) {
                        store.cancel(job)
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
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
        }
        .alert("Enrich Metadata?", isPresented: $showingEnrichConfirm) {
            Button("Enrich", role: .none) {
                store.enrich(job: job, settings: settings)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will search Genius for \(pendingEnrichCount) track\(pendingEnrichCount == 1 ? "" : "s"), inject ID3 tags with artist/album/cover art, and rename files using your template.")
        }
        .sheet(item: $inspectedTrack) { track in
            TrackInspectorSheet(track: track, job: job)
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
            $0.fileURL != nil && $0.enrichmentStatus != .enriched && $0.enrichmentStatus != .skipped
        }.count
    }

    private var canEnrich: Bool {
        pendingEnrichCount > 0 && !settings.geniusToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enrichButtonTitle: String {
        let enrichedCount = job.tracks.filter { $0.enrichmentStatus == .enriched }.count
        if enrichedCount > 0 && pendingEnrichCount > 0 {
            return "Enrich Remaining"
        }
        return "Enrich Metadata"
    }

    private var enrichButtonHelp: String {
        if settings.geniusToken.isEmpty {
            return "Set your Genius API token in Settings first (⌘,)"
        }
        if pendingEnrichCount == 0 {
            return "All tracks already enriched"
        }
        return "Auto-match \(pendingEnrichCount) track\(pendingEnrichCount == 1 ? "" : "s") on Genius and inject tags"
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
