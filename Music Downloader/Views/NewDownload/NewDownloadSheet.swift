import SwiftUI

struct NewDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var url: String = ""
    @FocusState private var urlFieldFocused: Bool

    let onSubmit: (String) -> Void

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let parsed = URL(string: trimmedURL) else { return false }
        let host = parsed.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Download")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste a YouTube video or playlist URL.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://www.youtube.com/playlist?list=…", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .onSubmit(submit)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Will download to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.downloadRoot.path)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    Label("Start Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidURL)
            }
        }
        .padding(24)
        .frame(width: 520, height: 280)
        .onAppear {
            urlFieldFocused = true
            if let pasted = NSPasteboard.general.string(forType: .string),
               URL(string: pasted)?.host?.lowercased().contains("youtu") == true {
                url = pasted
            }
        }
    }

    private func submit() {
        guard isValidURL else { return }
        onSubmit(trimmedURL)
        dismiss()
    }
}
