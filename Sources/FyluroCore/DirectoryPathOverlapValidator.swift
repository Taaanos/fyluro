import Foundation

public enum DirectoryPathRelation: String, Equatable, Sendable {
    case disjoint
    case same
    case sourceContainsDestination
    case destinationContainsSource
}

public struct DirectoryPathPairAnalysis: Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let relation: DirectoryPathRelation

    public init(sourcePath: String, destinationPath: String, relation: DirectoryPathRelation) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.relation = relation
    }

    public var isDisjoint: Bool {
        relation == .disjoint
    }

    public var overlapMessage: String {
        let requirement = "Source and destination must be different folders with no nesting."
        switch relation {
        case .same:
            return "\(requirement) Both resolved to \(sourcePath)."
        case .sourceContainsDestination:
            return "\(requirement) Destination \(destinationPath) is inside source \(sourcePath)."
        case .destinationContainsSource:
            return "\(requirement) Source \(sourcePath) is inside destination \(destinationPath)."
        case .disjoint:
            return requirement
        }
    }
}

public enum DirectoryPathOverlapValidator {
    public static func analyze(sourcePath: String, destinationPath: String) -> DirectoryPathPairAnalysis {
        analyze(sourcePath: sourcePath, destinationPath: destinationPath, caseSensitiveOverride: nil)
    }

    static func analyze(
        sourcePath: String,
        destinationPath: String,
        caseSensitiveOverride: Bool?
    ) -> DirectoryPathPairAnalysis {
        let resolvedSource = canonicalDirectoryPathAndAncestor(sourcePath)
        let resolvedDestination = canonicalDirectoryPathAndAncestor(destinationPath)

        let sourceComponents = URL(fileURLWithPath: resolvedSource.canonicalPath, isDirectory: true).pathComponents
        let destinationComponents = URL(fileURLWithPath: resolvedDestination.canonicalPath, isDirectory: true).pathComponents

        let caseInsensitive: Bool
        if let caseSensitiveOverride {
            caseInsensitive = !caseSensitiveOverride
        } else {
            caseInsensitive = !isCaseSensitiveVolume(at: resolvedSource.existingAncestor)
                || !isCaseSensitiveVolume(at: resolvedDestination.existingAncestor)
        }

        let relation: DirectoryPathRelation
        if componentsEqual(sourceComponents, destinationComponents, caseInsensitive: caseInsensitive) {
            relation = .same
        } else if componentsStart(destinationComponents, with: sourceComponents, caseInsensitive: caseInsensitive) {
            relation = .sourceContainsDestination
        } else if componentsStart(sourceComponents, with: destinationComponents, caseInsensitive: caseInsensitive) {
            relation = .destinationContainsSource
        } else {
            relation = .disjoint
        }

        return DirectoryPathPairAnalysis(
            sourcePath: resolvedSource.canonicalPath,
            destinationPath: resolvedDestination.canonicalPath,
            relation: relation
        )
    }

    private static func canonicalDirectoryPathAndAncestor(
        _ path: String
    ) -> (canonicalPath: String, existingAncestor: URL) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let standardizedURL = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default

        var pendingComponents: [String] = []
        var probeURL = standardizedURL

        // Walk up until we hit an existing path so symlinks in existing
        // ancestors still resolve when trailing destination folders are new.
        while probeURL.path != "/" && !fileManager.fileExists(atPath: probeURL.path) {
            let component = probeURL.lastPathComponent
            if !component.isEmpty && component != "/" {
                pendingComponents.append(component)
            }
            probeURL = probeURL.deletingLastPathComponent()
        }

        let resolvedAncestor = probeURL.resolvingSymlinksInPath().standardizedFileURL
        var combinedURL = resolvedAncestor
        for component in pendingComponents.reversed() {
            combinedURL = combinedURL.appendingPathComponent(component, isDirectory: true)
        }

        return (combinedURL.standardizedFileURL.path, resolvedAncestor)
    }

    private static func isCaseSensitiveVolume(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames ?? false
    }

    private static func componentsEqual(
        _ lhs: [String],
        _ rhs: [String],
        caseInsensitive: Bool
    ) -> Bool {
        lhs.elementsEqual(rhs) { componentMatches($0, $1, caseInsensitive: caseInsensitive) }
    }

    private static func componentsStart(
        _ full: [String],
        with prefix: [String],
        caseInsensitive: Bool
    ) -> Bool {
        full.starts(with: prefix) { componentMatches($0, $1, caseInsensitive: caseInsensitive) }
    }

    private static func componentMatches(
        _ lhs: String,
        _ rhs: String,
        caseInsensitive: Bool
    ) -> Bool {
        if caseInsensitive {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }
        return lhs == rhs
    }
}
