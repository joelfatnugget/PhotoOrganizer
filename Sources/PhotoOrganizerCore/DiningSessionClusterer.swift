import Foundation

/// Groups food photos (and companion meal receipts) into spatiotemporal dining sessions across mixed cuisines.
public struct DiningSessionClusterer: Sendable {
    public let maxTimeGapSeconds: TimeInterval
    public let maxDistanceMeters: Double

    public init(maxTimeGapSeconds: TimeInterval = 7200, maxDistanceMeters: Double = 100.0) {
        self.maxTimeGapSeconds = maxTimeGapSeconds
        self.maxDistanceMeters = maxDistanceMeters
    }

    /// Clusters food items into `DiningSession`s and assigns `assignedDiningSessionID` on items.
    public func cluster(
        items: inout [AnalyzedMediaItem],
        timeZone: TimeZone = .current
    ) -> [DiningSession] {
        let foodIndices = items.indices
            .filter { items[$0].isFood && !items[$0].isDuplicate }
            .sorted { items[$0].captureDate < items[$1].captureDate }

        guard !foodIndices.isEmpty else { return [] }

        var rawGroups: [[Int]] = []
        var currentGroup: [Int] = [foodIndices[0]]

        for i in 1..<foodIndices.count {
            let currentIdx = foodIndices[i]
            let prevIdx = currentGroup[currentGroup.count - 1]
            let currentItem = items[currentIdx]
            let prevItem = items[prevIdx]

            let deltaT = currentItem.captureDate.timeIntervalSince(prevItem.captureDate)
            let timeMatches = deltaT >= 0 && deltaT <= maxTimeGapSeconds

            let locationMatches: Bool
            if let currentGPS = currentItem.effectiveGPS,
               let anchorGPS = latestGPS(in: currentGroup, items: items) {
                locationMatches = currentGPS.distanceInMeters(to: anchorGPS) <= maxDistanceMeters
            } else {
                // Indoor photos lacking GPS stay inside the active 2-hour meal window.
                locationMatches = true
            }

            if timeMatches && locationMatches {
                currentGroup.append(currentIdx)
            } else {
                rawGroups.append(currentGroup)
                currentGroup = [currentIdx]
            }
        }
        rawGroups.append(currentGroup)

        // Build provisional sessions and enrich with companion receipts captured during each meal.
        let receiptIndices = items.indices.filter {
            items[$0].isReceipt && !items[$0].isFood && !items[$0].isDuplicate
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        struct DraftSession {
            let id: UUID
            let startTime: Date
            let endTime: Date
            let location: ResolvedLocation?
            let mealLabel: String
            var baseName: String
            var itemIndices: [Int]
        }

        var drafts: [DraftSession] = rawGroups.map { group in
            let sessionID = UUID()
            let start = items[group.first!].captureDate
            let end = items[group.last!].captureDate
            let location = group.compactMap { items[$0].resolvedLocation }.first
            let mealLabel = Self.mealLabel(for: start, calendar: calendar)
            let datePrefix = dateFormatter.string(from: start)

            return DraftSession(
                id: sessionID,
                startTime: start,
                endTime: end,
                location: location,
                mealLabel: mealLabel,
                baseName: "\(datePrefix) \(mealLabel)",
                itemIndices: group
            )
        }

        // Attach meal receipts captured during or shortly after the dining session.
        for receiptIdx in receiptIndices {
            let receiptDate = items[receiptIdx].captureDate
            let receiptGPS = items[receiptIdx].effectiveGPS

            for draftIdx in drafts.indices {
                let startWindow = drafts[draftIdx].startTime.addingTimeInterval(-600)
                let endWindow = drafts[draftIdx].endTime.addingTimeInterval(1800)
                guard receiptDate >= startWindow && receiptDate <= endWindow else { continue }

                if let rGPS = receiptGPS,
                   let sGPS = latestGPS(in: drafts[draftIdx].itemIndices, items: items),
                   rGPS.distanceInMeters(to: sGPS) > max(maxDistanceMeters, 150.0) {
                    continue
                }
                drafts[draftIdx].itemIndices.append(receiptIdx)
                break
            }
        }

        // Recompute folder names now that nearby receipts (with potential merchant names) are attached.
        for draftIdx in drafts.indices {
            let loc = drafts[draftIdx].itemIndices
                .compactMap { items[$0].resolvedLocation }
                .first(where: { $0.venueName != nil })
                ?? drafts[draftIdx].location
            let merchantName = drafts[draftIdx].itemIndices
                .compactMap { items[$0].receiptMetadata?.merchantName }
                .first
            let rawVenueLabel = loc?.venueName ?? merchantName
            let venueLabel = rawVenueLabel?
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var folderName = drafts[draftIdx].baseName
            if let venue = venueLabel, !venue.isEmpty {
                folderName += " - \(venue)"
            }
            if let sub = loc?.sublocality,
               let city = loc?.city,
               sub.caseInsensitiveCompare(city) != .orderedSame {
                folderName += " (\(sub))"
            }
            drafts[draftIdx].baseName = folderName
        }

        // Disambiguate duplicate base names on the same day ("- Visit 1", "- Visit 2").
        var baseNameCounts: [String: Int] = [:]
        for draft in drafts {
            baseNameCounts[draft.baseName, default: 0] += 1
        }
        var baseNameNextIndex: [String: Int] = [:]

        var sessions: [DiningSession] = []
        for draft in drafts {
            let folderName: String
            if (baseNameCounts[draft.baseName] ?? 0) > 1 {
                let visitNumber = (baseNameNextIndex[draft.baseName] ?? 0) + 1
                baseNameNextIndex[draft.baseName] = visitNumber
                folderName = "\(draft.baseName) - Visit \(visitNumber)"
            } else {
                folderName = draft.baseName
            }

            for idx in draft.itemIndices {
                items[idx].assignedDiningSessionID = draft.id
            }

            sessions.append(
                DiningSession(
                    id: draft.id,
                    startTime: draft.startTime,
                    endTime: draft.endTime,
                    location: draft.location,
                    mealLabel: draft.mealLabel,
                    folderName: folderName,
                    itemIDs: draft.itemIndices.map { items[$0].id }
                )
            )
        }

        return sessions
    }

    private func latestGPS(in group: [Int], items: [AnalyzedMediaItem]) -> GPSCoordinate? {
        for idx in group.reversed() {
            if let gps = items[idx].effectiveGPS {
                return gps
            }
        }
        return nil
    }

    public static func mealLabel(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5...10: return "Breakfast"
        case 11...14: return "Lunch"
        case 15...16: return "Cafe & Snacks"
        case 17...21: return "Dinner"
        default: return "Late Night"
        }
    }
}
