import SwiftUI

/// A compact, native-switch toggle for Film Mode. Uses a custom hover
/// popover rather than `.help()` — the system tooltip delay isn't
/// controllable and is noticeably slow; this one triggers in half the time
/// of the equivalent hover indicator used elsewhere in the app
/// (`LauncherSettingsHoverWarningIndicator`, 0.3s).
struct LauncherFilmModeToggleRow: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Binding var isFilmModeSheetPresented: Bool

    @State private var isTooltipVisible = false
    @State private var isHoveringRow = false
    @State private var pendingShowTask: DispatchWorkItem?
    @State private var pendingHideTask: DispatchWorkItem?

    private let hoverShowDelay: TimeInterval = 0.15
    private let hoverHideDelay: TimeInterval = 0.2
    private let explanation = "For digitized film: declare the correct month and camera for this batch. RollKeep uses these instead of the digitizing camera's EXIF, and writes them into each photo."

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
            }
            .popover(isPresented: $isTooltipVisible, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                Text(explanation)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(width: 300, alignment: .leading)
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
        .onHover(perform: handleHoverChanged)
        .sheet(isPresented: $isFilmModeSheetPresented) {
            LauncherFilmModeSheet(viewModel: viewModel)
        }
    }

    private func handleHoverChanged(_ isHovering: Bool) {
        isHoveringRow = isHovering

        if isHovering {
            pendingHideTask?.cancel()
            pendingHideTask = nil

            guard !isTooltipVisible, pendingShowTask == nil else {
                return
            }

            let task = DispatchWorkItem {
                pendingShowTask = nil
                guard isHoveringRow else {
                    return
                }
                isTooltipVisible = true
            }
            pendingShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverShowDelay, execute: task)
        } else {
            pendingShowTask?.cancel()
            pendingShowTask = nil

            guard isTooltipVisible else {
                return
            }

            let task = DispatchWorkItem {
                pendingHideTask = nil
                isTooltipVisible = false
            }
            pendingHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverHideDelay, execute: task)
        }
    }
}
