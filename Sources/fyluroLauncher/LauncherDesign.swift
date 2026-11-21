import SwiftUI

enum LauncherTone {
    case neutral
    case info
    case success
    case attention
    case error

    var color: Color {
        switch self {
        case .neutral: return .primary
        case .info: return .accentColor
        case .success: return .green
        case .attention: return .orange
        case .error: return .red
        }
    }

    var defaultIcon: String {
        switch self {
        case .neutral, .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

enum LauncherRadius {
    static let card: CGFloat = 16
    static let control: CGFloat = 12
}
