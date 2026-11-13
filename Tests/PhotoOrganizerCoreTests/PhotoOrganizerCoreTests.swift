import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoOrganizerCore

final class PhotoOrganizerCoreTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PhotoOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    private func makeDate(
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int, second: Int = 0,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    private func writeTestJPEG(
        to url: URL,
        width: Int = 128,
        height: Int = 128,
        exifDateString: String? = nil,
        gps: GPSCoordinate? = nil,
        seedColor: (CGFloat, CGFloat, CGFloat) = (0.2, 0.5, 0.8)
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create CGContext")
            return
        }
        ctx.setFillColor(red: seedColor.0, green: seedColor.1, blue: seedColor.2, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            XCTFail("Could not make CGImage")
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Could not create CGImageDestination")
            return
        }

        var properties: [CFString: Any] = [:]
        if let exifDateString {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: exifDateString,
                kCGImagePropertyExifDateTimeDigitized: exifDateString
            ]
        }
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(gps.latitude),
                kCGImagePropertyGPSLatitudeRef: gps.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(gps.longitude),
                kCGImagePropertyGPSLongitudeRef: gps.longitude >= 0 ? "E" : "W"
            ]
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - 1. Date Extraction Cascade & EXIF

    func testFilenameDateRegexCascade() {
        let d1 = MetadataExtractor.extractDateFromFilename("IMG_20250412_123045.JPG")
        XCTAssertNotNil(d1)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.year, from: d1!), 2025)
        XCTAssertEqual(cal.component(.month, from: d1!), 4)
        XCTAssertEqual(cal.component(.day, from: d1!), 12)
        XCTAssertEqual(cal.component(.hour, from: d1!), 12)
        XCTAssertEqual(cal.component(.minute, from: d1!), 30)

        let d2 = MetadataExtractor.extractDateFromFilename("IMG-20250412-WA0001.jpg")
        XCTAssertNotNil(d2)
        XCTAssertEqual(cal.component(.year, from: d2!), 2025)
        XCTAssertEqual(cal.component(.month, from: d2!), 4)
        XCTAssertEqual(cal.component(.day, from: d2!), 12)

        let d3 = MetadataExtractor.extractDateFromFilename("Screenshot 2025-04-12 at 10.15.00.png")
        XCTAssertNotNil(d3)
        XCTAssertEqual(cal.component(.hour, from: d3!), 10)
        XCTAssertEqual(cal.component(.minute, from: d3!), 15)
    }

    func testEXIFDateAndGPSExtraction() async throws {
        let dir = try makeTempDirectory()
        let photoURL = dir.appendingPathComponent("kyoto_shot.jpg")
        try writeTestJPEG(
            to: photoURL,
            exifDateString: "2025:04:12 12:30:00",
            gps: GPSCoordinate(latitude: 35.0037, longitude: 135.7786)
        )

        let extractor = MetadataExtractor()
        let entry = ScannedMediaEntry(primaryURL: photoURL, mediaKind: .photo)
        let meta = await extractor.extract(entry: entry)

        XCTAssertEqual(meta.dateSource, .exif)
        XCTAssertNotNil(meta.gps)
        XCTAssertEqual(meta.gps!.latitude, 35.0037, accuracy: 0.001)
        XCTAssertEqual(meta.gps!.longitude, 135.7786, accuracy: 0.001)
        XCTAssertFalse(meta.sha256Hash.isEmpty)
        XCTAssertFalse(meta.isScreenshot)
    }

    // MARK: - 2. Offline Reverse Geocoding & Indoor GPS Gap-Fill

    func testOfflineGeocoderAndIndoorGapFilling() {
        let geocoder = OfflineGeocoder()

        let gion = geocoder.resolve(coordinate: GPSCoordinate(latitude: 35.0037, longitude: 135.7786))
        XCTAssertEqual(gion?.city, "Kyoto")
        XCTAssertEqual(gion?.country, "Japan")
        XCTAssertEqual(gion?.sublocality, "Gion")
        XCTAssertEqual(gion?.folderName, "Kyoto, Japan")

        let dotonbori = geocoder.resolve(coordinate: GPSCoordinate(latitude: 34.6687, longitude: 135.5013))
        XCTAssertEqual(dotonbori?.city, "Osaka")
        XCTAssertEqual(dotonbori?.sublocality, "Dotonbori")

        let singapore = geocoder.resolve(coordinate: GPSCoordinate(latitude: 1.3521, longitude: 103.8198))
        XCTAssertEqual(singapore?.city, "Singapore")
        XCTAssertNil(singapore?.sublocality) // City center should not duplicate city name as sublocality.

        let tz = TimeZone(secondsFromGMT: 9 * 3600)!
        var items = [
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/outside.jpg"),
                mediaKind: .photo,
                fileSize: 100,
                sha256Hash: "h1",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 12, minute: 0, timeZone: tz),
                dateSource: .exif,
                rawGPS: GPSCoordinate(latitude: 35.0037, longitude: 135.7786)
            ),
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/indoor_within_2h.jpg"),
                mediaKind: .photo,
                fileSize: 100,
                sha256Hash: "h2",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 12, minute: 45, timeZone: tz),
                dateSource: .exif,
                rawGPS: nil
            ),
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/later_outside_window.jpg"),
                mediaKind: .photo,
                fileSize: 100,
                sha256Hash: "h3",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 16, minute: 30, timeZone: tz),
                dateSource: .exif,
                rawGPS: nil
            )
        ]

        geocoder.inferMissingGPS(for: &items)
        geocoder.resolveLocations(for: &items)

        XCTAssertEqual(items[1].resolvedLocation?.city, "Kyoto")
        XCTAssertEqual(items[1].resolvedLocation?.sublocality, "Gion")
        XCTAssertNil(items[2].effectiveGPS)
        XCTAssertNil(items[2].resolvedLocation)
    }

    // MARK: - 3. Spatiotemporal Restaurant Session Clustering

    func testRestaurantSessionClusteringAcrossMixedCuisines() {
        let tz = TimeZone(secondsFromGMT: 9 * 3600)!
        let gionLoc = ResolvedLocation(city: "Kyoto", country: "Japan", sublocality: "Gion")
        let dotonboriLoc = ResolvedLocation(city: "Osaka", country: "Japan", sublocality: "Dotonbori")

        var items = [
            // Lunch in Gion (2 food items + 1 indoor missing-GPS food + 1 receipt)
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/sushi.jpg"),
                mediaKind: .photo, fileSize: 100, sha256Hash: "f1",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 12, minute: 10, timeZone: tz),
                dateSource: .exif,
                rawGPS: GPSCoordinate(latitude: 35.0037, longitude: 135.7786),
                resolvedLocation: gionLoc,
                isFood: true
            ),
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/steak_indoor.jpg"),
                mediaKind: .photo, fileSize: 100, sha256Hash: "f2",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 12, minute: 25, timeZone: tz),
                dateSource: .exif,
                rawGPS: nil,
                resolvedLocation: gionLoc,
                isFood: true
            ),
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/lunch_receipt.jpg"),
                mediaKind: .photo, fileSize: 100, sha256Hash: "r1",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 12, minute: 40, timeZone: tz),
                dateSource: .exif,
                rawGPS: GPSCoordinate(latitude: 35.0037, longitude: 135.7786),
                resolvedLocation: gionLoc,
                isReceipt: true
            ),
            // Dinner in Dotonbori (same day, evening)
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/takoyaki.jpg"),
                mediaKind: .photo, fileSize: 100, sha256Hash: "f3",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 19, minute: 15, timeZone: tz),
                dateSource: .exif,
                rawGPS: GPSCoordinate(latitude: 34.6687, longitude: 135.5013),
                resolvedLocation: dotonboriLoc,
                isFood: true
            ),
            // Second dinner visit in Dotonbori (> 100m away) within dinner hours -> Visit 2
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/ramen.jpg"),
                mediaKind: .photo, fileSize: 100, sha256Hash: "f4",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 20, minute: 00, timeZone: tz),
                dateSource: .exif,
                rawGPS: GPSCoordinate(latitude: 34.6710, longitude: 135.5050),
                resolvedLocation: dotonboriLoc,
                isFood: true
            )
        ]

        let clusterer = DiningSessionClusterer()
        let sessions = clusterer.cluster(items: &items, timeZone: tz)

        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].folderName, "2025-04-12 Lunch (Gion)")
        XCTAssertEqual(sessions[0].itemIDs.count, 3) // sushi + indoor steak + receipt
        XCTAssertEqual(sessions[1].folderName, "2025-04-12 Dinner (Dotonbori) - Visit 1")
        XCTAssertEqual(sessions[2].folderName, "2025-04-12 Dinner (Dotonbori) - Visit 2")
        XCTAssertEqual(items[2].assignedDiningSessionID, sessions[0].id)
    }

    // MARK: - 4. Receipt OCR Heuristics

    func testReceiptHeuristicsDistinguishReceiptsFromStreetSigns() {
        XCTAssertTrue(ReceiptDetector.shouldRunOCR(classifications: ["document": 0.42, "sky": 0.1]))
        XCTAssertFalse(ReceiptDetector.shouldRunOCR(classifications: ["landscape": 0.85, "mountain": 0.7]))

        let receiptLines = [
            "GION RAMEN HOUSE",
            "QTY 2 TONKOTSU RAMEN    $24.00",
            "SUBTOTAL                $24.00",
            "GST 9%                   $2.16",
            "TOTAL                   $26.16",
            "VISA **** 4242"
        ]
        XCTAssertTrue(ReceiptDetector.isReceiptText(lines: receiptLines))

        let streetSignLines = [
            "GION SHIJIO STATION",
            "EXIT 6 ->",
            "KYOTO CITY"
        ]
        XCTAssertFalse(ReceiptDetector.isReceiptText(lines: streetSignLines))
    }

    // MARK: - 5. Face DBSCAN Clustering, Live Photo Pairing & Renaming

    func testLivePhotoPairingAndFaceDBSCANRenaming() async throws {
        let dir = try makeTempDirectory()
        let heicURL = dir.appendingPathComponent("IMG_1001.HEIC")
        let movURL = dir.appendingPathComponent("IMG_1001.MOV")
        let standaloneMov = dir.appendingPathComponent("VID_1005.MOV")

        try Data("fake-heic".utf8).write(to: heicURL)
        try Data("fake-live-mov".utf8).write(to: movURL)
        try Data("fake-standalone-mov".utf8).write(to: standaloneMov)

        let scanner = MediaScanner()
        let entries = try await scanner.scan(rootURL: dir)
        XCTAssertEqual(entries.count, 2)

        let liveEntry = entries.first { $0.primaryURL.lastPathComponent == "IMG_1001.HEIC" }
        if case .livePhotoPair(let pairedVideoURL) = liveEntry?.mediaKind {
            XCTAssertEqual(pairedVideoURL.lastPathComponent, "IMG_1001.MOV")
            XCTAssertTrue(FileManager.default.contentsEqual(atPath: pairedVideoURL.path, andPath: movURL.path))
        } else {
            XCTFail("Expected livePhotoPair for IMG_1001.HEIC, got \(String(describing: liveEntry?.mediaKind))")
        }

        let tz = TimeZone(secondsFromGMT: 9 * 3600)!
        let sarahVecA: [Float] = [1, 0, 0, 0]
        let sarahVecB: [Float] = [0.98, 0.1, 0, 0]
        let johnVecA: [Float] = [0, 1, 0, 0]
        let johnVecB: [Float] = [0.05, 0.99, 0, 0]
        let strangerVec: [Float] = [0, 0, 1, 0]

        var items = [
            AnalyzedMediaItem(
                sourceURL: heicURL, companionVideoURL: movURL, mediaKind: .livePhotoPair(videoURL: movURL),
                fileSize: 10, sha256Hash: "a1",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 10, minute: 0, timeZone: tz),
                dateSource: .exif,
                faces: [DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), areaRatio: 0.09, embedding: sarahVecA)]
            ),
            AnalyzedMediaItem(
                sourceURL: dir.appendingPathComponent("IMG_1002.JPG"), mediaKind: .photo,
                fileSize: 10, sha256Hash: "a2",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 10, minute: 5, timeZone: tz),
                dateSource: .exif,
                faces: [DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), areaRatio: 0.09, embedding: sarahVecB)]
            ),
            AnalyzedMediaItem(
                sourceURL: dir.appendingPathComponent("IMG_1003.JPG"), mediaKind: .photo,
                fileSize: 10, sha256Hash: "a3",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 10, minute: 10, timeZone: tz),
                dateSource: .exif,
                faces: [
                    DetectedFace(boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.25), areaRatio: 0.0625, embedding: johnVecA),
                    DetectedFace(boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.25, height: 0.25), areaRatio: 0.0625, embedding: sarahVecA)
                ]
            ),
            AnalyzedMediaItem(
                sourceURL: dir.appendingPathComponent("IMG_1004.JPG"), mediaKind: .photo,
                fileSize: 10, sha256Hash: "a4",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 10, minute: 15, timeZone: tz),
                dateSource: .exif,
                faces: [DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), areaRatio: 0.09, embedding: johnVecB)]
            ),
            AnalyzedMediaItem(
                sourceURL: dir.appendingPathComponent("IMG_1005.JPG"), mediaKind: .photo,
                fileSize: 10, sha256Hash: "a5",
                captureDate: makeDate(year: 2025, month: 4, day: 12, hour: 10, minute: 20, timeZone: tz),
                dateSource: .exif,
                faces: [DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), areaRatio: 0.09, embedding: strangerVec)]
            )
        ]

        let faceClusterer = FaceDBSCANClusterer()
        var clusters = faceClusterer.cluster(items: &items)
        XCTAssertEqual(clusters.count, 2)

        // Rename cluster 0 to Sarah and rebuild plan.
        clusters[0].customName = "Sarah"
        let planner = OrganizationPlanner()
        let outDir = dir.appendingPathComponent("Organized", isDirectory: true)
        let plan = planner.buildPlan(
            sourceRootURL: dir,
            destinationRootURL: outDir,
            items: items,
            faceClusters: clusters,
            diningSessions: [],
            options: OrganizationOptions(timeZone: tz)
        )

        let paths = plan.operations.map(\.destinationRelativePath)
        XCTAssertTrue(paths.contains("2025/04 - April/Unknown Location/People/Person 1 (Sarah)/IMG_1001.HEIC"))
        XCTAssertTrue(paths.contains("2025/04 - April/Unknown Location/People/Person 1 (Sarah)/IMG_1001.MOV"))
        XCTAssertTrue(paths.contains("2025/04 - April/Unknown Location/People/Group Photos/IMG_1003.JPG"))
        XCTAssertTrue(paths.contains("2025/04 - April/Unknown Location/People/Other People/IMG_1005.JPG"))
    }

    func testSamePhotoCannotLinkAndMultiFaceGroupRouting() {
        let tz = TimeZone(secondsFromGMT: 8 * 3600)!
        let sharedVec: [Float] = [1, 0, 0, 0]

        var items = [
            // Single photo with two faces (same-photo cannot-link must prevent both faces joining the same cluster)
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/duo.jpg"), mediaKind: .photo,
                fileSize: 10, sha256Hash: "d1",
                captureDate: makeDate(year: 2025, month: 7, day: 1, hour: 12, minute: 0, timeZone: tz),
                dateSource: .exif,
                faces: [
                    DetectedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), areaRatio: 0.04, embedding: sharedVec),
                    DetectedFace(boundingBox: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2), areaRatio: 0.04, embedding: sharedVec)
                ]
            ),
            AnalyzedMediaItem(
                sourceURL: URL(fileURLWithPath: "/tmp/solo.jpg"), mediaKind: .photo,
                fileSize: 10, sha256Hash: "d2",
                captureDate: makeDate(year: 2025, month: 7, day: 1, hour: 12, minute: 5, timeZone: tz),
                dateSource: .exif,
                faces: [
                    DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), areaRatio: 0.04, embedding: sharedVec)
                ]
            )
        ]

        let clusterer = FaceDBSCANClusterer()
        let clusters = clusterer.cluster(items: &items)

        // Only 1 cluster can be formed (face 0 of duo + solo), never both faces of duo.jpg.
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(items[0].assignedFaceClusterIDs.count, 1)

        // Even though duo.jpg only has 1 assigned cluster ID, item.faces.count == 2 must route it to Group Photos.
        let planner = OrganizationPlanner()
        let plan = planner.buildPlan(
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            destinationRootURL: URL(fileURLWithPath: "/tmp/out"),
            items: items,
            faceClusters: clusters,
            diningSessions: [],
            options: OrganizationOptions(timeZone: tz)
        )
        let paths = plan.operations.map(\.destinationRelativePath)
        XCTAssertTrue(paths.contains("2025/07 - July/Unknown Location/People/Group Photos/duo.jpg"))
        XCTAssertTrue(paths.contains("2025/07 - July/Unknown Location/People/Person 1/solo.jpg"))
    }

    // MARK: - 6. End-to-End Pipeline, APFS COPYFILE_CLONE, Move & 1-Click Undo

    func testEndToEndOrganizationAndUndoRoundTrip() async throws {
        let rootDir = try makeTempDirectory()
        let sourceDir = rootDir.appendingPathComponent("Messy", isDirectory: true)
        let destCloneDir = rootDir.appendingPathComponent("OrganizedClone", isDirectory: true)
        let destMoveDir = rootDir.appendingPathComponent("OrganizedMove", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let shot1 = sourceDir.appendingPathComponent("IMG_0001.jpg")
        let shot1Duplicate = sourceDir.appendingPathComponent("IMG_0001_copy.jpg")
        let screenshot = sourceDir.appendingPathComponent("Screenshot 2025-04-12 at 10.15.00.png")

        try writeTestJPEG(
            to: shot1,
            exifDateString: "2025:04:12 14:00:00",
            gps: GPSCoordinate(latitude: 35.0116, longitude: 135.7681),
            seedColor: (0.1, 0.7, 0.3)
        )
        try Data(contentsOf: shot1).write(to: shot1Duplicate)
        try writeTestJPEG(
            to: screenshot,
            exifDateString: nil,
            gps: nil,
            seedColor: (0.9, 0.2, 0.2)
        )

        let engine = OrganizationEngine()
        let tz = TimeZone.current

        // Mode 1: Safe Copy (APFS Zero-Space Clone)
        let clonePlan = try await engine.analyzeAndPlan(
            sourceRootURL: sourceDir,
            destinationRootURL: destCloneDir,
            options: OrganizationOptions(executionMode: .safeCopyAPFSClone, timeZone: tz)
        )
        XCTAssertEqual(clonePlan.items.count, 3)

        let cloneJournal = try engine.execute(plan: clonePlan)
        XCTAssertEqual(cloneJournal.records.count, 3)
        XCTAssertTrue(FileExecutor.hasUndoJournal(at: destCloneDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot1.path))

        let expectedShot1 = destCloneDir.appendingPathComponent("2025/04 - April/Kyoto, Japan/Scenery & General/IMG_0001.jpg")
        let expectedDup = destCloneDir.appendingPathComponent("_Duplicates/IMG_0001_copy.jpg")
        let expectedScreen = destCloneDir.appendingPathComponent("2025/04 - April/Unknown Location/Screenshots/Screenshot 2025-04-12 at 10.15.00.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedShot1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedScreen.path))

        // Undo clone organization
        try engine.undo(at: destCloneDir)
        XCTAssertFalse(FileExecutor.hasUndoJournal(at: destCloneDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedShot1.path))

        // Mode 2: In-Place Move + Undo restoration
        let movePlan = try await engine.analyzeAndPlan(
            sourceRootURL: sourceDir,
            destinationRootURL: destMoveDir,
            options: OrganizationOptions(executionMode: .inPlaceMove, timeZone: tz)
        )
        try engine.execute(plan: movePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destMoveDir.appendingPathComponent("2025/04 - April/Kyoto, Japan/Scenery & General/IMG_0001.jpg").path))

        try engine.undo(at: destMoveDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot1Duplicate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
    }
}
