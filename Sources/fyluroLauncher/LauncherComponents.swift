import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherPathIcon: View {
    let path: String
    let fallbackSystemImage: String
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let nsImage = resolvedFileIcon {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: size * 0.62, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var resolvedFileIcon: NSImage? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: trimmed)
    }
}

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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.color)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if let text {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle((emphasizedText || title == nil) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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

struct ResultAction: Identifiable {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var id: String { title }
}

struct ResultActionBar: View {
    let secondaryActions: [ResultAction]
    let primaryAction: ResultAction

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    secondaryButtons
                    primaryButton
                }

                VStack(alignment: .trailing, spacing: 10) {
                    if !secondaryActions.isEmpty {
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            secondaryButtons
                        }
                    }
                    primaryButton
                }
            }
        }
    }

    private var secondaryButtons: some View {
        ForEach(secondaryActions) { action in
            Button(action.title, action: action.action)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!action.isEnabled)
                .fixedSize()
        }
    }

    private var primaryButton: some View {
        Button(primaryAction.title, action: primaryAction.action)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryAction.isEnabled)
            .fixedSize()
    }
}

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
