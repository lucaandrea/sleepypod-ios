import SwiftUI

enum SleepTypography {
    case pageTitle, widePageTitle, cardTitle, body, small, caption, eyebrow, metric, smallMetric, button, badge
    var size: CGFloat {
        switch self {
        case .pageTitle: SleepTokens.Typography.pageTitle
        case .widePageTitle: SleepTokens.Typography.widePageTitle
        case .cardTitle: SleepTokens.Typography.cardTitle
        case .body: SleepTokens.Typography.body
        case .small: SleepTokens.Typography.small
        case .caption: SleepTokens.Typography.caption
        case .eyebrow: SleepTokens.Typography.eyebrow
        case .metric: SleepTokens.Typography.metric
        case .smallMetric: SleepTokens.Typography.smallMetric
        case .button: SleepTokens.Typography.button
        case .badge: SleepTokens.Typography.badge
        }
    }
    var weight: Font.Weight {
        switch self {
        case .pageTitle, .widePageTitle, .cardTitle, .eyebrow: .semibold
        case .metric, .smallMetric, .button, .badge: .medium
        default: .regular
        }
    }
    var relative: Font.TextStyle {
        switch self {
        case .pageTitle, .widePageTitle, .metric: .title
        case .cardTitle, .smallMetric: .title3
        case .caption, .eyebrow, .badge: .caption
        default: .body
        }
    }
    var tracking: CGFloat {
        switch self {
        case .pageTitle, .widePageTitle: -0.04 * size
        case .cardTitle: -0.025 * size
        case .eyebrow: 0.12 * size
        default: 0
        }
    }
}
