import AppKit
import SwiftUI

/// Shows a job's song list as pasteable text, for building the same playlist
/// in BingoBite without retyping it.
///
/// This is the manual path — the manifest in an export folder does the same job
/// automatically. It exists for when you want one playlist rather than a whole
/// export, or want to hand the list to someone over a message.
struct PlaylistTextExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let job: DownloadJob

    @State private var text = ""
    @State private var didCopy = false

    /// Tracks with no metadata are left out — a line with a wrong artist
    /// matches worse than no line at all.
    private var skippedCount: Int {
        job.tracks.filter { $0.metadata == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Song List")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste this into BingoBite to recreate this playlist from your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if skippedCount > 0 {
                Label(
                    "\(skippedCount) track\(skippedCount == 1 ? " has" : "s have") no metadata yet and \(skippedCount == 1 ? "was" : "were") left out. Enrich the job first to include \(skippedCount == 1 ? "it" : "them").",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 480)
        .onAppear { text = PlaylistTextExporter.render(job: job) }
    }
}
