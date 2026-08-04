import SwiftUI

/// A small tinted capsule with an icon and a label.
///
/// The app's status enums (`JobStatus`, `EnrichmentStatus`, `DuplicateVerdict`,
/// `DownloadMode`) all expose `displayName` / `symbolName` / `tint`, so anything
/// conforming to `StatusPresentable` renders without a switch at the call site.
protocol StatusPresentable {
    var displayName: String { get }
    var symbolName: String { get }
    var tint: Color { get }
}

extension JobStatus: StatusPresentable {}
extension DownloadMode: StatusPresentable {}
extension DuplicateVerdict: StatusPresentable {}

struct StatusChip: View {
    let title: String
    let symbolName: String
    let tint: Color
    var size: Size = .regular

    enum Size {
        case regular
        /// For dense list rows where a full-size chip would crowd the line.
        case compact

        var font: Font {
            switch self {
            case .regular: .caption
            case .compact: .caption2
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: 8
            case .compact: 6
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .regular: 3
            case .compact: 2
            }
        }
    }

    init(title: String, symbolName: String, tint: Color, size: Size = .regular) {
        self.title = title
        self.symbolName = symbolName
        self.tint = tint
        self.size = size
    }

    init(_ status: some StatusPresentable, size: Size = .regular) {
        self.init(
            title: status.displayName,
            symbolName: status.symbolName,
            tint: status.tint,
            size: size
        )
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            Text(title)
        }
        .font(size.font)
        .fontWeight(.medium)
        .foregroundStyle(tint)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
