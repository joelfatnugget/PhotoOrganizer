import Foundation
import ImageIO
import AVFoundation
import CryptoKit

/// Extracted deterministic metadata for a media item prior to AI inference.
public struct ExtractedMetadata: Sendable {
    public let captureDate: Date
    public let dateSource: DateSource
    public let gps: GPSCoordinate?
    public let isScreenshot: Bool
    public let fileSize: Int64
    public let sha256Hash: String

    public init(
        captureDate: Date,
        dateSource: DateSource,
        gps: GPSCoordinate?,
        isScreenshot: Bool,
        fileSize: Int64,
        sha256Hash: String
    ) {
        self.captureDate = captureDate
        self.dateSource = dateSource
        self.gps = gps
        self.isScreenshot = isScreenshot
        self.fileSize = fileSize
        self.sha256Hash = sha256Hash
    }
}

/// Extracts EXIF/QuickTime/filename dates, GPS coordinates, Live Photo Content IDs, screenshot flags, and SHA256 hashes.
public struct MetadataExtractor: Sendable {
    private static let exifDateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy:MM:dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy:MM:dd HH:mm:ssXXXXX"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    public init() {}

    /// Extracts metadata for a scanned media entry using the 4-tier date cascade and streaming SHA256.
    public func extract(entry: ScannedMediaEntry) async -> ExtractedMetadata {
        let url = entry.primaryURL
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let fileSize = Int64(resourceValues?.fileSize ?? 0)
        let hash = (try? Self.computeSHA256(for: url)) ?? ""

        let isVideo = (entry.mediaKind == .video)

        var captureDate: Date?
        var dateSource: DateSource = .fileSystem
        var gps: GPSCoordinate?
        var isScreenshot = Self.isScreenshotFilename(url.lastPathComponent)

        if !isVideo, let properties = Self.readImageProperties(from: url) {
            if let exifDate = Self.extractEXIFDate(from: properties) {
                captureDate = exifDate
                dateSource = .exif
            }
            gps = Self.extractEXIFGPS(from: properties)
            if Self.hasScreenshotEXIFMarker(in: properties) {
                isScreenshot = true
            }
        } else if isVideo {
            let qt = await Self.extractQuickTimeMetadata(from: url)
            if let qtDate = qt.date {
                captureDate = qtDate
                dateSource = .quickTime
            }
            gps = qt.gps
        }

        if captureDate == nil, let filenameDate = Self.extractDateFromFilename(url.lastPathComponent) {
            captureDate = filenameDate
            dateSource = .filenameRegex
        }

        if captureDate == nil {
            captureDate = resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? Date()
            dateSource = .fileSystem
        }

        return ExtractedMetadata(
            captureDate: captureDate ?? Date(),
            dateSource: dateSource,
            gps: gps,
            isScreenshot: isScreenshot,
            fileSize: fileSize,
            sha256Hash: hash
        )
    }

    // MARK: - Live Photo Content Identifier

