import SwiftUI

struct NewDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var url: String = ""
    @State private var mode: DownloadMode = .library
    @FocusState private var urlFieldFocused: Bool

    let onSubmit: (String, DownloadMode) -> Void

    /// Where files will actually land, which differs by mode: library-mode
    /// downloads go to staging first and only reach the library after review.
    private var destinationDescription: String {
        switch mode {
        case .freshFolder: settings.downloadRoot.path
        case .library:     "Staging → review → \(settings.libraryRoot.path)"
        }
    }

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Mode", selection: $mode) {
                    ForEach(DownloadMode.allCases) { option in
                        Label(option.displayName, systemImage: option.symbolName)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: mode.symbolName)
                    .foregroundStyle(.secondary)
                Text(destinationDescription)
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
        .frame(width: 520, height: 400)
        .onAppear {
            urlFieldFocused = true
            mode = settings.defaultDownloadMode
            if let pasted = NSPasteboard.general.string(forType: .string),
               URL(string: pasted)?.host?.lowercased().contains("youtu") == true {
                url = pasted
            }
        }
    }

    private func submit() {
        guard isValidURL else { return }
        onSubmit(trimmedURL, mode)
        dismiss()
    }
}
