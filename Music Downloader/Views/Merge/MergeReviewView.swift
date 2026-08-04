import SwiftUI

/// Reviews a staged job before its files move into the library.
///
/// Three buckets, ordered by how much attention they need:
/// **New** (nothing matched), **Duplicates** (confident matches, pre-skipped),
/// **Needs a look** (weak matches, kept by default). Nothing reaches the
/// library without passing through here.
struct MergeReviewView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let job: DownloadJob

    @State private var candidates: [MergeCandidate] = []
    @State private var isPreparing = true
    @State private var isMerging = false
    @State private var result: LibraryImporter.Result?
    @State private var expandedBuckets: Set<MergeBucket> = [.new, .duplicates]

    private func candidates(in bucket: MergeBucket) -> [MergeCandidate] {
        candidates.filter { $0.bucket == bucket }
    }

    private var addCount: Int {
        candidates.filter { $0.action != .skip }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isPreparing {
                ProgressView("Checking against your library…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                ContentUnavailableView(
                    "Nothing to merge",
                    systemImage: "tray",
                    description: Text("No tracks in this job finished downloading.")
                )
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .task { await prepare() }
        .alert(
            "Merge complete",
            isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })
        ) {
            Button("Done") {
                result = nil
                dismiss()
            }
        } message: {
            if let result { Text(summary(for: result)) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merge into Library")
                .font(.title2)
                .fontWeight(.semibold)
            Text(job.playlistTitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !job.skippedVideoIDs.isEmpty {
                Label(
                    "\(job.skippedVideoIDs.count) track\(job.skippedVideoIDs.count == 1 ? " was" : "s were") already in your library and never downloaded.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(MergeBucket.allCases) { bucket in
                let rows = candidates(in: bucket)
                if !rows.isEmpty {
                    Section {
                        if expandedBuckets.contains(bucket) {
                            ForEach(rows) { candidate in
                                MergeCandidateRow(candidate: candidate)
                            }
                        }
                    } header: {
                        bucketHeader(bucket, count: rows.count)
                    }
                }
            }
        }
        .alternatingRowBackgrounds()
    }

    private func bucketHeader(_ bucket: MergeBucket, count: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                if expandedBuckets.contains(bucket) {
                    expandedBuckets.remove(bucket)
                } else {
                    expandedBuckets.insert(bucket)
                }
            } label: {
                Image(systemName: expandedBuckets.contains(bucket) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(bucket.title)
            Text("\(count)")
                .foregroundStyle(.secondary)

            Text(bucket.explanation)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button(allSkipped(in: bucket) ? "Add all" : "Skip all") {
                let target: MergeAction = allSkipped(in: bucket) ? .include : .skip
                for candidate in candidates(in: bucket) { candidate.action = target }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func allSkipped(in bucket: MergeBucket) -> Bool {
        let rows = candidates(in: bucket)
        return !rows.isEmpty && rows.allSatisfy { $0.action == .skip }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(addCount) of \(candidates.count) will be added")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isMerging)

            Button {
                Task { await merge() }
            } label: {
                if isMerging {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Merge \(addCount)", systemImage: "arrow.triangle.merge")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isMerging || candidates.isEmpty)
        }
        .padding(20)
    }

    // MARK: - Actions

    private func prepare() async {
        isPreparing = true
        candidates = await store.prepareMerge(job: job, settings: settings)
        // Auto-expand the review bucket only when it has something in it —
        // otherwise it's noise on a clean merge.
        if candidates.contains(where: { $0.bucket == .review }) {
            expandedBuckets.insert(.review)
        }
        isPreparing = false
    }

    private func merge() async {
        isMerging = true
        result = await store.commitMerge(candidates, job: job, settings: settings)
        isMerging = false
    }

    private func summary(for result: LibraryImporter.Result) -> String {
        var parts: [String] = []
        if !result.imported.isEmpty { parts.append("\(result.imported.count) added") }
        if !result.replaced.isEmpty { parts.append("\(result.replaced.count) replaced") }
        if result.skipped > 0 { parts.append("\(result.skipped) skipped") }
        if !result.failures.isEmpty { parts.append("\(result.failures.count) failed") }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: ", ") + "."
    }
}
