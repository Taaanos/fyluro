import Foundation

/// User-declared metadata for a batch of digitized film photos, applied once
/// per ingest to replace misleading EXIF written by the digitizing camera
/// (e.g. a DSLR's scan date/model instead of the original shoot date/camera).
public struct FilmModeOverride: Sendable, Codable, Equatable {
    public let year: Int
    public let month: Int // 1...12
    public let camera: String
    public let lens: String?
    public let filmStock: String?
    public let iso: Int?
    /// The sensitivity the roll was actually exposed/developed at, when it
    /// differs from `iso` (the film's box speed) -- i.e. a pushed or pulled
    /// roll. Distinct EXIF tag from `iso`: ExposureIndex vs ISOSpeedRatings.
    public let shotAtISO: Int?
    public let developmentNotes: String?
    public let scannerSetup: String?
    public let creator: String?
    public let copyright: String?

    public init(
        year: Int,
        month: Int,
        camera: String,
        lens: String? = nil,
        filmStock: String?,
        iso: Int?,
        shotAtISO: Int? = nil,
        developmentNotes: String? = nil,
        scannerSetup: String? = nil,
        creator: String?,
        copyright: String?
    ) {
        self.year = year
        self.month = month
        self.camera = camera
        self.lens = lens
        self.filmStock = filmStock
        self.iso = iso
        self.shotAtISO = shotAtISO
        self.developmentNotes = developmentNotes
        self.scannerSetup = scannerSetup
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
