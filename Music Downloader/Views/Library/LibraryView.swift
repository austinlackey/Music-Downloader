import AppKit
import SwiftUI

/// Browses the master library — every song that has passed merge review.
///
/// Reads from the ledger rather than scanning the folder, so it's instant even
/// with a few thousand songs. The ledger is the record of what was *merged*;
/// a file deleted by hand outside the app shows as missing.
struct LibraryView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var entries: [LibraryEntry] = []
    @State private var searchText = ""
    @State private var sortField: LibrarySortField = .artist
    @State private var isLoading = true
    @State private var showingExport = false
    @State private var unexportedCount = 0
    @State private var selectedEntryID: LibraryEntry.ID?

    private var filtered: [LibraryEntry] {
        let base: [LibraryEntry]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            base = entries
        } else {
            base = entries.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query)
                    || ($0.album?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return base.sorted(by: sortField.comparator)
    }

    private var selectedEntry: LibraryEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "books.vertical")
                } description: {
                    Text("Download a playlist in Library mode and merge it in.")
                }
            } else {
                content
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, prompt: "Search songs")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Sort", selection: $sortField) {
                    ForEach(LibrarySortField.allCases) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExport = true
                } label: {
                    Label("Export for iPad", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
                .help("Build a folder to copy into BingoBite on the iPad")
            }
        }
        .sheet(isPresented: $showingExport, onDismiss: { Task { await reload() } }) {
            ExportSheet()
        }
        .task(id: settings.libraryRoot) { await reload() }
        .task(id: store.libraryRevision) { await reload() }
    }

    private var subtitle: String {
        let count = entries.count
        let suffix = count == 1 ? "song" : "songs"
        if unexportedCount > 0 {
            return "\(count) \(suffix) · \(unexportedCount) not yet exported"
        }
        return "\(count) \(suffix)"
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            List(selection: $selectedEntryID) {
                ForEach(filtered) { entry in
                    LibraryRow(entry: entry, libraryRoot: settings.libraryRoot)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Show in Finder") {
                                let url = settings.libraryRoot.appendingPathComponent(entry.file)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            if let genius = entry.geniusURL, let url = URL(string: genius) {
                                Button("Open on Genius") { NSWorkspace.shared.open(url) }
                            }
                        }
                }
            }
            .alternatingRowBackgrounds()

            if let selectedEntry {
                LibrarySongDetailPane(
                    entry: selectedEntry,
                    memberships: store.playlistsContaining(uid: selectedEntry.uid),
                    libraryRoot: settings.libraryRoot
                ) {
                    selectedEntryID = nil
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.22), value: selectedEntryID)
    }

    private func reload() async {
        isLoading = true
        entries = await store.libraryEntries(settings: settings)
        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
        unexportedCount = entries.filter { $0.exportedAt == nil }.count
        isLoading = false
    }
}

enum LibrarySortField: String, CaseIterable, Identifiable {
    case artist
    case title
    case album
    case dateAdded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .artist:    "Artist"
        case .title:     "Title"
        case .album:     "Album"
        case .dateAdded: "Date Added"
        }
    }

    var comparator: (LibraryEntry, LibraryEntry) -> Bool {
        switch self {
        case .artist:
            { lhs, rhs in
                let primary = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
                if primary != .orderedSame { return primary == .orderedAscending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .title:
            { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .album:
            { ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending }
        case .dateAdded:
            // Newest first — the interesting end when you've just merged.
            { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        }
    }
}
