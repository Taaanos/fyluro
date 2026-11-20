import SwiftUI

/// The Transfers pane: shows the detected destination medium and lets the user choose
/// 1 or 2 parallel copies for non-HDD destinations. Changes save immediately and apply
/// to the next import (ROL-6 Section 11).
struct LauncherTransferSettingsView: View {
    @ObservedObject var store: LauncherTransferSettingsStore

    private static let paneHeight: CGFloat = 210

    private var parallelCopiesBinding: Binding<Int> {
        Binding(
            get: { store.effectiveMaxParallelCopies },
            set: { newValue in
                guard !store.isParallelCopiesLockedToSingleStream else {
                    return
                }
                store.setPreferredMaxParallelCopies(newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Destination medium") {
                    Text(store.detectedMediumDisplayText)
                        .foregroundStyle(.secondary)
                }

                Picker("Parallel copies", selection: parallelCopiesBinding) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(store.isParallelCopiesLockedToSingleStream)
            } header: {
                Text("Parallel Copies")
            } footer: {
                SettingsFootnote(store.explanationFootnoteText)
            }
        }
        .formStyle(.grouped)
        .frame(width: LauncherSettingsWindowMetrics.width, height: Self.paneHeight)
    }
}
