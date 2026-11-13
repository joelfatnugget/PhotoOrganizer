import Foundation
import CoreGraphics

/// Classifies the container kind of a scanned media entry.
public enum MediaKind: Equatable, Hashable, Sendable, Codable {
    case photo
    case video
    case livePhotoPair(videoURL: URL)
}

/// Primary semantic category used for deterministic folder routing.
public enum PhotoCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case screenshots = "Screenshots"
    case receipts = "Receipts"
    case foodAndRestaurants = "Food & Restaurants"
    case pets = "Pets"
    case people = "People"
    case sceneryAndGeneral = "Scenery & General"

    /// Deterministic priority order (1 = highest, 6 = fallback).
    public var priority: Int {
        switch self {
        case .screenshots: return 1
        case .receipts: return 2
        case .foodAndRestaurants: return 3
        case .pets: return 4
        case .people: return 5
        case .sceneryAndGeneral: return 6
        }
    }

    public var folderName: String { rawValue }
}

/// Source tier that produced a media item's capture timestamp.
public enum DateSource: String, Codable, Sendable {
    case exif
    case quickTime
    case filenameRegex
    case fileSystem
}

/// File operation mode when executing an organization plan.
public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case safeCopyAPFSClone = "Safe Copy (APFS Zero-Space Clone)"
    case inPlaceMove = "In-Place Move"

    public var id: String { rawValue }
}

/// Geographic coordinate with Haversine distance helper.
public struct GPSCoordinate: Equatable, Hashable, Codable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Computes great-circle distance in meters using the Haversine formula.
    public func distanceInMeters(to other: GPSCoordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let dLat = (other.latitude - latitude) * .pi / 180.0
        let dLon = (other.longitude - longitude) * .pi / 180.0

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }
}

/// Reverse-geocoded city, country, and optional neighborhood/sub-locality.
public struct ResolvedLocation: Equatable, Hashable, Codable, Sendable {
    public let city: String
    public let country: String
    public let sublocality: String?

    public init(city: String, country: String, sublocality: String? = nil) {
        self.city = city
        self.country = country
        self.sublocality = sublocality
    }

    public var folderName: String {
        "\(city), \(country)"
    }
}

/// A foreground face detected inside a photo or video keyframe.
public struct DetectedFace: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let boundingBox: CGRect
    public let areaRatio: Double
    public let featurePrintData: Data?
    public let embedding: [Float]?
    public let thumbnailJPEGData: Data?
    public var clusterId: Int?

    public init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        areaRatio: Double,
        featurePrintData: Data? = nil,
        embedding: [Float]? = nil,
        thumbnailJPEGData: Data? = nil,
        clusterId: Int? = nil
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.areaRatio = areaRatio
        self.featurePrintData = featurePrintData
        self.embedding = embedding
        self.thumbnailJPEGData = thumbnailJPEGData
        self.clusterId = clusterId
    }
}

/// A cluster of faces belonging to the same person identity.
public struct FaceCluster: Identifiable, Equatable, Codable, Sendable {
    public let id: Int
    public var customName: String
    public let sampleThumbnailJPEG: Data?
    public let photoIDs: [UUID]

    public init(
        id: Int,
        customName: String = "",
        sampleThumbnailJPEG: Data? = nil,
        photoIDs: [UUID]
    ) {
        self.id = id
        self.customName = customName
        self.sampleThumbnailJPEG = sampleThumbnailJPEG
        self.photoIDs = photoIDs
    }

    public var displayName: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Person \(id + 1)" : trimmed
    }

    public var folderName: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Person \(id + 1)"
        }
        let sanitized = trimmed.replacingOccurrences(of: "/", with: "-")
        return "Person \(id + 1) (\(sanitized))"
    }
}

/// A dining session grouping food photos (and companion meal receipts) by time and micro-GPS.
public struct DiningSession: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public let location: ResolvedLocation?
    public let mealLabel: String
    public let folderName: String
    public let itemIDs: [UUID]

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        location: ResolvedLocation?,
        mealLabel: String,
        folderName: String,
        itemIDs: [UUID]
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.mealLabel = mealLabel
        self.folderName = folderName
        self.itemIDs = itemIDs
    }
}

/// Complete metadata and Vision analysis state for a single media item (or Live Photo pair).
public struct AnalyzedMediaItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let companionVideoURL: URL?
    public let mediaKind: MediaKind
    public let fileSize: Int64
    public let sha256Hash: String
    public var isDuplicate: Bool
    public let captureDate: Date
    public let dateSource: DateSource
    public let rawGPS: GPSCoordinate?
    public var inferredGPS: GPSCoordinate?
    public var resolvedLocation: ResolvedLocation?
    public var isScreenshot: Bool
    public var isReceipt: Bool
    public var isFood: Bool
    public var isPet: Bool
    public var faces: [DetectedFace]
    public var detectedCategories: Set<PhotoCategory>
    public var primaryCategory: PhotoCategory
    public var assignedDiningSessionID: UUID?
    public var assignedFaceClusterIDs: [Int]

    public var effectiveGPS: GPSCoordinate? {
        rawGPS ?? inferredGPS
    }

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        companionVideoURL: URL? = nil,
        mediaKind: MediaKind,
        fileSize: Int64,
        sha256Hash: String,
        isDuplicate: Bool = false,
        captureDate: Date,
        dateSource: DateSource,
        rawGPS: GPSCoordinate? = nil,
        inferredGPS: GPSCoordinate? = nil,
        resolvedLocation: ResolvedLocation? = nil,
        isScreenshot: Bool = false,
        isReceipt: Bool = false,
        isFood: Bool = false,
        isPet: Bool = false,
        faces: [DetectedFace] = [],
        detectedCategories: Set<PhotoCategory> = [],
        primaryCategory: PhotoCategory = .sceneryAndGeneral,
        assignedDiningSessionID: UUID? = nil,
        assignedFaceClusterIDs: [Int] = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.companionVideoURL = companionVideoURL
        self.mediaKind = mediaKind
        self.fileSize = fileSize
        self.sha256Hash = sha256Hash
        self.isDuplicate = isDuplicate
        self.captureDate = captureDate
        self.dateSource = dateSource
        self.rawGPS = rawGPS
        self.inferredGPS = inferredGPS
        self.resolvedLocation = resolvedLocation
        self.isScreenshot = isScreenshot
        self.isReceipt = isReceipt
        self.isFood = isFood
        self.isPet = isPet
        self.faces = faces
        self.detectedCategories = detectedCategories
        self.primaryCategory = primaryCategory
        self.assignedDiningSessionID = assignedDiningSessionID
        self.assignedFaceClusterIDs = assignedFaceClusterIDs
    }
}

