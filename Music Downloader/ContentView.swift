//
//  ContentView.swift
//  Music Downloader
//
//  Created by Austin Lackey on 4/8/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback

    @State private var selection: SidebarSelection?
    @State private var showingNewDownload = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The job the sidebar is pointing at, if it's pointing at one at all.
    private var selectedJob: DownloadJob? {
        guard case .job(let id) = selection else { return nil }
        return store.jobs.first { $0.id == id }
    }

    private var isShowingLibrary: Bool { selection == .library }

    /// Split out of `body` — inlining it makes the type-checker give up on
    /// the whole `NavigationSplitView` expression.
    @ViewBuilder
    private var detailContent: some View {
        if isShowingLibrary {
            LibraryView()
        } else if let job = selectedJob {
            JobDetailView(job: job)
        } else {
            EmptyDetailView { showingNewDownload = true }
        }
    }

    /// The split view proper. The player bar sits beside it in `body` rather
    /// than being attached to it: see the note there.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detailContent
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showingNewDownload = true
                    } label: {
                        Label("New Download", systemImage: "plus")
                    }
                    .help("New Download (⌘N)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let job = selectedJob {
                            store.revealInFinder(job)
                        } else if selection == .library {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.libraryRoot])
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.downloadRoot])
                        }
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show in Finder")
                }
            }
        }
        .sheet(isPresented: $showingNewDownload) {
            NewDownloadSheet { url, mode in
                store.startDownload(url: url, mode: mode, settings: settings)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDownloadRequested)) { _ in
            showingNewDownload = true
        }
        .onAppear {
            guard selection == nil else { return }
            // Prefer a job that's waiting on the user, then the most recent
            // job, then fall back to the library.
            if let staged = store.jobs.first(where: \.awaitsMerge) {
                selection = .job(staged.id)
            } else if let recent = store.jobs.first {
                selection = .job(recent.id)
            } else {
                selection = .library
            }
        }
    }

    var body: some View {
        // The player bar gets its own row in a VStack instead of being a
        // `.safeAreaInset` on the split view. An inset applied to a
        // NavigationSplitView never reaches the columns' scroll views, so the
        // bar painted over the last track row and the bottom of the scroller
        // instead of shortening the lists.
        VStack(spacing: 0) {
            splitView

            if playback.currentTrack != nil {
                PlayerBar()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.currentTrack?.id)
    }
}
