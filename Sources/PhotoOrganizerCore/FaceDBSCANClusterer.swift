import Foundation
import Vision

/// Density-based (DBSCAN) identity clusterer with same-photo cannot-link and centroid anti-chaining guards.
public struct FaceDBSCANClusterer: Sendable {
    public let featurePrintEpsilon: Float
    public let cosineEpsilon: Float
    public let centroidMaxDistance: Float
    public let minPoints: Int

    public init(
        featurePrintEpsilon: Float = 0.95,
        cosineEpsilon: Float = 0.24,
        centroidMaxDistance: Float = 0.26,
        minPoints: Int = 2
    ) {
        self.featurePrintEpsilon = featurePrintEpsilon
        self.cosineEpsilon = cosineEpsilon
        self.centroidMaxDistance = centroidMaxDistance
        self.minPoints = minPoints
    }

    /// Clusters all foreground faces across `items` and populates `assignedFaceClusterIDs` and `FaceCluster`s.
    public func cluster(items: inout [AnalyzedMediaItem]) -> [FaceCluster] {
        struct FaceRef {
            let itemIndex: Int
            let faceIndex: Int
            let itemID: UUID
            let face: DetectedFace
            let featurePrint: VNFeaturePrintObservation?
        }

        var refs: [FaceRef] = []
        for itemIdx in items.indices where !items[itemIdx].isDuplicate {
            items[itemIdx].assignedFaceClusterIDs = []
            for faceIdx in items[itemIdx].faces.indices {
                let face = items[itemIdx].faces[faceIdx]
                let fp: VNFeaturePrintObservation?
                if face.embedding == nil, let data = face.featurePrintData {
                    fp = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
                } else {
                    fp = nil
                }
                refs.append(
                    FaceRef(
                        itemIndex: itemIdx,
                        faceIndex: faceIdx,
                        itemID: items[itemIdx].id,
                        face: face,
                        featurePrint: fp
                    )
                )
            }
        }

        guard !refs.isEmpty else { return [] }

        let count = refs.count
        var labels = Array(repeating: -1, count: count) // -1 = unvisited, -2 = noise, >= 0 = cluster id
        var nextClusterID = 0

        func neighbors(of idx: Int) -> [Int] {
            var result: [Int] = []
            let a = refs[idx]
            for j in 0..<count {
                if idx == j {
                    result.append(j)
                    continue
                }
                let b = refs[j]
                // Cannot-link constraint: two faces in the same photo cannot be the same person.
                guard a.itemID != b.itemID else { continue }

                if let embA = a.face.embedding, let embB = b.face.embedding, !embA.isEmpty, embA.count == embB.count {
                    if Self.cosineDistance(embA, embB) <= cosineEpsilon {
                        result.append(j)
                    }
                } else if let fpA = a.featurePrint, let fpB = b.featurePrint {
                    var distance: Float = .infinity
                    if (try? fpA.computeDistance(&distance, to: fpB)) != nil, distance <= featurePrintEpsilon {
                        result.append(j)
                    }
                }
            }
            return result
        }

        for i in 0..<count where labels[i] == -1 {
            let seedNeighbors = neighbors(of: i)
            if seedNeighbors.count < minPoints {
                labels[i] = -2
                continue
            }

            let clusterID = nextClusterID
            nextClusterID += 1
            labels[i] = clusterID

            var usedItemIDs: Set<UUID> = [refs[i].itemID]
            var centroidSum: [Float]? = refs[i].face.embedding
            var centroid = Self.l2Normalize(centroidSum)

            var queue = seedNeighbors.filter { $0 != i }
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1

                guard labels[current] == -1 || labels[current] == -2 else { continue }
                guard !usedItemIDs.contains(refs[current].itemID) else { continue }

                if let curEmb = refs[current].face.embedding, !centroid.isEmpty, curEmb.count == centroid.count {
                    if Self.cosineDistance(centroid, curEmb) > centroidMaxDistance {
                        continue
                    }
                }

                let wasUnvisited = (labels[current] == -1)
                labels[current] = clusterID
                usedItemIDs.insert(refs[current].itemID)

                if let curEmb = refs[current].face.embedding {
                    if var sum = centroidSum, sum.count == curEmb.count {
                        for k in 0..<sum.count { sum[k] += curEmb[k] }
                        centroidSum = sum
                        centroid = Self.l2Normalize(sum)
                    } else {
                        centroidSum = curEmb
                        centroid = Self.l2Normalize(curEmb)
                    }
                }

                if wasUnvisited {
                    let currentNeighbors = neighbors(of: current)
                    if currentNeighbors.count >= minPoints {
                        for n in currentNeighbors where labels[n] == -1 || labels[n] == -2 {
                            if !usedItemIDs.contains(refs[n].itemID) && !queue.contains(n) {
                                queue.append(n)
                            }
                        }
                    }
                }
            }
        }

        // Group refs by raw cluster ID and sort clusters by photo count descending (tie-break by raw ID).
        var rawClusterPhotoIDs: [Int: [UUID]] = [:]
        var rawClusterBestThumb: [Int: (area: Double, data: Data)] = [:]
        for (refIdx, ref) in refs.enumerated() {
            let label = labels[refIdx]
            guard label >= 0 else { continue }
            var ids = rawClusterPhotoIDs[label, default: []]
            if !ids.contains(ref.itemID) {
                ids.append(ref.itemID)
                rawClusterPhotoIDs[label] = ids
            }
            if let thumb = ref.face.thumbnailJPEGData {
                let existingArea = rawClusterBestThumb[label]?.area ?? -1
                if ref.face.areaRatio > existingArea {
                    rawClusterBestThumb[label] = (ref.face.areaRatio, thumb)
                }
            }
        }

        let sortedRawIDs = rawClusterPhotoIDs.keys
            .filter { (rawClusterPhotoIDs[$0]?.count ?? 0) >= minPoints }
            .sorted { lhs, rhs in
                let lCount = rawClusterPhotoIDs[lhs]?.count ?? 0
                let rCount = rawClusterPhotoIDs[rhs]?.count ?? 0
                if lCount != rCount { return lCount > rCount }
                return lhs < rhs
            }

        var rawToSortedID: [Int: Int] = [:]
        for (newID, oldID) in sortedRawIDs.enumerated() {
            rawToSortedID[oldID] = newID
        }

        for (refIdx, ref) in refs.enumerated() {
            let rawLabel = labels[refIdx]
            guard rawLabel >= 0, let mappedID = rawToSortedID[rawLabel] else {
                items[ref.itemIndex].faces[ref.faceIndex].clusterId = nil
                continue
            }

            items[ref.itemIndex].faces[ref.faceIndex].clusterId = mappedID
            if !items[ref.itemIndex].assignedFaceClusterIDs.contains(mappedID) {
                items[ref.itemIndex].assignedFaceClusterIDs.append(mappedID)
            }
        }

        return sortedRawIDs.enumerated().map { newID, oldID in
            FaceCluster(
                id: newID,
                customName: "",
                sampleThumbnailJPEG: rawClusterBestThumb[oldID]?.data,
                photoIDs: rawClusterPhotoIDs[oldID] ?? []
            )
        }
    }

    private static func l2Normalize(_ vector: [Float]?) -> [Float] {
        guard let vector, !vector.isEmpty else { return [] }
        let normSq = vector.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = sqrt(normSq)
        guard norm > 1e-8 else { return [] }
        return vector.map { $0 / norm }
    }

    /// Computes cosine distance `1 - cos(a, b)` in `[0, 2]`.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2.0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 2.0 }
        let similarity = max(-1.0, min(1.0, dot / denom))
        return 1.0 - similarity
    }
}
