import Foundation

/// Represents a discovered media unit prior to metadata/AI inspection.
public struct ScannedMediaEntry: Equatable, Sendable {
    public let primaryURL: URL
    public let companionVideoURL: URL?
    public let mediaKind: MediaKind

    public init(primaryURL: URL, companionVideoURL: URL? = nil, mediaKind: MediaKind) {
        self.primaryURL = primaryURL
        self.companionVideoURL = companionVideoURL
        self.mediaKind = mediaKind
    }
}

/// Discovers supported photos and videos recursively and pairs Apple Live Photo (.HEIC/.JPG + .MOV) companions.
public struct MediaScanner: Sendable {
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "webp",
        "raw", "dng", "cr2", "nef", "arw", "tiff", "tif"
    ]

    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v"
    ]

    private static let ignoredDirectoryNames: Set<String> = [
        "_Duplicates", ".git", ".Trash"
    ]

    public init() {}

    /// Scans `rootURL` recursively and pairs Live Photo still+video companions.
    public func scan(rootURL: URL) async throws -> [ScannedMediaEntry] {
        let collected = collectMediaFiles(under: rootURL)
        return await pairLivePhotos(photos: collected.photos, videos: collected.videos)
    }

    private func collectMediaFiles(under rootURL: URL) -> (photos: [URL], videos: [URL]) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], [])
        }

        var photos: [URL] = []
        var videos: [URL] = []

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            let name = values?.name ?? fileURL.lastPathComponent

            if values?.isDirectory == true {
                if Self.ignoredDirectoryNames.contains(name) || name.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            if name == UndoJournal.filename || name.hasPrefix(".") { continue }

            let ext = fileURL.pathExtension.lowercased()
            if Self.photoExtensions.contains(ext) {
                photos.append(fileURL)
            } else if Self.videoExtensions.contains(ext) {
                videos.append(fileURL)
            }
        }

        return (photos, videos)
    }

    private func pairLivePhotos(photos: [URL], videos: [URL]) async -> [ScannedMediaEntry] {
        let remainingVideos = videos
        var pairedVideoIndices = Set<Int>()
        var entries: [ScannedMediaEntry] = []

        // Index videos by (parentDirectory, lowercaseStem) for O(1) Live Photo matching.
        var videosByFolderAndStem: [String: [Int]] = [:]
        var videosByContentID: [String: Int] = [:]

        for (index, videoURL) in remainingVideos.enumerated() {
            guard videoURL.pathExtension.lowercased() == "mov" else { continue }
            let dir = videoURL.deletingLastPathComponent().standardizedFileURL.path
            let stem = videoURL.deletingPathExtension().lastPathComponent.lowercased()
            let key = "\(dir)|\(stem)"
            videosByFolderAndStem[key, default: []].append(index)

            if let contentID = await MetadataExtractor.extractLivePhotoContentID(from: videoURL) {
                videosByContentID[contentID] = index
            }
        }

        let liveStillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]

        for photoURL in photos.sorted(by: { $0.path < $1.path }) {
            let ext = photoURL.pathExtension.lowercased()
            var matchedVideoIndex: Int?

            if liveStillExtensions.contains(ext) {
                let dir = photoURL.deletingLastPathComponent().standardizedFileURL.path
                let stem = photoURL.deletingPathExtension().lastPathComponent.lowercased()
                let key = "\(dir)|\(stem)"

                if let candidates = videosByFolderAndStem[key] {
                    matchedVideoIndex = candidates.first { !pairedVideoIndices.contains($0) }
                }

                if matchedVideoIndex == nil,
                   let photoContentID = await MetadataExtractor.extractLivePhotoContentID(from: photoURL),
                   let candidateIndex = videosByContentID[photoContentID],
                   !pairedVideoIndices.contains(candidateIndex) {
                    matchedVideoIndex = candidateIndex
                }
            }

            if let videoIdx = matchedVideoIndex {
                pairedVideoIndices.insert(videoIdx)
                let companionURL = remainingVideos[videoIdx]
                entries.append(
                    ScannedMediaEntry(
                        primaryURL: photoURL,
                        companionVideoURL: companionURL,
                        mediaKind: .livePhotoPair(videoURL: companionURL)
                    )
                )
            } else {
                entries.append(
                    ScannedMediaEntry(
                        primaryURL: photoURL,
                        companionVideoURL: nil,
                        mediaKind: .photo
                    )
                )
            }
        }

        // Remaining unpaired videos are standalone video entries.
        for (index, videoURL) in remainingVideos.enumerated() where !pairedVideoIndices.contains(index) {
            entries.append(
                ScannedMediaEntry(
                    primaryURL: videoURL,
                    companionVideoURL: nil,
                    mediaKind: .video
                )
            )
        }

        return entries.sorted { $0.primaryURL.path < $1.primaryURL.path }
    }
}
