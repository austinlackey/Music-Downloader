//
//  Music_DownloaderApp.swift
//  Music Downloader
//
//  Created by Austin Lackey on 4/8/26.
//

import SwiftUI

@main
struct Music_DownloaderApp: App {
    @State private var store = DownloadStore()
    @State private var settings = AppSettings()
    @State private var playback = PlaybackController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(settings)
                .environment(playback)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download…") {
                    NotificationCenter.default.post(name: .newDownloadRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}

extension Notification.Name {
    static let newDownloadRequested = Notification.Name("newDownloadRequested")
}
