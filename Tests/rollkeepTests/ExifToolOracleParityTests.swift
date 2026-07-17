import Foundation
import XCTest
@testable import RollKeepCore

/// Parity harness against exiftool, the reference implementation for camera
/// identification (see docs/exiftool-sync.md).
/// ExifTool itself is never vendored -- it is located on disk (default
/// `$ROLLKEEP_EXIFTOOL_CHECKOUT`, override `ROLLKEEP_EXIFTOOL_CHECKOUT`) and used
/// strictly as a dev-time oracle.
///
/// Two modes:
/// - `testCorpusParityAgainstSnapshot` needs only the checkout (for the
///   t/images corpus files) plus the committed snapshot JSON -- no perl. It
///   asserts RollKeep resolves the same make/model as exiftool for every
///   corpus file not listed in `knownGaps`, and that `knownGaps` entries
///   stay gaps: once a milestone closes one, the test fails until the entry
///   is removed (the ratchet that keeps the gap list honest).
/// - `testFixtureLibraryParityAgainstLiveExifTool` additionally needs perl:
///   it runs exiftool live over the real fixture library
///   (Tests/TestingDirs) and prints a coverage report.
///   It fails only when RollKeep resolves a *conflicting* identity -- missing
///   coverage is expected until the milestones land and is tracked by the
///   printed counts, not by assertions.
final class ExifToolOracleParityTests: XCTestCase {
    private struct Snapshot: Decodable {
        let exiftoolVersion: String
        let entries: [String: Entry]

        struct Entry: Decodable {
            let make: String?
            let model: String?
            let serial: String?
            let uniqueCameraModel: String?
        }
    }

    /// The exiftool release the Swift tables were last synced against.
    /// Bumping the checkout without following docs/exiftool-sync.md fails
    /// the corpus test via the version assertion below.
    private static let pinnedExifToolVersion = "13.59"

