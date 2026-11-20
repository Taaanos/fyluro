import Foundation

struct EmbeddedVideoMetadataTextParser {
    func extract(
        from fileURL: URL,
        parser: VideoCreationDateParser,
        byteCount: Int = 2 * 1024 * 1024
    ) -> VideoMetadataSnapshot {
        guard let data = readSearchData(from: fileURL, byteCount: byteCount) else {
            return VideoMetadataSnapshot(
                captureDateTime: nil,
                captureDateSource: nil,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        }

        let printableStrings = extractPrintableStrings(from: data, minimumLength: 6)
        let rawText = String(decoding: data, as: UTF8.self)
        return parse(rawText: rawText, printableStrings: printableStrings, parser: parser)
    }

    /// Narrow, cheap lookup for just a heuristic-matched model name (e.g. a
    /// vendor's friendly product name like "DJI OsmoAction6") within an
    /// already-bounded byte range -- unlike `extract`/`parse`, this skips the
    /// ~20 date/labeled-field/XML regexes run over the *entire* text, which
    /// dominate the cost of a full scan on multi-megabyte input. Intended for
    /// callers that already have make/serial from elsewhere and only want to
    /// check whether a friendlier model string exists nearby.
    func findFriendlierModel(in data: Data) -> String? {
        let printableStrings = extractPrintableStrings(from: data, minimumLength: 6)
        return firstMatchingPrintableString(in: printableStrings, regexes: Self.heuristicModelRegexes)
    }

    func parse(
        rawText: String,
        printableStrings: [String],
        parser: VideoCreationDateParser
    ) -> VideoMetadataSnapshot {
        var searchableTextCache: String?
        func searchableText() -> String {
            if let searchableTextCache {
                return searchableTextCache
            }
            if printableStrings.isEmpty {
                searchableTextCache = rawText
            } else {
                searchableTextCache = rawText + "\n" + printableStrings.joined(separator: "\n")
            }
            return searchableTextCache ?? rawText
        }

        let rawRange = NSRange(rawText.startIndex..., in: rawText)
        var creationDate: Date?
        var xmlDevice: (make: String?, model: String?, serial: String?) = (nil, nil, nil)
        var cameraMake: String?
        var cameraModel: String?
        var cameraSerial: String?

        if hasAnyFieldAnchor(rawText, range: rawRange) {
            creationDate = firstMatch(in: rawText, range: rawRange, regexes: Self.creationDateRegexes).flatMap(parser.parse)
            xmlDevice = parseXMLDevice(in: rawText, range: rawRange)
            cameraMake = sanitize(xmlDevice.make ?? firstMatch(in: rawText, range: rawRange, regexes: Self.labeledMakeRegexes))
            cameraModel = sanitize(xmlDevice.model ?? firstMatch(in: rawText, range: rawRange, regexes: Self.labeledModelRegexes))
            cameraSerial = sanitizeSerial(xmlDevice.serial ?? firstMatch(in: rawText, range: rawRange, regexes: Self.labeledSerialRegexes))
        }

        if creationDate == nil || cameraMake == nil || cameraModel == nil || cameraSerial == nil {
            let combinedText = searchableText()
            let combinedRange = NSRange(combinedText.startIndex..., in: combinedText)
            if hasAnyFieldAnchor(combinedText, range: combinedRange) {
                if creationDate == nil {
                    creationDate = firstMatch(in: combinedText, range: combinedRange, regexes: Self.creationDateRegexes).flatMap(parser.parse)
                }
                if cameraMake == nil || cameraModel == nil || cameraSerial == nil {
                    xmlDevice = parseXMLDevice(in: combinedText, range: combinedRange)
                    if cameraSerial == nil {
                        cameraSerial = sanitizeSerial(xmlDevice.serial ?? firstMatch(in: combinedText, range: combinedRange, regexes: Self.labeledSerialRegexes))
                    }
                    if cameraMake == nil {
                        cameraMake = sanitize(xmlDevice.make ?? firstMatch(in: combinedText, range: combinedRange, regexes: Self.labeledMakeRegexes))
                    }
                    if cameraModel == nil {
                        cameraModel = sanitize(xmlDevice.model ?? firstMatch(in: combinedText, range: combinedRange, regexes: Self.labeledModelRegexes))
                    }
                }
            }
        }

        if cameraMake == nil {
            cameraMake = firstMatchingPrintableString(
                in: printableStrings,
                regexes: Self.heuristicMakeRegexes
            )
        }
        if cameraModel == nil {
            cameraModel = firstMatchingPrintableString(
                in: printableStrings,
                regexes: Self.heuristicModelRegexes
            )
        }

        return VideoMetadataSnapshot(
            captureDateTime: creationDate,
            captureDateSource: creationDate == nil ? nil : .creationTime,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial,
            cameraMakeSource: cameraMake == nil ? nil : .embeddedMetadataMake,
            cameraModelSource: cameraModel == nil ? nil : .embeddedMetadataModel,
            cameraSerialSource: cameraSerial == nil ? nil : .embeddedMetadataSerial,
            cameraMakeSelectionRule: "embedded_text_direct",
            cameraModelSelectionRule: "embedded_text_direct",
            cameraSerialSelectionRule: "embedded_text_direct"
        )
    }

    private func readSearchData(from fileURL: URL, byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0 else {
            return try? handle.read(upToCount: byteCount)
        }

        guard fileSize > byteCount else {
            return try? handle.read(upToCount: byteCount)
        }

        let prefix = try? handle.read(upToCount: byteCount)
        let suffixOffset = max(fileSize - byteCount, 0)
        try? handle.seek(toOffset: UInt64(suffixOffset))
        let suffix = try? handle.readToEnd()

        var combined = Data()
        if let prefix {
            combined.append(prefix)
        }
        combined.append(0x0A)
        if let suffix {
            combined.append(suffix)
        }
        return combined
    }

    func extractPrintableStrings(from data: Data, minimumLength: Int) -> [String] {
        guard !data.isEmpty else {
            return []
        }

        var strings: [String] = []
        var buffer = ""
        buffer.reserveCapacity(minimumLength * 2)

        for byte in data {
            if byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte) {
                buffer.append(Character(UnicodeScalar(Int(byte))!))
                continue
            }

            flushBuffer(&buffer, into: &strings, minimumLength: minimumLength)
        }

        flushBuffer(&buffer, into: &strings, minimumLength: minimumLength)
        return strings
    }

