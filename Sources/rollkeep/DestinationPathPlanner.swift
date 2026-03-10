import Foundation
import RollKeepCore

struct DestinationPathPlanner {
    struct SourceFile {
        let candidate: MediaCandidate
        let cameraLabel: String
        let sourceHash: String?

        init(candidate: MediaCandidate, cameraLabel: String, sourceHash: String? = nil) {
            self.candidate = candidate
            self.cameraLabel = cameraLabel
            self.sourceHash = sourceHash
        }
    }

    enum Disposition: String {
        case stageAndCommit = "stage_and_commit"
        case duplicateNotCopied = "duplicate_not_copied"
    }

    struct PlannedFile {
        let candidate: MediaCandidate
        let cameraLabel: String
        let sourceHash: String?
        let finalPath: String
        let stagingPath: String?
        let disposition: Disposition
        let collisionResolved: Bool
        let collisionSuffix: Int?
        let duplicateOfPath: String?
    }

    struct Plan {
        let files: [PlannedFile]
        let directoriesToCreate: [String]

        var duplicatesSkipped: Int {
            files.filter { $0.disposition == .duplicateNotCopied }.count
        }

        var conflictsRenamed: Int {
            files.filter(\.collisionResolved).count
        }
    }

    func plan(
        destRoot: URL,
        sessionID: String,
        files: [SourceFile],
        existingFinalFiles: [String: String?] = [:]
    ) -> Plan {
        var occupiedByHash: [String: String?] = existingFinalFiles.reduce(into: [:]) { partial, entry in
            partial[normalizePath(entry.key)] = entry.value
        }
        var planned: [PlannedFile] = []
        var directories: Set<String> = []

        for file in files {
            let mediaTypeFolder = file.candidate.mediaType == .photo ? "Photos" : "Videos"
            let captureDate = captureDate(for: file.candidate)
            let cameraLabel = sanitizeCameraLabel(file.cameraLabel)
            let filename = sourceFilename(for: file.candidate)
            let bucketComponents = bucketPathComponents(for: captureDate)

            let finalDirURL = destinationDirectory(
                destRoot: destRoot,
                bucketComponents: bucketComponents,
                cameraLabel: cameraLabel,
                mediaTypeFolder: mediaTypeFolder
            )
            let baseFinalPath = finalDirURL.appendingPathComponent(filename, isDirectory: false).path
            let resolved = resolveFinalPath(
                basePath: baseFinalPath,
                sourceHash: file.sourceHash,
                occupiedByHash: occupiedByHash
            )

            switch resolved.kind {
            case .duplicate:
                planned.append(PlannedFile(
                    candidate: file.candidate,
                    cameraLabel: cameraLabel,
                    sourceHash: file.sourceHash,
                    finalPath: resolved.path,
                    stagingPath: nil,
                    disposition: .duplicateNotCopied,
                    collisionResolved: false,
                    collisionSuffix: nil,
                    duplicateOfPath: resolved.path
                ))
            case .commit:
                let stagingDirURL = stagingDirectory(
                    destRoot: destRoot,
                    sessionID: sessionID,
                    bucketComponents: bucketComponents,
                    cameraLabel: cameraLabel,
                    mediaTypeFolder: mediaTypeFolder
                )
                let stagingPath = stagingDirURL.appendingPathComponent(lastPathComponent(of: resolved.path), isDirectory: false).path

                occupiedByHash[normalizePath(resolved.path)] = file.sourceHash
                directories.insert(normalizePath(finalDirURL.path))
                directories.insert(normalizePath(stagingDirURL.path))

                planned.append(PlannedFile(
                    candidate: file.candidate,
                    cameraLabel: cameraLabel,
                    sourceHash: file.sourceHash,
                    finalPath: resolved.path,
                    stagingPath: stagingPath,
                    disposition: .stageAndCommit,
                    collisionResolved: resolved.collisionSuffix != nil,
                    collisionSuffix: resolved.collisionSuffix,
                    duplicateOfPath: nil
                ))
            }
        }

        return Plan(
            files: planned,
            directoriesToCreate: directories.sorted()
        )
    }

    private enum ResolveKind {
        case commit
        case duplicate
    }

