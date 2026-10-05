import ArgumentParser
import Foundation
import RollKeepCore

struct RollkeepCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollkeep",
        abstract: "Safely ingest media from a source path into a destination library.",
        discussion: "Each run scans the source, copies files to a staging folder, verifies them by read-back hash, and commits them to final library paths. A receipt is always written."
    )

    @Option(name: .long, help: "Source media path. If omitted, rollkeep auto-detects a likely card mount under /Volumes.")
    var source: String?

    @Option(name: .long, help: "Destination library path. If omitted, rollkeep reuses the last remembered mounted destination when available.")
    var dest: String?

    @Flag(name: .long, help: "Run planning only; do not write files.")
    var dryRun = false

    @Flag(name: .long, help: "Print verbose diagnostic logs.")
    var verbose = false

    @Flag(name: .long, help: "Write a human-readable PDF summary next to the NDJSON receipt.")
    var pdf = false

    @Option(name: .long, help: "Maximum number of files copied to staging in parallel.")
    var maxParallelCopies = 2

    @Option(name: .long, help: "Seconds to watch /Volumes for a newly mounted source card when --source is omitted. Use 0 to wait indefinitely.")
    var detectTimeoutSeconds = 60

    @Flag(name: .long, help: "Always show source picker when --source is omitted.")
    var pickSource = false

    @Flag(name: .long, help: "Always show destination picker when --dest is omitted.")
    var pickDest = false

    @Flag(name: .long, help: "Print final ingest summary as JSON.")
    var json = false

    @Option(
        name: .long,
        help: ArgumentHelp("Internal app bridge: override path chronology mode.", visibility: .hidden)
    )
    var pathChronological: String?

    @Flag(
        name: .long,
        help: ArgumentHelp("Internal app bridge: disable camera folder grouping.", visibility: .hidden)
    )
    var pathNoCamera = false

    @Flag(
        name: .long,
        help: ArgumentHelp("Internal app bridge: split photos into RAW/Non-RAW folders.", visibility: .hidden)
    )
    var pathSplitRaw = false

    mutating func validate() throws {
        if maxParallelCopies < 1 {
            throw ValidationError("--max-parallel-copies must be at least 1")
        }
        if detectTimeoutSeconds < 0 {
            throw ValidationError("--detect-timeout-seconds must be greater than or equal to 0")
        }
        if let pathChronological,
           PathChronologicalLayout.parseCLIValue(pathChronological) == nil {
            throw ValidationError("--path-chronological must be one of: YYYY/YYYYMM, YYYY/MM")
        }
    }
}

RollkeepCLI.main()