    private func flushBuffer(_ buffer: inout String, into strings: inout [String], minimumLength: Int) {
        defer { buffer.removeAll(keepingCapacity: true) }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else {
            return
        }

        strings.append(trimmed)
    }

    private func parseXMLDevice(in rawText: String, range: NSRange) -> (make: String?, model: String?, serial: String?) {
        guard
            let match = Self.xmlDeviceRegex.firstMatch(in: rawText, range: range),
            let make = substring(in: rawText, result: match, at: 1),
            let model = substring(in: rawText, result: match, at: 2)
        else {
            return (nil, nil, nil)
        }

        return (
            make: make,
            model: model,
            serial: substring(in: rawText, result: match, at: 3)
        )
    }

    // Every date/labeled-field/XML-device regex requires one of these literals
    // (case-insensitive) to be present, so a single cheap pre-check can skip the
    // entire ~20-pattern battery -- which dominates cost on a multi-megabyte
    // window -- when none of them appear anywhere in the text at all (e.g. a
    // vendor with no EXIF-style embedded text, only a proprietary binary
    // trailer). A single NSRegularExpression alternation is used rather than
    // separate per-literal substring checks: measured ~10x faster on a 4MB
    // text (ICU's literal-alternation matching vs. repeated calls to
    // String/NSString range(of:)).
    private static let anyFieldAnchorRegex = try! NSRegularExpression(
        pattern: "CreationDate|CreateDate|DateTimeOriginal|<Device|Make|Manufacturer|Model|Serial",
        options: [.caseInsensitive]
    )

    private func hasAnyFieldAnchor(_ text: String, range: NSRange) -> Bool {
        Self.anyFieldAnchorRegex.firstMatch(in: text, range: range) != nil
    }

    private func firstMatch(in rawText: String, range: NSRange, regexes: [NSRegularExpression]) -> String? {
        for regex in regexes {
            guard let match = regex.firstMatch(in: rawText, range: range),
                  let value = substring(in: rawText, result: match, at: 1)
            else {
                continue
            }

            return value
        }

        return nil
    }