    private struct ResolvedFinalPath {
        let kind: ResolveKind
        let path: String
        let collisionSuffix: Int?
    }

    private func resolveFinalPath(
        basePath: String,
        sourceHash: String?,
        occupiedByHash: [String: String?]
    ) -> ResolvedFinalPath {
        let normalizedBasePath = normalizePath(basePath)

        if let existingHash = occupiedByHash[normalizedBasePath] {
            if isDuplicate(sourceHash: sourceHash, existingHash: existingHash) {
                return ResolvedFinalPath(kind: .duplicate, path: normalizedBasePath, collisionSuffix: nil)
            }

            var suffix = 1
            while true {
                let candidatePath = normalizePath(pathByAppendingCollisionSuffix(basePath: normalizedBasePath, suffix: suffix))
                if let candidateHash = occupiedByHash[candidatePath] {
                    if isDuplicate(sourceHash: sourceHash, existingHash: candidateHash) {
                        return ResolvedFinalPath(kind: .duplicate, path: candidatePath, collisionSuffix: nil)
                    }
                    suffix += 1
                    continue
                }

                return ResolvedFinalPath(kind: .commit, path: candidatePath, collisionSuffix: suffix)
            }
        }

        return ResolvedFinalPath(kind: .commit, path: normalizedBasePath, collisionSuffix: nil)
    }

    private func destinationDirectory(
        destRoot: URL,
        bucketComponents: [String],
        cameraLabel: String,
        mediaTypeFolder: String
    ) -> URL {
        var result = destRoot
        for component in bucketComponents {
            result = result.appendingPathComponent(component, isDirectory: true)
        }
        return result
            .appendingPathComponent(cameraLabel, isDirectory: true)
            .appendingPathComponent(mediaTypeFolder, isDirectory: true)
    }

    private func stagingDirectory(
        destRoot: URL,
        sessionID: String,
        bucketComponents: [String],
        cameraLabel: String,
        mediaTypeFolder: String
    ) -> URL {
        var result = destRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        for component in bucketComponents {
            result = result.appendingPathComponent(component, isDirectory: true)
        }
        return result
            .appendingPathComponent(cameraLabel, isDirectory: true)
            .appendingPathComponent(mediaTypeFolder, isDirectory: true)
    }

    private func captureDate(for candidate: MediaCandidate) -> Date? {
        switch candidate.mediaType {
        case .photo:
            return candidate.photoMetadata?.captureDateTime
        case .video:
            return candidate.videoMetadata?.captureDateTime
        }
    }

    private func bucketPathComponents(for captureDate: Date?) -> [String] {
        guard let captureDate else {
            return ["_unsorted"]
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month], from: captureDate)

        guard let year = components.year, let month = components.month else {
            return ["_unsorted"]
        }

        let yearComponent = String(year)
        let monthYearComponent = String(format: "%02d%04d", month, year)
        return [yearComponent, monthYearComponent]
    }

    private func sourceFilename(for candidate: MediaCandidate) -> String {
        let filename = lastPathComponent(of: candidate.relativePath)
        return filename.isEmpty ? "unknown-file" : filename
    }

    private func pathByAppendingCollisionSuffix(basePath: String, suffix: Int) -> String {
        let filename = lastPathComponent(of: basePath)
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        let suffixedName: String
        if ext.isEmpty {
            suffixedName = "\(stem)-\(suffix)"
        } else {
            suffixedName = "\(stem)-\(suffix).\(ext)"
        }

        return URL(fileURLWithPath: basePath, isDirectory: false)
            .deletingLastPathComponent()
            .appendingPathComponent(suffixedName, isDirectory: false)
            .path
    }

    private func isDuplicate(sourceHash: String?, existingHash: String?) -> Bool {
        guard let sourceHash, let existingHash else {
            return false
        }
        return sourceHash == existingHash
    }

    private func sanitizeCameraLabel(_ label: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in label.lowercased().unicodeScalars {
            guard scalar.isASCII else {
                continue
            }

            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
                continue
            }

            if scalar == "-" {
                if !previousWasSeparator, !result.isEmpty {
                    result.append("-")
                    previousWasSeparator = true
                }
                continue
            }

            if !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown-camera" : trimmed
    }

    private func lastPathComponent(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }
}
