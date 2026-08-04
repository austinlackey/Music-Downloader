import AppKit
import SwiftUI

/// Builds an export folder to copy to the iPad.
struct ExportSheet: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var scope: ExportBuilder.Scope = .newOnly
    @State private var totalCount = 0
    @State private var newCount = 0
    @State private var isExporting = false
    @State private var result: ExportBuilder.Result?
    @State private var errorMessage: String?

    private var selectedCount: Int {
        switch scope {
        case .full:    totalCount
        case .newOnly: newCount
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Export for iPad")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Creates a folder to copy into BingoBite on the iPad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("What to export", selection: $scope) {
                Text("New since last export (\(newCount))").tag(ExportBuilder.Scope.newOnly)
                Text("Everything (\(totalCount))").tag(ExportBuilder.Scope.full)
            }
            .pickerStyle(.radioGroup)

            Text(scopeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(settings.exportRoot.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExporting)
                Button {
                    Task { await runExport() }
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export \(selectedCount)", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting || selectedCount == 0)
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
        .task { await loadCounts() }
        .alert(
            "Export complete",
            isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })
        ) {
            Button("Show in Finder") {
                if let folder = result?.folderURL {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                result = nil
                dismiss()
            }
            Button("Done") {
                result = nil
                dismiss()
            }
        } message: {
            if let result { Text(summary(for: result)) }
        }
    }

    private var scopeExplanation: String {
        switch scope {
        case .newOnly:
            "Copies only songs you haven't exported before. Playlists can still reference songs from earlier exports — BingoBite matches them against what's already on the iPad."
        case .full:
            "Copies your entire library. Use this for a new iPad, or if the songs on the iPad were deleted."
        }
    }

    private func loadCounts() async {
        totalCount = await store.libraryEntries(settings: settings).count
        newCount = await store.unexportedCount(settings: settings)
        // Nothing new to send — default to a full export so the primary button
        // isn't disabled on arrival.
        if newCount == 0 && totalCount > 0 { scope = .full }
    }

    private func runExport() async {
        isExporting = true
        errorMessage = nil
        do {
            result = try await store.exportForIPad(scope: scope, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
        isExporting = false
    }

    private func summary(for result: ExportBuilder.Result) -> String {
        var parts = ["\(result.songsExported) song\(result.songsExported == 1 ? "" : "s")"]
        if result.playlistsIncluded > 0 {
            parts.append("\(result.playlistsIncluded) playlist\(result.playlistsIncluded == 1 ? "" : "s")")
        }
        if result.bytesCopied > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: result.bytesCopied, countStyle: .file))
        }
        var text = "Exported \(parts.joined(separator: ", ")) to \(result.folderURL.lastPathComponent)."
        if !result.failures.isEmpty {
            text += "\n\n\(result.failures.count) file\(result.failures.count == 1 ? "" : "s") could not be copied."
        }
        return text
    }
}

extension ExportBuilder.Scope: Hashable {}
