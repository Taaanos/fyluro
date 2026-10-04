import SwiftUI
import UniformTypeIdentifiers

/// The panel background. One fill and one hairline stroke, with no shadow and no tint.
/// A quiet surface keeps the eye on the content, not on the box around it.
struct Surface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: LauncherRadius.card, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: LauncherRadius.card, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.8)
            )
    }
}

/// A rounded square in the accent color with one SF Symbol on it.
struct LauncherIconTile: View {
    let systemImage: String
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LauncherTone.info.color.opacity(0.12))

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(LauncherTone.info.color)
        }
        .frame(width: size, height: size)
    }
}

/// A tinted box with an icon, an optional title, optional text, and optional extra content.
/// The tone sets the icon and tint color. `emphasizedText` shows the text in primary color.
struct NoticeBanner<Content: View>: View {
    let tone: LauncherTone
    let icon: String
    let title: String?
    let text: String?
    let emphasizedText: Bool
    @ViewBuilder let content: () -> Content

    init(
        tone: LauncherTone,
        icon: String? = nil,
        title: String? = nil,
        text: String? = nil,
        emphasizedText: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tone = tone
        self.icon = icon ?? tone.defaultIcon
        self.title = title
        self.text = text
        self.emphasizedText = emphasizedText
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if let text {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(emphasizedText ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                content()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tone.color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tone.color.opacity(0.35), lineWidth: 0.8)
        )
    }
}

extension NoticeBanner where Content == EmptyView {
    init(tone: LauncherTone, icon: String? = nil, title: String? = nil, text: String, emphasizedText: Bool = false) {
        self.init(tone: tone, icon: icon, title: title, text: text, emphasizedText: emphasizedText) { EmptyView() }
    }
}

/// One button of a `ResultActionBar`.
struct ResultAction: Identifiable {
    enum Emphasis {
        /// A bordered button.
        case secondary
        /// A plain text button, for actions that most people do not need.
        case tertiary
    }

    let title: String
    var emphasis: Emphasis = .secondary
    var isEnabled = true
    let action: () -> Void

    var id: String { title }
}

/// The one row of actions at the end of the Complete and Failure screens.
/// The lesser actions are at the left. The main action is at the right and is the default button.
/// Each button takes the width of its label. When the window is too narrow for one row,
/// the main action moves to a second row, still at the right.
struct ResultActionBar: View {
    let secondaryActions: [ResultAction]
    let primaryAction: ResultAction

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                secondaryRow
                Spacer(minLength: 10)
                primaryButton
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    secondaryRow
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer(minLength: 0)
                    primaryButton
                }
            }
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            ForEach(secondaryActions) { action in
                switch action.emphasis {
                case .secondary:
                    Button(action.title, action: action.action)
                        .buttonStyle(.bordered)
                        .disabled(!action.isEnabled)
                case .tertiary:
                    Button(action.title, action: action.action)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!action.isEnabled)
                }
            }
        }
        .fixedSize()
    }

    private var primaryButton: some View {
        Button(primaryAction.title, action: primaryAction.action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryAction.isEnabled)
            .fixedSize()
    }
}

/// A small label above a value, for example "Photos" over "128".
struct StatItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Makes a view take a dropped folder. While a folder is over the view, an accent ring shows.
/// A disabled view takes no drop and shows no ring.
private struct FolderDropTarget: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let onDropURLs: (([URL]) -> Void)?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LauncherTone.info.color.opacity(isTargeted && isEnabled ? 0.7 : 0), lineWidth: 2)
            )
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: targetedBinding) { providers in
                handleDrop(providers)
            }
    }

    private var targetedBinding: Binding<Bool> {
        Binding(
            get: { isTargeted },
            set: { isTargeted = isEnabled && $0 }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isEnabled, let onDropURLs, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL?
            switch item {
            case let data as Data:
                url = URL(dataRepresentation: data, relativeTo: nil)
            case let directURL as URL:
                url = directURL
            default:
                url = nil
            }

            guard let url else {
                return
            }

            Task { @MainActor in
                onDropURLs([url])
            }
        }

        return true
    }
}

extension View {
    func folderDropTarget(
        isEnabled: Bool = true,
        cornerRadius: CGFloat = LauncherRadius.control,
        onDropURLs: (([URL]) -> Void)?
    ) -> some View {
        modifier(FolderDropTarget(isEnabled: isEnabled, cornerRadius: cornerRadius, onDropURLs: onDropURLs))
    }
}
