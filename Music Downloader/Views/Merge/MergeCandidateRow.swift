import SwiftUI

/// One staged track in the merge review, with its verdict and the action the
/// user has chosen for it.
struct MergeCandidateRow: View {
    @Bindable var candidate: MergeCandidate

    /// Replacing only makes sense when there's an existing library file to
    /// replace — for a genuinely new song there's nothing to overwrite.
    private var canReplace: Bool {
        candidate.verdict.existingFile != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: includeBinding) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(candidate.action == .skip ? "Skipped" : "Will be added")

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(candidate.action == .skip ? .secondary : .primary)

                HStack(spacing: 6) {
                    Text(candidate.displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if candidate.verdict.existingFile != nil {
                        StatusChip(candidate.verdict, size: .compact)
                    }
                }

                if let detail = verdictDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(LibraryRow.formatDuration(candidate.track.sourceDuration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            if canReplace {
                Picker("Action", selection: $candidate.action) {
                    ForEach(MergeAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 100)
            }
        }
        .padding(.vertical, 4)
    }

    /// The checkbox is a two-state view onto a three-state action: unchecking
    /// always means skip, rechecking returns to whichever add-style action
    /// makes sense for this row.
    private var includeBinding: Binding<Bool> {
        Binding(
            get: { candidate.action != .skip },
            set: { isOn in
                candidate.action = isOn ? .include : .skip
            }
        )
    }

    private var verdictDetail: String? {
        guard let existing = candidate.verdict.existingFile else { return nil }
        switch candidate.verdict {
        case .sameMetadata(_, let delta):
            return "Matches “\(existing)” · \(Self.deltaText(delta))"
        case .probableMatch(_, let delta):
            if let delta {
                return "Similar to “\(existing)” · \(Self.deltaText(delta))"
            }
            return "Similar to “\(existing)” · no duration to compare"
        case .possibleMatch(_, let score):
            return "Similar to “\(existing)” · \(Int(score * 100))% match"
        case .sameVideo, .sameGeniusSong:
            return "Already in your library as “\(existing)”"
        case .unique:
            return nil
        }
    }

    private static func deltaText(_ delta: Double) -> String {
        if delta < 1 { return "same length" }
        return "\(Int(delta.rounded()))s difference"
    }
}
