import SwiftUI

struct EmptyDetailView: View {
    var onNewDownload: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Download Selected", systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text("Pick a download from the sidebar, or start a new one.")
        } actions: {
            Button {
                onNewDownload()
            } label: {
                Label("New Download", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
