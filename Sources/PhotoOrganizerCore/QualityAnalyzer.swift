import Foundation
import CoreGraphics
import Vision

/// Evaluates image sharpness, motion blur, and closed-eye blink states.
public struct QualityAnalyzer: Sendable {
    public static let blurThreshold: Double = 0.085
    public static let closedEyeAspectThreshold: CGFloat = 0.14

    public init() {}

    /// Computes normalized Laplacian variance sharpness in `[0, 1]` over the main face or central 60% crop.
    public static func computeSharpness(cgImage: CGImage, focusRectNormalized: CGRect? = nil) -> Double {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW >= 16, imgH >= 16 else { return 0.5 }

        let imageBounds = CGRect(x: 0, y: 0, width: imgW, height: imgH)
        let rawCropRect: CGRect
        if let box = focusRectNormalized {
            rawCropRect = CGRect(
                x: max(0, box.minX * imgW),
                y: max(0, (1.0 - box.maxY) * imgH),
                width: min(imgW, box.width * imgW),
                height: min(imgH, box.height * imgH)
            )
        } else {
            rawCropRect = CGRect(
                x: imgW * 0.2,
                y: imgH * 0.2,
                width: imgW * 0.6,
                height: imgH * 0.6
            )
        }
        let cropRect = rawCropRect.intersection(imageBounds).integral

        let targetImage = (cropRect.width >= 16 && cropRect.height >= 16)
            ? (cgImage.cropping(to: cropRect) ?? cgImage)
            : cgImage

        let dim = 128
        var pixels = [UInt8](repeating: 0, count: dim * dim)
        guard let ctx = CGContext(
            data: &pixels,
            width: dim,
            height: dim,
            bitsPerComponent: 8,
            bytesPerRow: dim,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0.5
        }
        ctx.interpolationQuality = .medium
        ctx.draw(targetImage, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0
        for y in 1..<(dim - 1) {
            for x in 1..<(dim - 1) {
                let c = Double(pixels[y * dim + x]) / 255.0
                let top = Double(pixels[(y - 1) * dim + x]) / 255.0
                let bottom = Double(pixels[(y + 1) * dim + x]) / 255.0
                let left = Double(pixels[y * dim + x - 1]) / 255.0
                let right = Double(pixels[y * dim + x + 1]) / 255.0
                let laplacian = 4.0 * c - top - bottom - left - right
                sum += laplacian
                sumSq += laplacian * laplacian
                count += 1.0
            }
        }

        guard count > 0 else { return 0.5 }
        let mean = sum / count
        let variance = max(0.0, (sumSq / count) - (mean * mean))
        return min(1.0, variance * 100.0)
    }

    /// Estimates whether a face has open eyes using Eye Aspect Ratio (`height / width`) on eye landmarks.
    public static func areEyesOpen(observation: VNFaceObservation) -> Bool {
        guard let landmarks = observation.landmarks else { return true }
        let leftEAR = eyeAspectRatio(landmarks.leftEye)
        let rightEAR = eyeAspectRatio(landmarks.rightEye)

        switch (leftEAR, rightEAR) {
        case let (l?, r?):
            return l >= closedEyeAspectThreshold || r >= closedEyeAspectThreshold
        case let (l?, nil):
            return l >= closedEyeAspectThreshold
        case let (nil, r?):
            return r >= closedEyeAspectThreshold
        default:
            return true
        }
    }

    private static func eyeAspectRatio(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
        guard let points = region?.normalizedPoints, points.count >= 4 else { return nil }
        // Find the major axis between the two farthest landmark points (eye corners) so head tilt doesn't skew EAR.
        var maxDistSq: CGFloat = 0
        var pointA = points[0]
        var pointB = points[1]
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = points[j].x - points[i].x
                let dy = points[j].y - points[i].y
                let dSq = dx * dx + dy * dy
                if dSq > maxDistSq {
                    maxDistSq = dSq
                    pointA = points[i]
                    pointB = points[j]
                }
            }
        }
        let width = sqrt(maxDistSq)
        guard width > 1e-5 else { return nil }

        let nx = -(pointB.y - pointA.y) / width
        let ny = (pointB.x - pointA.x) / width
        var minProj = CGFloat.infinity
        var maxProj = -CGFloat.infinity
        for p in points {
            let proj = p.x * nx + p.y * ny
            minProj = min(minProj, proj)
            maxProj = max(maxProj, proj)
        }
        return (maxProj - minProj) / width
    }
}

/// Groups consecutive burst shots (<= 3.0s) and flags the sharpest open-eye frame as Best Shot.
public struct BurstClusterer: Sendable {
    public let maxBurstGapSeconds: TimeInterval

    public init(maxBurstGapSeconds: TimeInterval = 3.0) {
        self.maxBurstGapSeconds = maxBurstGapSeconds
    }

    /// Computes `qualityScore` across items and tags `burstGroupID`, `isBurstBestShot`, and `isBurstExtra`.
    public func cluster(items: inout [AnalyzedMediaItem]) {
        for idx in items.indices {
            let eyeBonus = items[idx].hasClosedEyes ? 0.0 : 0.3
            items[idx].qualityScore = items[idx].sharpnessScore * 0.7 + eyeBonus
            items[idx].burstGroupID = nil
            items[idx].isBurstBestShot = false
            items[idx].isBurstExtra = false
        }

        let sortedIndices = items.indices
            .filter { !items[$0].isDuplicate && !items[$0].isScreenshot && items[$0].mediaKind != .video }
            .sorted { items[$0].captureDate < items[$1].captureDate }

        guard sortedIndices.count >= 2 else { return }

        var bursts: [[Int]] = []
        var currentBurst: [Int] = [sortedIndices[0]]

        for i in 1..<sortedIndices.count {
            let curIdx = sortedIndices[i]
            let prevIdx = currentBurst[currentBurst.count - 1]
            let deltaT = items[curIdx].captureDate.timeIntervalSince(items[prevIdx].captureDate)

            // Keep solo portraits and multi-person group shots in separate bursts.
            let sameFacePresence = (items[curIdx].faces.isEmpty == items[prevIdx].faces.isEmpty)
                && ((items[curIdx].faces.count > 1) == (items[prevIdx].faces.count > 1))
                && abs(items[curIdx].faces.count - items[prevIdx].faces.count) <= 1
            let sameCategory = (items[curIdx].primaryCategory == items[prevIdx].primaryCategory)

            if deltaT >= 0 && deltaT <= maxBurstGapSeconds && sameFacePresence && sameCategory {
                currentBurst.append(curIdx)
            } else {
                if currentBurst.count >= 2 {
                    bursts.append(currentBurst)
                }
                currentBurst = [curIdx]
            }
        }
        if currentBurst.count >= 2 {
            bursts.append(currentBurst)
        }

        for burst in bursts {
            let burstID = UUID()
            guard let bestIdx = burst.max(by: { items[$0].qualityScore < items[$1].qualityScore }) else {
                continue
            }
            let bestScore = items[bestIdx].qualityScore
            let bestSharpness = items[bestIdx].sharpnessScore

            for idx in burst {
                items[idx].burstGroupID = burstID
                if idx == bestIdx {
                    if !items[bestIdx].isBlurry {
                        items[idx].isBurstBestShot = true
                    }
                } else if items[idx].hasClosedEyes
                    || items[idx].isBlurry
                    || items[idx].qualityScore < bestScore * 0.72
                    || items[idx].sharpnessScore < bestSharpness * 0.80 {
                    items[idx].isBurstExtra = true
                }
            }
        }
    }
}