    private func firstMatchingPrintableString(in strings: [String], regexes: [NSRegularExpression]) -> String? {
        for regex in regexes {
            var best: String?
            var bestScore = Int.min

            for candidate in strings {
                let range = NSRange(candidate.startIndex..., in: candidate)
                guard regex.firstMatch(in: candidate, range: range) != nil else {
                    continue
                }

                let score = candidateQualityScore(candidate)
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
            }

            guard let best else {
                continue
            }

            if best.hasSuffix("STRM") {
                return String(best.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return best
        }

        return nil
    }

    /// Firmware debug/section markers (e.g. "DJI meta", "DJI dbgi") match the same
    /// broad heuristic model regexes as real model names but never contain a digit,
    /// so digit-bearing candidates are strongly preferred; word count breaks ties.
    private func candidateQualityScore(_ candidate: String) -> Int {
        let hasDigit = candidate.rangeOfCharacter(from: .decimalDigits) != nil
        let wordCount = candidate.split(separator: " ").count
        return (hasDigit ? 1000 : 0) + wordCount
    }

    private static let xmlDeviceRegex = try! NSRegularExpression(
        pattern: #"<Device\b[^>]*manufacturer="([^"]+)"[^>]*modelName="([^"]+)"[^>]*serialNo="([^"]+)""#,
        options: [.caseInsensitive]
    )

    private static let creationDateRegexes = compileRegexes(
        [
            #"<CreationDate[^>]*value="([^"]+)""#,
            #"CreationDate(?:Value)?\s*[:=]\s*([^\r\n<]+)"#,
            #"CreateDate\s*[:=]\s*([^\r\n<]+)"#,
            #"DateTimeOriginal\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?CreateDate>\s*([^<]+)\s*</(?:[\w-]+:)?CreateDate>"#,
            #"<(?:[\w-]+:)?DateTimeOriginal>\s*([^<]+)\s*</(?:[\w-]+:)?DateTimeOriginal>"#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledModelRegexes = compileRegexes(
        [
            #"Camera Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Device Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Model Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Model\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?Model>\s*([^<]+)\s*</(?:[\w-]+:)?Model>"#,
            #"(?:\b[\w-]+:)?Model\s*=\s*"([^"]+)""#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledMakeRegexes = compileRegexes(
        [
            #"Camera Make Name\s*[:=]\s*([^\r\n<]+)"#,
            #"Device Manufacturer\s*[:=]\s*([^\r\n<]+)"#,
            #"Make\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?Make>\s*([^<]+)\s*</(?:[\w-]+:)?Make>"#,
            #"(?:\b[\w-]+:)?Make\s*=\s*"([^"]+)""#,
        ],
        options: [.caseInsensitive]
    )

    private static let labeledSerialRegexes = compileRegexes(
        [
            #"Camera Serial Number\s*[:=]\s*([^\r\n<]+)"#,
            #"CameraSerialNumber\s*[:=]\s*([^\r\n<]+)"#,
            #"Serial Number\s*[:=]\s*([^\r\n<]+)"#,
            #"SerialNumber\s*[:=]\s*([^\r\n<]+)"#,
            #"<(?:[\w-]+:)?CameraSerialNumber>\s*([^<]+)\s*</(?:[\w-]+:)?CameraSerialNumber>"#,
            #"<(?:[\w-]+:)?SerialNumber>\s*([^<]+)\s*</(?:[\w-]+:)?SerialNumber>"#,
        ],
        options: [.caseInsensitive]
    )

    private static let heuristicModelRegexes = compileRegexes(
        [
            #"^ILCE-[A-Z0-9-]+$"#,
            #"^DSC-[A-Z0-9-]+$"#,
            #"^HERO\d+(?:\s+[A-Za-z0-9]+)+$"#,
            #"^DJI\s+(?=[A-Za-z0-9 ]*[a-z])[A-Za-z0-9]+(?:\s+[A-Za-z0-9]+){0,4}$"#,
            #"^Insta360\s+[A-Za-z0-9]+(?:\s+[A-Za-z0-9]+){0,3}$"#,
        ]
    )

    private static let heuristicMakeRegexes = compileRegexes(
        [
            #"^Sony$"#,
            #"^GoPro$"#,
            #"^Canon$"#,
            #"^FUJIFILM$"#,
            #"^NIKON$"#,
            #"^DJI$"#,
            #"^Insta360$"#,
        ]
    )

    private static func compileRegexes(
        _ patterns: [String],
        options: NSRegularExpression.Options = []
    ) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private func substring(in text: String, result: NSTextCheckingResult, at index: Int) -> String? {
        guard let range = Range(result.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    // Real-world make/model/serial strings are always well under this (e.g.
    // "Apple iPhone 15 Pro 13mm" is ~24 chars); matches the existing
    // `DJIXtraMetadataDecoder.maxModelCodeUnits` precedent. The regex capture
    // groups above have no length bound of their own, so a crafted field
    // (e.g. "Model:" followed by ~2MB of non-CR/LF/`<` bytes) would otherwise
    // flow through as a single unbroken token into the camera label, path
    // components, and PDF receipt rendering.
    private static let maxSanitizedValueLength = 128

    private func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maxSanitizedValueLength
        else {
            return nil
        }
        return trimmed
    }

    private func sanitizeSerial(_ value: String?) -> String? {
        guard let trimmed = sanitize(value) else {
            return nil
        }

        if trimmed == "0" || trimmed == "4294967295" {
            return nil
        }

        if trimmed.allSatisfy(\.isNumber), Set(trimmed).count == 1 {
            return nil
        }

        return trimmed
    }
}
