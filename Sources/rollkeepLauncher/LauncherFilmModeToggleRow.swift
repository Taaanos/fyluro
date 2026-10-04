import RollKeepCore
import SwiftUI

/// A compact, native-switch toggle for Film Mode. The explanation is shown
/// from a dedicated "?" help icon on click, rather than a whole-row hover
/// popover — hovering near the toggle to flip it shouldn't also pop up
/// explanatory text.
struct LauncherFilmModeToggleRow: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Binding var isFilmModeSheetPresented: Bool

    @State private var isExplanationVisible = false

    private let explanation = "For digitized film: declare the correct month and camera for this batch. \(AppBrand.name) uses these instead of the digitizing camera's EXIF, and writes them into each photo."

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

            if viewModel.filmModeEnabled, let configuration = viewModel.filmModeConfiguration {
                Text("· \(Calendar.current.monthSymbols[configuration.month - 1]) \(String(configuration.year)) · \(configuration.camera)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sheet(isPresented: $isFilmModeSheetPresented) {
            LauncherFilmModeSheet(viewModel: viewModel)
        }
    }
}
