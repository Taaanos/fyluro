import Foundation
@testable import FyluroCore

enum CameraCatalogTestIsolation {
    static func useEmptyCatalog() {
        let path = NSTemporaryDirectory() + "fyluro-no-catalog-\(UUID().uuidString).json"
        setenv(CameraUserCatalogFileLocation.environmentOverrideKey, path, 1)
    }
}
