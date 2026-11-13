import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import Vision

private final class MobileFaceNetHolder: @unchecked Sendable {
    static let shared = MobileFaceNetHolder()
    let vnModel: VNCoreMLModel?

    private init() {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc"),
            Bundle.main.resourceURL?.appendingPathComponent("PhotoOrganizer_PhotoOrganizerCore.bundle/MobileFaceNet.mlmodelc"),
            Bundle.module.url(forResource: "MobileFaceNet", withExtension: "mlmodelc")
        ]

        let modelURL = candidates
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        guard let modelURL else {
            self.vnModel = nil
            return
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        if let mlModel = try? MLModel(contentsOf: modelURL, configuration: config),
           let vnModel = try? VNCoreMLModel(for: mlModel) {
            self.vnModel = vnModel
        } else {
            self.vnModel = nil
        }
    }
}

/// Foreground face filter, eye-landmark alignment, thumbnail exporter, and MobileFaceNet CoreML embedder.
public struct FaceEmbedder: Sendable {
    /// Absolute minimum face bounding-box area ratio (0.25% of frame) so waist-up and group faces are retained.
    public static let minimumForegroundAreaRatio: Double = 0.0025

    /// Minimum face area relative to the largest face in the same photo (22%) to ignore distant background bystanders.
    public static let minimumRelativeAreaRatio: Double = 0.22

    public init() {}

    /// Extracts foreground faces, aligns them via eye landmarks, encodes 128x128 thumbnails, and computes embeddings.
    public func extractForegroundFaces(from cgImage: CGImage, observations: [VNFaceObservation]) -> [DetectedFace] {
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)
        guard imgWidth > 0, imgHeight > 0, !observations.isEmpty else { return [] }

        let maxArea = observations
            .map { Double($0.boundingBox.width * $0.boundingBox.height) }
            .max() ?? 0.0

        var detected: [DetectedFace] = []
        for obs in observations {
            let box = obs.boundingBox
            let areaRatio = Double(box.width * box.height)
            guard areaRatio >= Self.minimumForegroundAreaRatio,
                  areaRatio >= maxArea * Self.minimumRelativeAreaRatio else {
                continue
            }

            guard let alignedCrop = cropAndAlignFace(in: cgImage, observation: obs) else {
                continue
            }

            let thumbnailData = encodeJPEG(cgImage: alignedCrop, maxDimension: 128)
            let embedding = computeMobileFaceNetEmbedding(for: alignedCrop)
            let featurePrintData = (embedding == nil) ? computeFallbackFeaturePrint(for: alignedCrop) : nil
            let eyesOpen = QualityAnalyzer.areEyesOpen(observation: obs)

            detected.append(
                DetectedFace(
                    boundingBox: box,
                    areaRatio: areaRatio,
                    featurePrintData: featurePrintData,
                    embedding: embedding,
                    thumbnailJPEGData: thumbnailData,
                    clusterId: nil,
                    eyesOpen: eyesOpen,
                    captureQuality: obs.faceCaptureQuality
                )
            )
        }
        return detected
    }

    /// Crops a tightly padded face region (15% padding) and rotates it to level the eye line when landmarks are present.
    private func cropAndAlignFace(in cgImage: CGImage, observation: VNFaceObservation) -> CGImage? {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let box = observation.boundingBox

        let padW = box.width * 0.15
        let padH = box.height * 0.15
        let normMinX = max(0, box.minX - padW)
        let normMaxX = min(1, box.maxX + padW)
        let normMinY = max(0, box.minY - padH)
        let normMaxY = min(1, box.maxY + padH)

        let cropRect = CGRect(
            x: normMinX * imgW,
            y: (1.0 - normMaxY) * imgH,
            width: (normMaxX - normMinX) * imgW,
            height: (normMaxY - normMinY) * imgH
        ).integral

        guard cropRect.width >= 16, cropRect.height >= 16,
              let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        // Align roll angle using eye centers in normalized landmark space.
        guard let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let leftCenter = averagePoint(leftEye.normalizedPoints),
              let rightCenter = averagePoint(rightEye.normalizedPoints) else {
            return cropped
        }

        let dx = (rightCenter.x - leftCenter.x) * box.width * imgW
        let dy = (rightCenter.y - leftCenter.y) * box.height * imgH
        let angle = atan2(dy, dx)

        // Skip negligible rotations (< 2 degrees) to preserve sharpness.
        if abs(angle) < (2.0 * .pi / 180.0) {
            return cropped
        }

        return rotateCGImage(cropped, byRadians: -angle) ?? cropped
    }

    private func averagePoint(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func rotateCGImage(_ image: CGImage, byRadians radians: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
        context.rotate(by: radians)
        context.translateBy(x: -CGFloat(width) / 2.0, y: -CGFloat(height) / 2.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func computeMobileFaceNetEmbedding(for cgImage: CGImage) -> [Float]? {
        guard let vnModel = MobileFaceNetHolder.shared.vnModel else {
            return nil
        }

        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let multiArray = results.first?.featureValue.multiArrayValue else {
            return nil
        }

        let count = multiArray.count
        guard count > 0 else { return nil }

        var vector = [Float](repeating: 0, count: count)
        var normSq: Float = 0
        for i in 0..<count {
            let v = multiArray[i].floatValue
            vector[i] = v
            normSq += v * v
        }

        let norm = sqrt(normSq)
        guard norm > 1e-8 else { return nil }
        for i in 0..<count {
            vector[i] /= norm
        }
        return vector
    }

    private func computeFallbackFeaturePrint(for cgImage: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else {
            return nil
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    private func encodeJPEG(cgImage: CGImage, maxDimension: CGFloat) -> Data? {
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1.0, maxDimension / max(srcW, srcH))
        let targetW = max(1, Int((srcW * scale).rounded()))
        let targetH = max(1, Int((srcH * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let resized = context.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            resized,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
