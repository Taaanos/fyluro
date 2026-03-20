import Foundation
import RollKeepCore
import SwiftUI

@MainActor
final class LauncherPathSchemeSettingsStore: ObservableObject {
    @Published private(set) var appliedConfiguration: LauncherPathSchemeConfiguration
    @Published var draftConfiguration: LauncherPathSchemeConfiguration

    private let pathSchemeRemembering: LauncherPathSchemeRemembering
    private let previewDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 12))
            ?? Date(timeIntervalSince1970: 1_773_547_200)
    }()
    private let previewCameraLabel = "sony-a7iv"

    init(pathSchemeRemembering: LauncherPathSchemeRemembering = LauncherPathSchemeMemory()) {
        self.pathSchemeRemembering = pathSchemeRemembering
        let loaded = pathSchemeRemembering.loadAppliedPathScheme()
        self.appliedConfiguration = loaded
        self.draftConfiguration = loaded
    }

    var hasPendingChanges: Bool {
        draftConfiguration != appliedConfiguration
    }

    var pendingWarningMessages: [String] {
        guard hasPendingChanges else {
            return []
        }

        var messages: [String] = []
        if draftConfiguration.chronologicalLayout != appliedConfiguration.chronologicalLayout {
            messages.append("Frequent path scheme changes can create mixed destination structures over time.")
        }
        if draftConfiguration.includeCameraFolder != appliedConfiguration.includeCameraFolder,
           !draftConfiguration.includeCameraFolder {
            messages.append("Disabling camera grouping can increase filename collision suffixes (-1, -2, ...).")
        }

        return messages
    }

    var shouldShowPendingWarnings: Bool {
        !pendingWarningMessages.isEmpty
    }

    var draftPhotoPreviewPath: String {
        previewPath(
            configuration: draftConfiguration,
            mediaType: .photo,
            filename: "IMG_1234.CR3",
            photoCompressionBucket: .raw
        )
    }

    var draftVideoPreviewPath: String {
        previewPath(
            configuration: draftConfiguration,
            mediaType: .video,
            filename: "VID_9876.MP4",
            photoCompressionBucket: nil
        )
    }

    func applyDraft() {
        appliedConfiguration = draftConfiguration
        pathSchemeRemembering.saveAppliedPathScheme(appliedConfiguration)
    }

    func resetDraftToDefault() {
        draftConfiguration = .default
    }

    private func previewPath(
        configuration: LauncherPathSchemeConfiguration,
        mediaType: MediaType,
        filename: String,
        photoCompressionBucket: PhotoCompressionBucket?
    ) -> String {
        let scheme = configuration.corePathScheme
        var components = ["<DEST>"]
        components.append(contentsOf: scheme.pathPrefixComponents(
            captureDate: previewDate,
            cameraLabel: previewCameraLabel
        ))
        components.append(mediaType == .photo ? "Photos" : "Videos")
        if let compressionDirectoryName = scheme.compressionDirectoryName(
            mediaType: mediaType,
            photoCompressionBucket: photoCompressionBucket
        ) {
            components.append(compressionDirectoryName)
        }
        components.append(filename)
        return components.joined(separator: "/")
    }
}
