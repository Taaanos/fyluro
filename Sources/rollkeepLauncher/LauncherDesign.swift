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
}

enum LauncherRadius {
    static let card: CGFloat = 16
}
