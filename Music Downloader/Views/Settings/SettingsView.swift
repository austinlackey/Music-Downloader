import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            LibrarySettingsTab()
                .tabItem { Label("Library", systemImage: "folder") }

            MetadataSettingsTab()
                .tabItem { Label("Metadata", systemImage: "sparkles") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - Library tab

private struct LibrarySettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Download Location") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(settings.downloadRoot.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            pickFolder(startingAt: settings.downloadRoot) {
                                settings.downloadRoot = $0
                            }
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.downloadRoot])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")
                    }
                }
            }

            Section("Audio") {
                Picker("Format", selection: $settings.audioFormat) {
                    ForEach(AppSettings.supportedFormats, id: \.self) { fmt in
                        Text(fmt.uppercased()).tag(fmt)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("Quality") {
                    Text("Best available")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder(startingAt: URL, apply: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        if panel.runModal() == .OK, let url = panel.url {
            apply(url)
        }
    }
}

// MARK: - Metadata (Genius) tab

private struct MetadataSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                SecureField("Client Access Token", text: $settings.geniusToken)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Get a free token at")
                        .foregroundStyle(.secondary)
                    Link("genius.com/api-clients",
                         destination: URL(string: "https://genius.com/api-clients")!)
                }
                .font(.caption)
                Toggle("Strip parentheses & brackets from search", isOn: $settings.stripSearchNoise)

            } header: {
                Text("Genius API")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Required to auto-match tracks and pull artist, album, year, and cover art.")
                    Text("When stripping is enabled, text like (feat. X) or [Official Video] is removed before searching Genius.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextField("Filename template", text: $settings.renameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                LabeledContent("Preview") {
                    Text(FilenameTemplate.render(
                        template: settings.renameTemplate,
                        metadata: .sample,
                        trackNumber: 3,
                        originalName: "Me at the zoo"
                    ) + ".mp3")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Button("Reset to default") {
                    settings.renameTemplate = FilenameTemplate.defaultTemplate
                }
                .controlSize(.small)
            } header: {
                Text("Filename Template")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Placeholders:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(FilenameTemplate.placeholders, id: \.0) { token, description in
                        HStack(spacing: 6) {
                            Text(token)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About tab

private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Engine", value: "yt-dlp + ffmpeg (bundled)")
                LabeledContent("Metadata source", value: "Genius API")
            }
        }
        .formStyle(.grouped)
    }
}
