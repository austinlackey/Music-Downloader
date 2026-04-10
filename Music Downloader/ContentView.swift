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

    @State private var selection: DownloadJob.ID?
    @State private var showingNewDownload = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            Group {
                if let id = selection,
                   let job = store.jobs.first(where: { $0.id == id }) {
                    JobDetailView(job: job)
                } else {
                    EmptyDetailView {
                        showingNewDownload = true
                    }
                }
            }
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
                        if let id = selection,
                           let job = store.jobs.first(where: { $0.id == id }) {
                            store.revealInFinder(job)
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
            NewDownloadSheet { url in
                store.startDownload(url: url, settings: settings)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDownloadRequested)) { _ in
            showingNewDownload = true
        }
        .onAppear {
            // Auto-select the most recent job on launch.
            if selection == nil { selection = store.jobs.first?.id }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playback.currentTrack != nil {
                PlayerBar()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.currentTrack?.id)
    }
}