/// Configuration options controlling planning and execution.
public struct OrganizationOptions: Equatable, Sendable {
    public var executionMode: ExecutionMode
    public var enableMultiCategoryCrossLinks: Bool
    public var deduplicateExactMatches: Bool
    public var timeZone: TimeZone

    public init(
        executionMode: ExecutionMode = .safeCopyAPFSClone,
        enableMultiCategoryCrossLinks: Bool = true,
        deduplicateExactMatches: Bool = true,
        timeZone: TimeZone = .current
    ) {
        self.executionMode = executionMode
        self.enableMultiCategoryCrossLinks = enableMultiCategoryCrossLinks
        self.deduplicateExactMatches = deduplicateExactMatches
        self.timeZone = timeZone
    }
}

/// A single planned file copy/clone/move operation.
public struct PlannedFileOperation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public let sourceURL: URL
    public let destinationRelativePath: String
    public let destinationURL: URL
    public let isSecondaryCrossLink: Bool
    public let category: PhotoCategory

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        sourceURL: URL,
        destinationRelativePath: String,
        destinationURL: URL,
        isSecondaryCrossLink: Bool = false,
        category: PhotoCategory
    ) {
        self.id = id
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.destinationRelativePath = destinationRelativePath
        self.destinationURL = destinationURL
        self.isSecondaryCrossLink = isSecondaryCrossLink
        self.category = category
    }
}

/// Tree representation of the planned destination folder structure for Dry-Run preview.
public struct FolderTreeNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public var children: [FolderTreeNode]
    public var files: [String]
    public var totalFileCount: Int

    public var optionalChildren: [FolderTreeNode]? {
        children.isEmpty ? nil : children
    }

    public init(
        id: String,
        name: String,
        relativePath: String,
        children: [FolderTreeNode] = [],
        files: [String] = [],
        totalFileCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.children = children
        self.files = files
        self.totalFileCount = totalFileCount
    }
}

/// Full dry-run organization plan produced prior to touching files on disk.
public struct OrganizationPlan: Equatable, Sendable {
    public let sourceRootURL: URL
    public let destinationRootURL: URL
    public let options: OrganizationOptions
    public let items: [AnalyzedMediaItem]
    public let faceClusters: [FaceCluster]
    public let diningSessions: [DiningSession]
    public let operations: [PlannedFileOperation]
    public let treeRoot: FolderTreeNode

    public init(
        sourceRootURL: URL,
        destinationRootURL: URL,
        options: OrganizationOptions,
        items: [AnalyzedMediaItem],
        faceClusters: [FaceCluster],
        diningSessions: [DiningSession],
        operations: [PlannedFileOperation],
        treeRoot: FolderTreeNode
    ) {
        self.sourceRootURL = sourceRootURL
        self.destinationRootURL = destinationRootURL
        self.options = options
        self.items = items
        self.faceClusters = faceClusters
        self.diningSessions = diningSessions
        self.operations = operations
        self.treeRoot = treeRoot
    }
}

/// Records an individual executed filesystem mutation for 1-click undo.
public struct UndoRecord: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let wasMoved: Bool

    public init(sourcePath: String, destinationPath: String, wasMoved: Bool) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.wasMoved = wasMoved
    }
}

/// Persisted transaction journal stored as `.photo-organizer-journal.json` in the destination root.
public struct UndoJournal: Codable, Equatable, Sendable {
    public static let filename = ".photo-organizer-journal.json"

    public let timestamp: Date
    public let mode: ExecutionMode
    public let destinationRootPath: String
    public let records: [UndoRecord]

    public init(
        timestamp: Date = Date(),
        mode: ExecutionMode,
        destinationRootPath: String,
        records: [UndoRecord]
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.destinationRootPath = destinationRootPath
        self.records = records
    }
}

/// Progress update emitted during the two-stage analysis pipeline.
public struct PipelineProgress: Sendable {
    public enum Stage: String, Sendable {
        case scanning = "Scanning Media & Live Photos"
        case metadata = "Extracting Dates, GPS & Hashes"
        case vision = "Analyzing Receipts, Food, Pets & Faces (ANE)"
        case clustering = "Clustering People & Restaurant Visits"
        case planning = "Building Dry-Run Hierarchy"
    }

    public let stage: Stage
    public let completed: Int
    public let total: Int

    public init(stage: Stage, completed: Int, total: Int) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(completed) / Double(total)))
    }
}
