import SwiftUI

struct LauncherImportRoutePanel: View {
    let sourceName: String
    let sourcePath: String
    let destinationName: String
    let destinationPath: String
    let isActive: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalRoute
            verticalRoute
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface(style: .scan))
    }

    private var horizontalRoute: some View {
        HStack(alignment: .center, spacing: 12) {
            LauncherImportRouteEndpoint(
                title: "Source",
                systemImage: "externaldrive",
                style: .source,
                name: sourceName,
                path: sourcePath
            )

            routeArrow(symbolName: "arrow.right", axis: .horizontal)

            LauncherImportRouteEndpoint(
                title: "Destination",
                systemImage: "folder",
                style: .destination,
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
                style: .source,
                name: sourceName,
                path: sourcePath
            )

            routeArrow(symbolName: "arrow.down", axis: .vertical)
                .frame(maxWidth: .infinity, alignment: .center)

            LauncherImportRouteEndpoint(
                title: "Destination",
                systemImage: "folder",
                style: .destination,
                name: destinationName,
                path: destinationPath
            )
        }
    }

    private func routeArrow(symbolName: String, axis: LauncherRouteAxis) -> some View {
        LauncherFlowArrow(
            symbolName: symbolName,
            axis: axis,
            isActive: isActive
        )
        .frame(minWidth: 56)
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

    var body: some View {
        ZStack {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            if isActive {
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
        if isActive {
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
    let style: LauncherPanelStyle
    let name: String
    let path: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style.accent.opacity(style.iconFillOpacity))

                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.accent)
            }
            .frame(width: 34, height: 34)

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
