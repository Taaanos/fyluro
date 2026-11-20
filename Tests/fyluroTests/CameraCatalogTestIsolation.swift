import Foundation
@testable import FyluroCore

/// Points the user-catalog location at a file that doesn't exist, so tests that
/// default-construct `CameraLabeler()` never read a developer's real catalog.
enum CameraCatalogTestIsolation {
    static func useEmptyCatalog() {
        let path = NSTemporaryDirectory() + "fyluro-no-catalog-\(UUID().uuidString).json"
        setenv(CameraUserCatalogFileLocation.environmentOverrideKey, path, 1)
    }
}
