import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import Vision

/// Result of running Apple Vision on-device analysis on a photo or bounded video keyframes.
public struct VisionAnalysisResult: Sendable {
    public var isReceipt: Bool
    public var isFood: Bool
    public var isPet: Bool
    public var faces: [DetectedFace]

    public init(
        isReceipt: Bool = false,
        isFood: Bool = false,
        isPet: Bool = false,
        faces: [DetectedFace] = []
    ) {
        self.isReceipt = isReceipt
        self.isFood = isFood
        self.isPet = isPet
        self.faces = faces
    }
}

/// Unified Apple Vision + Neural Engine analyzer for scenes, food, pets, gated OCR receipts, and faces.
public struct VisionAnalyzer: Sendable {
    private static let foodKeywords: Set<String> = [
        "food", "dish", "meal", "cuisine", "dessert", "beverage", "drink",
        "tableware", "menu", "restaurant", "coffee", "sushi", "ramen", "noodle",
        "bread", "meat", "vegetable", "fruit", "cake", "wine", "beer", "cocktail",
        "salad", "soup", "pasta", "steak", "seafood", "breakfast", "pizza", "burger"
    ]

    private static let petKeywords: Set<String> = [
        "pet", "canine", "feline", "dog", "cat", "puppy", "kitten",
        "bird", "rabbit", "hamster", "parakeet", "parrot"
    ]

    private let receiptDetector = ReceiptDetector()
    private let faceEmbedder = FaceEmbedder()

    public init() {}

    /// Runs Vision analysis on an item. Live Photo pairs analyze only the still image and inherit for `.mov`.
    public func analyze(url: URL, mediaKind: MediaKind) async -> VisionAnalysisResult {
        switch mediaKind {
        case .photo, .livePhotoPair:
            guard let cgImage = Self.loadDownsampledImage(from: url, maxPixelSize: 1024) else {
                return VisionAnalysisResult()
            }
            return analyzeCGImage(cgImage)

        case .video:
            let keyframes = await Self.extractVideoKeyframes(from: url, maxDimension: 1024)
            guard !keyframes.isEmpty else { return VisionAnalysisResult() }

            var aggregated = VisionAnalysisResult()
            for frame in keyframes {
                let frameResult = analyzeCGImage(frame)
                aggregated.isReceipt = aggregated.isReceipt || frameResult.isReceipt
                aggregated.isFood = aggregated.isFood || frameResult.isFood
                aggregated.isPet = aggregated.isPet || frameResult.isPet
                if aggregated.faces.isEmpty && !frameResult.faces.isEmpty {
                    aggregated.faces.append(contentsOf: frameResult.faces)
                }
            }
            return aggregated
        }
    }

    /// Runs the unified single-handler Stage 1 pass + Stage 2 gated OCR on a single `CGImage`.
    public func analyzeCGImage(_ cgImage: CGImage) -> VisionAnalysisResult {
        let classifyRequest = VNClassifyImageRequest()
        let animalRequest = VNRecognizeAnimalsRequest()
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([classifyRequest, animalRequest, faceLandmarksRequest])
        } catch {
            return VisionAnalysisResult()
        }

        var classifications: [String: Float] = [:]
        for obs in classifyRequest.results ?? [] {
            classifications[obs.identifier.lowercased()] = obs.confidence
        }

        let isFood = Self.matchesFoodTaxonomy(classifications: classifications, threshold: 0.55)
        let isPetByAnimal = (animalRequest.results ?? []).contains { observation in
            observation.labels.contains { label in
                (label.identifier == "Dog" || label.identifier == "Cat") && label.confidence >= 0.60
            }
        }
        let isPetByScene = Self.matchesKeywords(classifications: classifications, keywords: Self.petKeywords, threshold: 0.60)
        let isPet = isPetByAnimal || isPetByScene

        var isReceipt = false
        if ReceiptDetector.shouldRunOCR(classifications: classifications) {
            isReceipt = receiptDetector.isReceipt(cgImage: cgImage)
        }

        let faceObservations = faceLandmarksRequest.results ?? []
        let faces = faceEmbedder.extractForegroundFaces(from: cgImage, observations: faceObservations)

        return VisionAnalysisResult(
            isReceipt: isReceipt,
            isFood: isFood,
            isPet: isPet,
            faces: faces
        )
    }

    private static func matchesFoodTaxonomy(classifications: [String: Float], threshold: Float) -> Bool {
        matchesKeywords(classifications: classifications, keywords: foodKeywords, threshold: threshold)
    }

    private static func matchesKeywords(
        classifications: [String: Float],
        keywords: Set<String>,
        threshold: Float
    ) -> Bool {
        for (identifier, confidence) in classifications where confidence >= threshold {
            if keywords.contains(where: { identifier.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Loads an orientation-corrected, downsampled `CGImage` via ImageIO for fast Neural Engine execution.
    public static func loadDownsampledImage(from url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Samples up to 3 keyframes (10%, 50%, 90% duration) for standalone videos.
    public static func extractVideoKeyframes(from url: URL, maxDimension: CGFloat) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

        let fractions: [Double] = totalSeconds < 2.0 ? [0.5] : [0.1, 0.5, 0.9]
        var frames: [CGImage] = []
        for fraction in fractions {
            let time = CMTime(seconds: totalSeconds * fraction, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                frames.append(result.image)
            }
        }
        return frames
    }
}