    /// Extracts Apple's Live Photo `ContentIdentifier` UUID from an image's MakerApple dictionary or `.mov` QuickTime metadata.
    public static func extractLivePhotoContentID(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        if MediaScanner.videoExtensions.contains(ext) {
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.metadata) else { return nil }
            for item in metadata {
                if item.identifier == .quickTimeMetadataContentIdentifier,
                   let value = try? await item.load(.stringValue),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let properties = readImageProperties(from: url),
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              let contentID = makerApple["17"] as? String,
              !contentID.isEmpty else {
            return nil
        }
        return contentID
    }

    // MARK: - ImageIO EXIF & GPS

    private static func readImageProperties(from url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }

    private static func extractEXIFDate(from properties: [String: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String,
            tiff?[kCGImagePropertyTIFFDateTime as String] as? String
        ]

        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
            ?? exif?[kCGImagePropertyExifOffsetTime as String] as? String

        for raw in candidates.compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let offset, !offset.isEmpty, !trimmed.contains("+"), !trimmed.hasSuffix("Z") {
                if let parsed = exifDateFormatters[3].date(from: "\(trimmed)\(offset)") {
                    return parsed
                }
            }
            for formatter in exifDateFormatters {
                if let parsed = formatter.date(from: trimmed) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func extractEXIFGPS(from properties: [String: Any]) -> GPSCoordinate? {
        guard let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let rawLat = numericDouble(gpsDict[kCGImagePropertyGPSLatitude as String]),
              let rawLon = numericDouble(gpsDict[kCGImagePropertyGPSLongitude as String]) else {
            return nil
        }

        let latRef = (gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() ?? "N"
        let lonRef = (gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() ?? "E"

        let lat = (latRef == "S" && rawLat > 0) ? -rawLat : rawLat
        let lon = (lonRef == "W" && rawLon > 0) ? -rawLon : rawLon

        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon), !(lat == 0 && lon == 0) else {
            return nil
        }
        return GPSCoordinate(latitude: lat, longitude: lon)
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Screenshot Detection

    private static func isScreenshotFilename(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasPrefix("screenshot")
            || lower.hasPrefix("screen shot")
            || lower.hasPrefix("bildschirmfoto")
            || lower.contains("_screenshot")
    }

    private static func hasScreenshotEXIFMarker(in properties: [String: Any]) -> Bool {
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let userComment = exif[kCGImagePropertyExifUserComment as String] as? String,
           userComment.localizedCaseInsensitiveContains("screenshot") {
            return true
        }
        if let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            for key in [kCGImagePropertyPNGTitle as String, kCGImagePropertyPNGDescription as String, kCGImagePropertyPNGSoftware as String] {
                if let val = png[key] as? String, val.localizedCaseInsensitiveContains("screenshot") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - QuickTime Video Metadata

    private static func extractQuickTimeMetadata(from url: URL) async -> (date: Date?, gps: GPSCoordinate?) {
        let asset = AVURLAsset(url: url)
        var parsedDate: Date?
        var parsedGPS: GPSCoordinate?

        if let creationItem = try? await asset.load(.creationDate) {
            parsedDate = try? await creationItem.load(.dateValue)
        }

        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                if parsedDate == nil, item.commonKey == .commonKeyCreationDate {
                    if let d = try? await item.load(.dateValue) {
                        parsedDate = d
                    } else if let str = try? await item.load(.stringValue) {
                        parsedDate = ISO8601DateFormatter().date(from: str)
                    }
                }
                if parsedGPS == nil, item.commonKey == .commonKeyLocation {
                    if let locStr = try? await item.load(.stringValue) {
                        parsedGPS = parseISO6709(locStr)
                    }
                }
            }
        }

        return (parsedDate, parsedGPS)
    }

    /// Parses QuickTime ISO 6709 coordinate strings like `+35.0037+135.7786+050.00/`.
    public static func parseISO6709(_ raw: String) -> GPSCoordinate? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let latRange = Range(match.range(at: 1), in: raw),
              let lonRange = Range(match.range(at: 2), in: raw),
              let lat = Double(raw[latRange]),
              let lon = Double(raw[lonRange]) else {
            return nil
        }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        return GPSCoordinate(latitude: lat, longitude: lon)
    }

    // MARK: - Filename Date Regex Cascade

    /// Parses capture timestamps from common camera, messaging, and macOS screenshot filenames.
    public static func extractDateFromFilename(_ filename: String) -> Date? {
        let patterns: [(regex: String, hasTime: Bool)] = [
            // IMG_20250412_123045, VID_20250412_123045, PXL_20250412_123045123
            (#"(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})"#, true),
            // 2025-04-12 12.30.45 or Screenshot 2025-04-12 at 10.15.00
            (#"(\d{4})[-_.](\d{2})[-_.](\d{2})(?:\s+at\s+|\s+|[_T-])(\d{2})[.:-](\d{2})[.:-](\d{2})"#, true),
            // IMG-20250412-WA0001 or 2025-04-12
            (#"(?<!\d)(\d{4})[-_]?(\d{2})[-_]?(\d{2})(?!\d)"#, false)
        ]

        let nsRange = NSRange(filename.startIndex..., in: filename)
        for (pattern, hasTime) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: filename, range: nsRange) else {
                continue
            }

            func intGroup(_ idx: Int) -> Int? {
                guard idx < match.numberOfRanges,
                      let range = Range(match.range(at: idx), in: filename) else { return nil }
                return Int(filename[range])
            }

            guard let year = intGroup(1), (1990...2100).contains(year),
                  let month = intGroup(2), (1...12).contains(month),
                  let day = intGroup(3), (1...31).contains(day) else {
                continue
            }

            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            if hasTime {
                let hour = intGroup(4) ?? 12
                let minute = intGroup(5) ?? 0
                let second = intGroup(6) ?? 0
                guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
                    continue
                }
                components.hour = hour
                components.minute = minute
                components.second = second
            } else {
                components.hour = 12
                components.minute = 0
                components.second = 0
            }

            if let date = Calendar.current.date(from: components) {
                return date
            }
        }
        return nil
    }

    // MARK: - Streaming SHA256

    /// Computes a streaming SHA256 hex digest using 1 MB chunks to minimize memory footprint.
    public static func computeSHA256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_048_576
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
