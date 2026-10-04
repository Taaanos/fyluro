import SwiftUI

/// What a piece of status UI means. Each tone maps to one system color, so the
/// app follows dark mode, light mode and the user's accent color.
/// Green is success, red is an error, orange needs attention, accent is neutral progress.
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

    /// The SF Symbol a banner of this tone shows when the caller gives none.
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
}
