import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Foreground face filter, eye-landmark alignment, thumbnail exporter, and Vision FeaturePrint embedder.
public struct FaceEmbedder: Sendable {
    /// Minimum face bounding-box area ratio (2.5% of total image area) to exclude background crowds.
    public static let minimumForegroundAreaRatio: Double = 0.025

    public init() {}

    /// Extracts foreground faces, aligns them via eye landmarks, encodes 128x128 thumbnails, and computes feature prints.
    public func extractForegroundFaces(from cgImage: CGImage, observations: [VNFaceObservation]) -> [DetectedFace] {
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)
        guard imgWidth > 0, imgHeight > 0 else { return [] }

        var detected: [DetectedFace] = []
        for obs in observations {
            let box = obs.boundingBox
            let areaRatio = Double(box.width * box.height)
            guard areaRatio >= Self.minimumForegroundAreaRatio else { continue }

            guard let alignedCrop = cropAndAlignFace(in: cgImage, observation: obs) else {
                continue
            }

            let thumbnailData = encodeJPEG(cgImage: alignedCrop, maxDimension: 128)
            let featureResult = computeFeaturePrint(for: alignedCrop)

            detected.append(
                DetectedFace(
                    boundingBox: box,
                    areaRatio: areaRatio,
                    featurePrintData: featureResult.archivedData,
                    embedding: featureResult.floatVector,
                    thumbnailJPEGData: thumbnailData,
                    clusterId: nil
                )
            )
        }
        return detected
    }

    /// Crops a padded face region and rotates it to level the eye line when landmarks are present.
    private func cropAndAlignFace(in cgImage: CGImage, observation: VNFaceObservation) -> CGImage? {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let box = observation.boundingBox

        // Convert Vision bottom-left normalized rect to CGImage top-left pixel rect with 25% padding.
        let padW = box.width * 0.25
        let padH = box.height * 0.25
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

    private func computeFeaturePrint(for cgImage: CGImage) -> (archivedData: Data?, floatVector: [Float]?) {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (nil, nil)
        }

        guard let observation = request.results?.first else {
            return (nil, nil)
        }

        let archived = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        var floatVector: [Float]?
        if observation.elementType == .float {
            let count = observation.elementCount
            if observation.data.count >= count * MemoryLayout<Float>.size {
                floatVector = observation.data.withUnsafeBytes { rawBuffer in
                    let typed = rawBuffer.bindMemory(to: Float.self)
                    return Array(typed.prefix(count))
                }
            }
        }
        return (archived, floatVector)
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
