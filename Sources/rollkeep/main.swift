import Foundation

private struct Config {
    var source: String?
    var dest: String?
    var dryRun = false
    var verbose = false
    var wantsHelp = false
}

private let usage = """
USAGE:
  rollkeep --source <path> --dest <path> [--dry-run] [--verbose]

OPTIONS:
  --source <path>    Source media path.
  --dest <path>      Destination library path.
  --dry-run          Run planning only; do not write files.
  --verbose          Print additional diagnostic output.
  -h, --help         Show this help output.
"""

private func parseArgs(_ args: [String]) throws -> Config {
    var config = Config()
    var index = 0

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            config.wantsHelp = true
            index += 1
        case "--dry-run":
            config.dryRun = true
            index += 1
        case "--verbose":
            config.verbose = true
            index += 1
        case "--source":
            index += 1
            guard index < args.count else {
                throw ParseError.missingValue("--source")
            }
            config.source = args[index]
            index += 1
        case "--dest":
            index += 1
            guard index < args.count else {
                throw ParseError.missingValue("--dest")
            }
            config.dest = args[index]
            index += 1
        default:
            throw ParseError.unknownFlag(arg)
        }
    }

    return config
}

private enum ParseError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownFlag(String)
    case requiredArg(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .unknownFlag(let flag):
            return "Unknown argument: \(flag)"
        case .requiredArg(let flag):
            return "Missing required argument: \(flag)"
        }
    }
}

private func run() -> Int32 {
    do {
        let config = try parseArgs(Array(CommandLine.arguments.dropFirst()))
        if config.wantsHelp {
            print(usage)
            return 0
        }

        guard config.source != nil else {
            throw ParseError.requiredArg("--source")
        }
        guard config.dest != nil else {
            throw ParseError.requiredArg("--dest")
        }

        if config.verbose {
            print("Verbose mode enabled.")
        }

        if config.dryRun {
            print("Dry run: rollkeep ingest plan generated (no files written).")
        } else {
            print("Rollkeep CLI skeleton ready.")
        }
        return 0
    } catch let error as ParseError {
        fputs("error: \(error.description)\n\n", stderr)
        fputs("\(usage)\n", stderr)
        return 2
    } catch {
        fputs("error: \(error)\n", stderr)
        return 1
    }
}

exit(run())
