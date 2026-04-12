import SwiftUI

struct JobRow: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: job.status.symbolName)
                    .foregroundStyle(job.status.tint)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, isActive: job.isActive)
                Text(job.playlistTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 13, weight: .medium))
            }

            ProgressView(value: job.overallProgress)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(job.status.tint)

            HStack {
                if job.isFolderMissing {
                    Text("Folder missing")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(job.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if job.totalCount > 0 {
                    Text("\(job.completedCount)/\(job.totalCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
    }
}
