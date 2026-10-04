import SwiftUI

/// Where the route is in its life. Running shows the moving arrow.
/// The other states show one still mark, so the same panel reads as the result.
enum LauncherRouteStatus: Equatable {
    case running
    case complete
    case completeWithWarnings
    case failed
    /// The user stopped the run. This is not an error, so the mark is neutral.
    case stopped

    var isRunning: Bool { self == .running }

    var markSymbol: String {
        switch self {
        case .running: return "arrow.right"
        case .complete: return "checkmark.circle.fill"
        case .completeWithWarnings: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    var markTone: LauncherTone {
        switch self {
        case .running: return .info
        case .complete: return .success
        case .completeWithWarnings: return .attention
        case .failed: return .error
        case .stopped: return .neutral
        }
    }

    var accessibilityText: String {
        switch self {
        case .running: return "Import in progress"
        case .complete: return "Import complete"
        case .completeWithWarnings: return "Import complete with warnings"
        case .failed: return "Import failed"
        case .stopped: return "Import stopped"
        }
    }
}

struct LauncherImportRoutePanel: View {
    let sourceName: String
    let sourcePath: String
    let destinationName: String
    let destinationPath: String
    let status: LauncherRouteStatus

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalRoute
            verticalRoute
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface())
    }

    private var horizontalRoute: some View {
        HStack(alignment: .center, spacing: 12) {
            LauncherImportRouteEndpoint(
                title: "Source",
                systemImage: "externaldrive",
                name: sourceName,
                path: sourcePath
            )

            routeArrow(symbolName: "arrow.right", axis: .horizontal)

            LauncherImportRouteEndpoint(
                title: "Destination",
                systemImage: "folder",
                name: destinationName,
                path: destinationPath
            )
        }
    }

    private var verticalRoute: some View {
        VStack(alignment: .leading, spacing: 12) {
            LauncherImportRouteEndpoint(
                title: "Source",
                systemImage: "externaldrive",
                name: sourceName,
                path: sourcePath
            )

            routeArrow(symbolName: "arrow.down", axis: .vertical)
                .frame(maxWidth: .infinity, alignment: .center)

            LauncherImportRouteEndpoint(
                title: "Destination",
                systemImage: "folder",
                name: destinationName,
                path: destinationPath
            )
        }
    }

    @ViewBuilder
    private func routeArrow(symbolName: String, axis: LauncherRouteAxis) -> some View {
        if status.isRunning {
            LauncherFlowArrow(
                symbolName: symbolName,
                axis: axis,
                isActive: true
            )
            .frame(minWidth: 56)
            .accessibilityLabel(status.accessibilityText)
        } else {
            Image(systemName: status.markSymbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(status.markTone.color)
                .frame(minWidth: 56)
                .accessibilityLabel(status.accessibilityText)
        }
    }
}

enum LauncherRouteAxis {
    case horizontal
    case vertical
}

struct LauncherFlowArrow: View {
    let symbolName: String
    let axis: LauncherRouteAxis
    let isActive: Bool

    @State private var flowProgress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // With Reduce Motion on, the arrow does not move. A still accent color shows "in progress".
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isActive && reduceMotion ? AnyShapeStyle(LauncherTone.info.color) : AnyShapeStyle(.secondary))

            if isActive && !reduceMotion {
                Image(systemName: symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(LauncherTone.info.color.opacity(0.95))
                    .mask(highlightBand)
            }
        }
        .frame(
            width: axis == .horizontal ? 56 : 20,
            height: axis == .horizontal ? 20 : 56
        )
        .onAppear {
            updateAnimation()
        }
        .onChange(of: isActive) { _ in
            updateAnimation()
        }
        .onChange(of: reduceMotion) { _ in
            updateAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
    }

    private var highlightBand: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.2), location: 0.35),
                .init(color: .white, location: 0.5),
                .init(color: .white.opacity(0.2), location: 0.65),
                .init(color: .clear, location: 1),
            ],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
        .frame(width: 48, height: 48)
        .offset(
            x: axis == .horizontal ? flowProgress * 36 : 0,
            y: axis == .vertical ? flowProgress * 36 : 0
        )
    }

    private func updateAnimation() {
        if isActive && !reduceMotion {
            flowProgress = -1
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                flowProgress = 1
            }
        } else {
            stopAnimation()
        }
    }

    private func stopAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flowProgress = 0
        }
    }
}

struct LauncherImportRouteEndpoint: View {
    let title: String
    let systemImage: String
    let name: String
    let path: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LauncherIconTile(systemImage: systemImage, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(pathText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pathText: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Path unavailable" : trimmed
    }
}
