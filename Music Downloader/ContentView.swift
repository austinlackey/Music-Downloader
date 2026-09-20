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

    /// Height of the player bar, measured rather than hard-coded so the
    /// columns' insets keep up with Dynamic Type and any later change to
    /// what the bar contains.
    @State private var playerBarHeight: CGFloat = 0

    /// How much of the bottom of each column the player bar is covering.
    private var playerBarInset: CGFloat {
        playback.currentTrack != nil ? playerBarHeight : 0
    }

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

    /// The split view proper. The player bar is layered over this in `body`
    /// rather than attached to it: see the note there.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: playerBarInset)
                }
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: playerBarInset)
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
        // The bar floats over the split view so the lists keep scrolling
        // under its material, and each column carries a matching bottom
        // safe-area inset so no row is stranded beneath it. The inset has to
        // go on the columns: applied to the NavigationSplitView itself it
        // never reaches their scroll views, which is how the bar ended up
        // covering the last track of a playlist and the end of the scroller.
        splitView
            .overlay(alignment: .bottom) {
                if playback.currentTrack != nil {
                    PlayerBar()
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            playerBarHeight = height
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: playback.currentTrack?.id)
    }
}
