import SwiftUI

struct SidebarView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: DownloadJob.ID?

    var body: some View {
        List(selection: $selection) {
            if store.jobs.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "music.note.list",
                        description: Text("Press ⌘N to start one.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Downloads") {
                    ForEach(store.jobs) { job in
                        JobRow(job: job)
                            .tag(job.id)
                            .contextMenu {
                                Button("Show in Finder") { store.revealInFinder(job) }
                                if job.isActive {
                                    Button("Cancel") { store.cancel(job) }
                                }
                                Divider()
                                Button("Remove from List", role: .destructive) {
                                    if selection == job.id { selection = nil }
                                    store.remove(job)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Music Downloader")
    }
}
