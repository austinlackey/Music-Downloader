import SwiftUI

/// Adds a single YouTube video to a playlist that already exists.
///
/// Separate from `NewDownloadSheet`, which starts a whole job: here the
/// destination is already decided, so the only question is which song.
struct AddSongSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings

    let job: DownloadJob

    @State private var url = ""
    @State private var isWorking = false
    @State private var message: String?
    @FocusState private var urlFieldFocused: Bool

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let parsed = URL(string: trimmedURL) else { return false }
        let host = parsed.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    /// Where the file will actually land, which is the same folder the rest of
    /// this playlist lives in.
    private var destination: URL {
        job.syncFolderURL ?? job.folderURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a Song")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste a YouTube video link. It downloads into “\(job.playlistTitle)” and is tagged like the rest of the playlist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://www.youtube.com/watch?v=…", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .disabled(isWorking)
                    .onSubmit(submit)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(destination.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if let message {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    Label("Add Song", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidURL || isWorking)
            }
        }
        .padding(24)
        .frame(width: 520, height: 340)
        .onAppear {
            urlFieldFocused = true
            if let pasted = NSPasteboard.general.string(forType: .string),
               URL(string: pasted)?.host?.lowercased().contains("youtu") == true {
                url = pasted
            }
        }
    }

    private func submit() {
        guard isValidURL, !isWorking else { return }
        isWorking = true
        message = nil
        let requested = trimmedURL
        Task {
            let result = await store.addSong(url: requested, to: job, settings: settings)
            isWorking = false
            if let result {
                message = result
            } else {
                // Downloaded cleanly — the row in the list says the rest.
                dismiss()
            }
            url = ""
        }
    }
}
