import SwiftUI

/// Says where a night's stages came from: a brain for a trained Core ML model running on this iPhone's
/// Neural Engine path, a list for the hand-written rules. SF Symbols only; Apple's Core ML mark is a trademark.
struct StageSourceBadge: View {
    enum Kind {
        case rules
        case model(String)

        var symbol: String {
            switch self {
            case .rules: "list.bullet.rectangle"
            case .model: "brain"
            }
        }
        var title: String {
            switch self {
            case .rules: "Rules"
            case .model(let name): name
            }
        }
        var color: Color {
            switch self {
            case .rules: Theme.text2
            case .model: Theme.cool
            }
        }
        var isModel: Bool {
            if case .model = self { return true }
            return false
        }
    }

    let kind: Kind
    var compact = false

    init(_ kind: Kind, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol).font(.system(size: compact ? 9 : 11, weight: .semibold))
            if !compact { Text(kind.isModel ? "ML · \(kind.title)" : kind.title) }
        }
        .font(.mono(10, relativeTo: .caption2))
        .foregroundStyle(kind.color)
        .padding(.horizontal, compact ? 5 : 7).padding(.vertical, 3)
        .background(kind.color.opacity(0.12), in: Capsule())
        .accessibilityLabel(kind.isModel ? "Stages from the \(kind.title) model" : "Stages from rules")
    }
}
