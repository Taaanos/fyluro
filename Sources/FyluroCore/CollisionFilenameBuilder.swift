import Foundation

public enum CollisionFilenameBuilder {
    public static let maxFilenameUTF8Bytes = 255

    public static func filenameByAppendingCollisionSuffix(
        to filename: String,
        suffix: Int,
        maxBytes: Int = maxFilenameUTF8Bytes
    ) -> String {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        let tail = ext.isEmpty ? "-\(suffix)" : "-\(suffix).\(ext)"
        let maxStemBytes = max(0, maxBytes - tail.utf8.count)
        let trimmedStem = trimToUTF8ByteLimit(stem, maxBytes: maxStemBytes)
        return "\(trimmedStem)\(tail)"
    }

    public static func pathByAppendingCollisionSuffix(
        basePath: String,
        suffix: Int,
        maxBytes: Int = maxFilenameUTF8Bytes
    ) -> String {
        let fileURL = URL(fileURLWithPath: basePath, isDirectory: false)
        let suffixedName = filenameByAppendingCollisionSuffix(
            to: fileURL.lastPathComponent,
            suffix: suffix,
            maxBytes: maxBytes
        )
        return fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(suffixedName, isDirectory: false)
            .path
    }

    static func trimToUTF8ByteLimit(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }
        if string.utf8.count <= maxBytes {
            return string
        }

        var byteCount = 0
        var endIndex = string.startIndex
        for index in string.indices {
            let charByteCount = string[index].utf8.count
            if byteCount + charByteCount > maxBytes {
                break
            }
            byteCount += charByteCount
            endIndex = string.index(after: index)
        }
        return String(string[..<endIndex])
    }
}
