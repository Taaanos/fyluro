import Foundation

/// One vendor's decoded catalog. `vendor` is the JSON filename minus its
/// extension and exists for organization/diagnostics only -- it plays no
/// role in lookup, which is purely by uppercased code (see
/// Resources/CameraModelCatalogs/README.md).
struct VendorModelCatalog: Equatable, Sendable {
    let vendor: String
    let entries: [String: String]
}

/// Loads the per-vendor bare-model-code -> retail-product-name catalogs
/// shipped as JSON under Resources/CameraModelCatalogs (one file per
/// vendor). Replaces what used to be a single hardcoded Swift dictionary in
/// `MapKnownModelCodeToProductNameRule`, so the catalog can grow to hundreds
/// of entries by editing data files rather than Swift code.
///
/// Internal, not public: `Bundle.module` (the default `bundle`) is itself
/// internal to this module, so a `public` init couldn't default to it. Only
/// `CameraModelCatalog.shared` below needs to be public, since it's what
/// `MapKnownModelCodeToProductNameRule`'s public init defaults to.
struct CameraModelCatalogLoader {
    private let bundle: Bundle
    private let subdirectory: String?

    /// `bundle`/`subdirectory` are injectable purely for testing (e.g.
    /// pointing at a temp bundle of deliberately malformed JSON to exercise
    /// the failure path without shipping bad data). Production code should
    /// always use the default, which reads from this module's own resource
    /// bundle.
    init(bundle: Bundle = .module, subdirectory: String? = "CameraModelCatalogs") {
        self.bundle = bundle
        self.subdirectory = subdirectory
    }

    /// Enumerates every `*.json` catalog and decodes each as a flat
    /// `{code: name}` map. Failure policy: a missing catalog directory, or
    /// an individual missing/unreadable/malformed file, contributes nothing
    /// and is skipped silently -- this must never crash the app, and an
    /// absent mapping simply falls back to the raw code, exactly like an
    /// unknown code does today.
    func loadVendorCatalogs() -> [VendorModelCatalog] {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) ?? []
        let decoder = JSONDecoder()

        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> VendorModelCatalog? in
                guard
                    let data = try? Data(contentsOf: url),
                    let raw = try? decoder.decode([String: String].self, from: data)
                else {
                    return nil
                }

                var entries: [String: String] = [:]
                entries.reserveCapacity(raw.count)
                for (code, name) in raw {
                    let key = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard !key.isEmpty else { continue }
                    entries[key] = name
                }

                return VendorModelCatalog(vendor: url.deletingPathExtension().lastPathComponent, entries: entries)
            }
    }

    /// Merged, uppercased-key lookup across every vendor file. A cross-vendor
    /// key collision is a data bug caught by
    /// `CameraModelCatalogLoaderTests.testNoDuplicateCodesAcrossVendorFiles`,
    /// not something resolved at runtime; here it's simply last-writer-wins.
    func loadMergedCatalog() -> [String: String] {
        var merged: [String: String] = [:]
        for catalog in loadVendorCatalogs() {
            merged.merge(catalog.entries) { _, new in new }
        }
        return merged
    }
}

public enum CameraModelCatalog {
    /// Loaded exactly once per process. `static let` initialization is
    /// atomic/thread-safe, so the JSON is parsed a single time no matter how
    /// many `CameraLabeler`/`MapKnownModelCodeToProductNameRule` instances a
    /// scan constructs (one per file, in the worst case).
    public static let shared: [String: String] = CameraModelCatalogLoader().loadMergedCatalog()
}