    /// Corpus files whose camera identity exiftool extracts but RollKeep
    /// does not yet (value = which milestone closes it, or why it stays).
    /// A file listed here that starts matching fails the test, prompting
    /// removal -- coverage only ratchets forward.
    private static let knownGaps: [String: String] = [
        "QuickTime.mov": "M1 (udta TAGS vendor signature)",
        "CanonRaw.cr2": "M2 (ImageIO rejects the stripped corpus file; native EXIF fallback closes it)",
        "CanonRaw.cr3": "M2 (BMFF + Canon uuid CMT1)",
        "FujiFilm.raf": "M2 (RAF header model string)",
        "Panasonic.rw2": "M2 (TIFF variant magic 0x55)",
        "CanonRaw.crw": "M2-stretch (CIFF heap, not TIFF -- evaluate during M2)",
        "KyoceraRaw.raw": "M2-stretch (fixed-offset header strings -- evaluate during M2)",
        "Minolta.mrw": "M2-stretch (MRW TTW block embeds a TIFF -- evaluate during M2)",
        "Sigma.x3f": "M2-stretch (X3F PROP section -- evaluate during M2)",
        "SigmaDP2.x3f": "M2-stretch (X3F PROP section -- evaluate during M2)",
        "M2TS.mts": "M3 (H.264 SEI MDPM)",
    ]

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "insv", "avi", "mts", "m2ts", "mxf"]
    private static let fixtureVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "insv"]

    private static var exiftoolCheckoutURL: URL {
        if let override = ProcessInfo.processInfo.environment["ROLLKEEP_EXIFTOOL_CHECKOUT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("exiftool", isDirectory: true)
    }

    private static var snapshotURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/exiftool-oracle-snapshot.json")
    }

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Tests/TestingDirs", isDirectory: true)
    }

    // MARK: - Corpus parity (snapshot mode, no perl required)

    func testCorpusParityAgainstSnapshot() throws {
        guard FileManager.default.fileExists(atPath: Self.snapshotURL.path) else {
            throw XCTSkip("No oracle snapshot; run scripts/refresh-exiftool-oracle-snapshot.sh")
        }
        let imagesURL = Self.exiftoolCheckoutURL.appendingPathComponent("t/images", isDirectory: true)
        guard FileManager.default.fileExists(atPath: imagesURL.path) else {
            throw XCTSkip("exiftool checkout not present at \(Self.exiftoolCheckoutURL.path)")
        }

        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: Self.snapshotURL))
        XCTAssertEqual(
            snapshot.exiftoolVersion, Self.pinnedExifToolVersion,
            "exiftool version drift: snapshot from \(snapshot.exiftoolVersion), pin is "
                + "\(Self.pinnedExifToolVersion). Follow docs/exiftool-sync.md before bumping."
        )

        var mismatches: [String] = []
        var healedGaps: [String] = []
        var report: [String] = []

        for (file, expected) in snapshot.entries.sorted(by: { $0.key < $1.key }) {
            let fileURL = imagesURL.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                mismatches.append("\(file): missing from corpus (checkout layout changed?)")
                continue
            }

            let resolved = Self.resolveIdentity(of: fileURL)
            let matches = Self.normalized(resolved.make) == Self.normalized(expected.make)
                && Self.normalized(resolved.model) == Self.normalized(expected.model)

            report.append(
                "\(file): ours(make=\(resolved.make ?? "nil"), model=\(resolved.model ?? "nil")) "
                    + "oracle(make=\(expected.make ?? "nil"), model=\(expected.model ?? "nil"))"
            )

            if let gapReason = Self.knownGaps[file] {
                if matches {
                    healedGaps.append("\(file): now matches the oracle -- remove from knownGaps (was: \(gapReason))")
                }
                continue
            }
            if !matches {
                mismatches.append(
                    "\(file): ours(\(resolved.make ?? "nil") / \(resolved.model ?? "nil")) "
                        + "vs exiftool(\(expected.make ?? "nil") / \(expected.model ?? "nil"))"
                )
            }
        }

        if !mismatches.isEmpty || !healedGaps.isEmpty {
            print(report.joined(separator: "\n"))
        }
        XCTAssertTrue(mismatches.isEmpty, "Oracle parity failures:\n" + mismatches.joined(separator: "\n"))
        XCTAssertTrue(healedGaps.isEmpty, "Healed gaps (update knownGaps):\n" + healedGaps.joined(separator: "\n"))
    }

    // MARK: - Fixture-library parity (live mode, needs perl)

    func testFixtureLibraryParityAgainstLiveExifTool() throws {
        let exiftoolScript = Self.exiftoolCheckoutURL.appendingPathComponent("exiftool")
        guard FileManager.default.fileExists(atPath: Self.fixturesRoot.path) else {
            throw XCTSkip("Local fixtures directory not present: \(Self.fixturesRoot.path)")
        }
        guard FileManager.default.fileExists(atPath: exiftoolScript.path) else {
            throw XCTSkip("exiftool checkout not present at \(Self.exiftoolCheckoutURL.path)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("perl not available")
        }

        let videoFiles = try Self.discoverFiles(under: Self.fixturesRoot, extensions: Self.fixtureVideoExtensions)
        guard !videoFiles.isEmpty else {
            throw XCTSkip("No video fixtures found under \(Self.fixturesRoot.path)")
        }

        let oracle = try Self.runExifTool(script: exiftoolScript, over: videoFiles)

        var conflicts: [String] = []
        var report: [String] = []
        var bothResolved = 0
        var oursOnly = 0
        var oracleOnly = 0
        var neither = 0

        for fileURL in videoFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: Self.fixturesRoot.path + "/", with: "")
            let expected = oracle[fileURL.path]
            let resolved = Self.resolveIdentity(of: fileURL)

            let oursHas = resolved.make != nil || resolved.model != nil
            let oracleHas = expected?.make != nil || expected?.model != nil

            switch (oursHas, oracleHas) {
            case (true, true):
                bothResolved += 1
                if let conflict = Self.conflictDescription(ours: resolved, oracle: expected!) {
                    conflicts.append("\(relativePath): \(conflict)")
                }
            case (true, false): oursOnly += 1
            case (false, true): oracleOnly += 1
            case (false, false): neither += 1
            }

            report.append(
                "\(relativePath): ours(make=\(resolved.make ?? "nil"), model=\(resolved.model ?? "nil")) "
                    + "oracle(make=\(expected?.make ?? "nil"), model=\(expected?.model ?? "nil"))"
            )
        }

        print(report.joined(separator: "\n"))
        print(
            "oracle-parity coverage: files=\(videoFiles.count) bothResolved=\(bothResolved) "
                + "oursOnly=\(oursOnly) oracleOnly(coverage gap)=\(oracleOnly) neither=\(neither) "
                + "conflicts=\(conflicts.count)"
        )

        XCTAssertTrue(conflicts.isEmpty, "Conflicting identities vs exiftool:\n" + conflicts.joined(separator: "\n"))
    }

    // MARK: - Shared

    private static func resolveIdentity(of fileURL: URL) -> (make: String?, model: String?, serial: String?) {
        if videoExtensions.contains(fileURL.pathExtension.lowercased()) {
            let metadata = AVFoundationVideoMetadataExtractor()
                .extract(from: fileURL, fallbackMtime: Date(timeIntervalSince1970: 0))
            return (metadata.cameraMake, metadata.cameraModel, metadata.cameraSerial)
        }
        let metadata = ImageIOPhotoMetadataExtractor().extract(from: fileURL)
        return (metadata.cameraMake, metadata.cameraModel, metadata.cameraSerial)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A "conflict" is both sides resolving values that are not even
    /// substring-related -- the same tolerance the fixture regression test
    /// uses, so a terse code contained in a friendlier name is not a
    /// conflict, but two unrelated identities are.
    private static func conflictDescription(
        ours: (make: String?, model: String?, serial: String?),
        oracle: Snapshot.Entry
    ) -> String? {
        var parts: [String] = []
        if let mine = normalized(ours.make), let theirs = normalized(oracle.make),
           !mine.localizedCaseInsensitiveContains(theirs), !theirs.localizedCaseInsensitiveContains(mine)
        {
            parts.append("make ours='\(mine)' oracle='\(theirs)'")
        }
        if let mine = normalized(ours.model), let theirs = normalized(oracle.model),
           !mine.localizedCaseInsensitiveContains(theirs), !theirs.localizedCaseInsensitiveContains(mine)
        {
            parts.append("model ours='\(mine)' oracle='\(theirs)'")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func discoverFiles(under root: URL, extensions: Set<String>) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if extensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func runExifTool(script: URL, over files: [URL]) throws -> [String: Snapshot.Entry] {
        let argfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollkeep-oracle-\(UUID().uuidString).args")
        // Camera identity is not always under Make/Model: Sony XAVC XML uses
        // DeviceManufacturer/DeviceModelName, phones use AndroidManufacturer/
        // AndroidModel. Request the aliases and coalesce below, mirroring
        // scripts/refresh-exiftool-oracle-snapshot.sh.
        var lines = [
            "-j", "-q",
            "-Make", "-Model",
            "-DeviceManufacturer", "-DeviceModelName",
            "-AndroidManufacturer", "-AndroidModel",
            "-SerialNumber", "-BodySerialNumber", "-CameraSerialNumber", "-InternalSerialNumber", "-DeviceSerialNo",
        ]
        lines += files.map(\.path)
        try lines.joined(separator: "\n").write(to: argfile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: argfile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, "-@", argfile.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // exiftool exits non-zero when any file carries none of the
        // requested tags; its JSON output is still valid, so parse whatever
        // came back instead of gating on the exit code.

        guard !output.isEmpty,
              let rows = try JSONSerialization.jsonObject(with: output) as? [[String: Any]]
        else {
            return [:]
        }

        var entries: [String: Snapshot.Entry] = [:]
        for row in rows {
            guard let source = row["SourceFile"] as? String else {
                continue
            }
            entries[source] = Snapshot.Entry(
                make: Self.pick(row, ["Make", "DeviceManufacturer", "AndroidManufacturer"]),
                model: Self.pick(row, ["Model", "DeviceModelName", "AndroidModel"]),
                serial: Self.pick(row, [
                    "BodySerialNumber", "SerialNumber", "CameraSerialNumber",
                    "InternalSerialNumber", "DeviceSerialNo",
                ]),
                uniqueCameraModel: nil
            )
        }
        return entries
    }

    private static func pick(_ row: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] {
                let string = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }
}
