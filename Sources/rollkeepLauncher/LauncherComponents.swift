import SwiftUI

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
