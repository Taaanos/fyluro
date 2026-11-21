import FyluroCore
import SwiftUI

struct LauncherFilmModeToggleRow: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Binding var isFilmModeSheetPresented: Bool

    @State private var isExplanationVisible = false

    private let explanation = "Scanned film carries the EXIF of whatever digitized it. Film Mode records the camera and film you actually shot on, and files the photos under the month you shot them."

    private var filmModeToggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filmModeEnabled },
            set: { newValue in
                if newValue {
                    isFilmModeSheetPresented = true
                } else {
                    viewModel.disableFilmMode()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow

            if let summary = viewModel.filmModeSummaryText {
                summaryRow(summary)
            }
        }
        .sheet(isPresented: $isFilmModeSheetPresented) {
            LauncherFilmModeSheet(
                viewModel: viewModel,
                editing: viewModel.filmModeState.configuration
            )
        }
    }

    private func summaryRow(_ summary: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LauncherTone.info.color)

            Text("Film Mode — \(summary)")
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button("Edit…") { isFilmModeSheetPresented = true }
                .controlSize(.small)
                .disabled(viewModel.isRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LauncherRadius.control, style: .continuous)
                .fill(LauncherTone.info.color.opacity(0.1))
        )
    }

    private var switchRow: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Film Mode")
                    .font(.subheadline)

                Toggle("", isOn: filmModeToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(viewModel.isRunning)

                Button(action: { isExplanationVisible.toggle() }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isExplanationVisible, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                    Text(explanation)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(width: 300, alignment: .leading)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
