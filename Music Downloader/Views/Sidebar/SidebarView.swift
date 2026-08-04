import SwiftUI

/// What the detail pane is showing. Replaces the bare `DownloadJob.ID?`
/// binding now that the sidebar has destinations that aren't jobs.
enum SidebarSelection: Hashable {
    case library
    case job(UUID)
}

struct SidebarView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: SidebarSelection?

    /// Jobs sitting in staging waiting for the user to review and merge them.
    /// Pulled into their own section because they're the one thing here that
    /// needs action rather than just existing.
    private var stagedJobs: [DownloadJob] {
        store.jobs.filter(\.awaitsMerge)
    }

    private var otherJobs: [DownloadJob] {
        store.jobs.filter { !$0.awaitsMerge }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Songs", systemImage: "books.vertical")
                    .tag(SidebarSelection.library)
            }

            if !stagedJobs.isEmpty {
                Section {
                    ForEach(stagedJobs) { job in
                        JobRow(job: job)
                            .tag(SidebarSelection.job(job.id))
                            .contextMenu { jobMenu(job) }
                    }
                } header: {
                    HStack {
                        Text("Ready to Merge")
                        Spacer()
                        Text("\(stagedJobs.count)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if otherJobs.isEmpty && stagedJobs.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "music.note.list",
                        description: Text("Press ⌘N to start one.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else if !otherJobs.isEmpty {
                Section("Downloads") {
                    ForEach(otherJobs) { job in
                        JobRow(job: job)
                            .tag(SidebarSelection.job(job.id))
                            .contextMenu { jobMenu(job) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Music Downloader")
    }

    @ViewBuilder
    private func jobMenu(_ job: DownloadJob) -> some View {
        Button("Show in Finder") { store.revealInFinder(job) }
        if job.isActive {
            Button("Cancel") { store.cancel(job) }
        }
        Divider()
        Button("Remove from List", role: .destructive) {
            if selection == .job(job.id) { selection = nil }
            store.remove(job)
        }
    }
}
