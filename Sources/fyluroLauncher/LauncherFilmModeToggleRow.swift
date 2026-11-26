import FyluroCore
import SwiftUI

struct LauncherFilmModeButtonRow: View {
    let isDisabled: Bool
    let onOpen: () -> Void

    private let explanation = "Record the camera, film stock, and shoot date for scanned film."

    var body: some View {
        Button(action: onOpen) {
            Label("Film Mode…", systemImage: "film")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isDisabled)
        .help(explanation)
        .fixedSize()
    }
}

struct LauncherFilmModeSummaryRow: View {
    let summary: String
    let isDisabled: Bool
    let onEdit: () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LauncherTone.info.color)

            Text("Film Mode — \(summary)")
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button("Edit…", action: onEdit)
                .controlSize(.small)
                .disabled(isDisabled)
                .fixedSize()

            Button("Turn Off", action: onTurnOff)
                .controlSize(.small)
                .disabled(isDisabled)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LauncherRadius.control, style: .continuous)
                .fill(LauncherTone.info.color.opacity(0.1))
        )
    }
}
