import Foundation

/// User-declared metadata for a batch of digitized film photos, applied once
/// per ingest to replace misleading EXIF written by the digitizing camera
/// (e.g. a DSLR's scan date/model instead of the original shoot date/camera).
public struct FilmModeOverride: Sendable, Codable, Equatable {
    public let year: Int
    public let month: Int // 1...12
    public let camera: String
    public let filmStock: String?
    public let iso: Int?
    public let creator: String?
    public let copyright: String?

    public init(year: Int, month: Int, camera: String, filmStock: String?, iso: Int?, creator: String?, copyright: String?) {
        self.year = year
        self.month = month
        self.camera = camera
        self.filmStock = filmStock
        self.iso = iso
        self.creator = creator
        self.copyright = copyright
    }

    /// The first day of the declared month, in UTC, used as the override capture date.
    public var captureDate: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
