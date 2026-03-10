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
}

public enum DirectoryPathOverlapValidator {
    public static func analyze(sourcePath: String, destinationPath: String) -> DirectoryPathPairAnalysis {
        let canonicalSourcePath = canonicalDirectoryPath(sourcePath)
        let canonicalDestinationPath = canonicalDirectoryPath(destinationPath)

        let sourceComponents = URL(fileURLWithPath: canonicalSourcePath, isDirectory: true).pathComponents
        let destinationComponents = URL(fileURLWithPath: canonicalDestinationPath, isDirectory: true).pathComponents

        let relation: DirectoryPathRelation
        if sourceComponents == destinationComponents {
            relation = .same
        } else if destinationComponents.starts(with: sourceComponents) {
            relation = .sourceContainsDestination
        } else if sourceComponents.starts(with: destinationComponents) {
            relation = .destinationContainsSource
        } else {
            relation = .disjoint
        }

        return DirectoryPathPairAnalysis(
            sourcePath: canonicalSourcePath,
            destinationPath: canonicalDestinationPath,
            relation: relation
        )
    }

    private static func canonicalDirectoryPath(_ path: String) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
