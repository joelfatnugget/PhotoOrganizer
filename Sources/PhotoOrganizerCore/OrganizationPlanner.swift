import Foundation

/// Builds a deterministic nested folder plan (`YYYY / MM - Month / City, Country / Category`) and dry-run tree.
public struct OrganizationPlanner: Sendable {
    private static let monthNames: [String] = [
        "01 - January", "02 - February", "03 - March", "04 - April",
        "05 - May", "06 - June", "07 - July", "08 - August",
        "09 - September", "10 - October", "11 - November", "12 - December"
    ]

    public init() {}

    /// Updates `detectedCategories` and `primaryCategory` on each item using deterministic priority.
    public static func classifyCategories(for items: inout [AnalyzedMediaItem]) {
        for idx in items.indices {
            var categories: Set<PhotoCategory> = []
            if items[idx].isScreenshot { categories.insert(.screenshots) }
            if items[idx].isReceipt { categories.insert(.receipts) }
            if items[idx].isFood { categories.insert(.foodAndRestaurants) }
            if items[idx].isPet { categories.insert(.pets) }
            if !items[idx].faces.isEmpty { categories.insert(.people) }
            if categories.isEmpty { categories.insert(.sceneryAndGeneral) }

            items[idx].detectedCategories = categories
            items[idx].primaryCategory = categories.min { $0.priority < $1.priority } ?? .sceneryAndGeneral
        }
    }

    /// Generates an `OrganizationPlan` (paths, operations, and `FolderTreeNode` preview) without modifying disk.
    public func buildPlan(
        sourceRootURL: URL,
        destinationRootURL: URL,
        items: [AnalyzedMediaItem],
        faceClusters: [FaceCluster],
        diningSessions: [DiningSession],
        options: OrganizationOptions
    ) -> OrganizationPlan {
        var classifiedItems = items
        Self.classifyCategories(for: &classifiedItems)

        let sessionByID = Dictionary(uniqueKeysWithValues: diningSessions.map { ($0.id, $0) })
        let clusterByID = Dictionary(uniqueKeysWithValues: faceClusters.map { ($0.id, $0) })

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = options.timeZone

        var usedPathsLowercased = Set<String>()
        var operations: [PlannedFileOperation] = []

        func reserveUniqueRelativePath(folderRelativePath: String, filename: String) -> String {
            let ext = (filename as NSString).pathExtension
            let stem = (filename as NSString).deletingPathExtension
            var candidateName = filename
            var counter = 1

            while true {
                let relative = folderRelativePath.isEmpty ? candidateName : "\(folderRelativePath)/\(candidateName)"
                let lower = relative.lowercased()
                if !usedPathsLowercased.contains(lower) {
                    usedPathsLowercased.insert(lower)
                    return relative
                }
                candidateName = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
                counter += 1
            }
        }

        func appendUnitOperations(
            for item: AnalyzedMediaItem,
            folderRelativePath: String,
            category: PhotoCategory,
            isSecondaryCrossLink: Bool
        ) {
            let primaryRelative = reserveUniqueRelativePath(
                folderRelativePath: folderRelativePath,
                filename: item.sourceURL.lastPathComponent
            )
            operations.append(
                PlannedFileOperation(
                    itemID: item.id,
                    sourceURL: item.sourceURL,
                    destinationRelativePath: primaryRelative,
                    destinationURL: destinationRootURL.appendingPathComponent(primaryRelative),
                    isSecondaryCrossLink: isSecondaryCrossLink,
                    category: category
                )
            )

            // Keep Apple Live Photo .mov companion right beside its paired still image with matching stem.
            if let companionURL = item.companionVideoURL {
                let pairedStillStem = ((primaryRelative as NSString).lastPathComponent as NSString).deletingPathExtension
                let companionExt = companionURL.pathExtension
                let companionFilename = companionExt.isEmpty ? pairedStillStem : "\(pairedStillStem).\(companionExt)"
                let companionRelative = reserveUniqueRelativePath(
                    folderRelativePath: folderRelativePath,
                    filename: companionFilename
                )
                operations.append(
                    PlannedFileOperation(
                        itemID: item.id,
                        sourceURL: companionURL,
                        destinationRelativePath: companionRelative,
                        destinationURL: destinationRootURL.appendingPathComponent(companionRelative),
                        isSecondaryCrossLink: isSecondaryCrossLink,
                        category: category
                    )
                )
            }
        }

        func categoryFolderPath(for item: AnalyzedMediaItem, category: PhotoCategory) -> String {
            switch category {
            case .screenshots:
                return PhotoCategory.screenshots.folderName
            case .receipts:
                return PhotoCategory.receipts.folderName
            case .foodAndRestaurants:
                if let sessionID = item.assignedDiningSessionID, let session = sessionByID[sessionID] {
                    return "\(PhotoCategory.foodAndRestaurants.folderName)/\(sanitizeFolderComponent(session.folderName))"
                }
                return PhotoCategory.foodAndRestaurants.folderName
            case .pets:
                return PhotoCategory.pets.folderName
            case .people:
                let clusterIDs = item.assignedFaceClusterIDs
                if clusterIDs.count > 1 {
                    return "\(PhotoCategory.people.folderName)/Group Photos"
                } else if let cid = clusterIDs.first, let cluster = clusterByID[cid] {
                    return "\(PhotoCategory.people.folderName)/\(sanitizeFolderComponent(cluster.folderName))"
                } else {
                    return "\(PhotoCategory.people.folderName)/Other People"
                }
            case .sceneryAndGeneral:
                return PhotoCategory.sceneryAndGeneral.folderName
            }
        }

        for item in classifiedItems {
            if options.deduplicateExactMatches && item.isDuplicate {
                appendUnitOperations(
                    for: item,
                    folderRelativePath: "_Duplicates",
                    category: item.primaryCategory,
                    isSecondaryCrossLink: false
                )
                continue
            }

            let comps = calendar.dateComponents([.year, .month], from: item.captureDate)
            let yearString = String(format: "%04d", comps.year ?? 1970)
            let monthIndex = max(1, min(12, comps.month ?? 1)) - 1
            let monthString = Self.monthNames[monthIndex]
            let locationString = sanitizeFolderComponent(item.resolvedLocation?.folderName ?? "Unknown Location")

            let basePrefix = "\(yearString)/\(monthString)/\(locationString)"
            let primaryCategoryPath = categoryFolderPath(for: item, category: item.primaryCategory)

            appendUnitOperations(
                for: item,
                folderRelativePath: "\(basePrefix)/\(primaryCategoryPath)",
                category: item.primaryCategory,
                isSecondaryCrossLink: false
            )

            if options.enableMultiCategoryCrossLinks {
                var extraCategories = item.detectedCategories
                extraCategories.remove(item.primaryCategory)
                extraCategories.remove(.sceneryAndGeneral)

                // Meal receipts assigned to a dining session also cross-link into that meal folder.
                if item.primaryCategory == .receipts && item.assignedDiningSessionID != nil {
                    extraCategories.insert(.foodAndRestaurants)
                }

                for extraCategory in extraCategories.sorted(by: { $0.priority < $1.priority }) {
                    let extraPath = categoryFolderPath(for: item, category: extraCategory)
                    appendUnitOperations(
                        for: item,
                        folderRelativePath: "\(basePrefix)/\(extraPath)",
                        category: extraCategory,
                        isSecondaryCrossLink: true
                    )
                }
            }
        }

        let treeRoot = buildTree(rootName: destinationRootURL.lastPathComponent, operations: operations)

        return OrganizationPlan(
            sourceRootURL: sourceRootURL,
            destinationRootURL: destinationRootURL,
            options: options,
            items: classifiedItems,
            faceClusters: faceClusters,
            diningSessions: diningSessions,
            operations: operations,
            treeRoot: treeRoot
        )
    }

    private func sanitizeFolderComponent(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    private func buildTree(rootName: String, operations: [PlannedFileOperation]) -> FolderTreeNode {
        final class MutableNode {
            let name: String
            let relativePath: String
            var children: [String: MutableNode] = [:]
            var files: [String] = []

            init(name: String, relativePath: String) {
                self.name = name
                self.relativePath = relativePath
            }

            func freeze() -> FolderTreeNode {
                let sortedChildren = children.values
                    .sorted { lhs, rhs in
                        if lhs.name == "_Duplicates" { return false }
                        if rhs.name == "_Duplicates" { return true }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    .map { $0.freeze() }

                let sortedFiles = files.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }

                let childTotal = sortedChildren.reduce(0) { $0 + $1.totalFileCount }
                return FolderTreeNode(
                    id: relativePath.isEmpty ? "__root__" : relativePath,
                    name: name,
                    relativePath: relativePath,
                    children: sortedChildren,
                    files: sortedFiles,
                    totalFileCount: sortedFiles.count + childTotal
                )
            }
        }

        let root = MutableNode(name: rootName, relativePath: "")
        for op in operations {
            let components = op.destinationRelativePath.split(separator: "/").map(String.init)
            guard let filename = components.last else { continue }
            var current = root
            var accumulatedPath = ""
            for folder in components.dropLast() {
                accumulatedPath = accumulatedPath.isEmpty ? folder : "\(accumulatedPath)/\(folder)"
                if let existing = current.children[folder] {
                    current = existing
                } else {
                    let child = MutableNode(name: folder, relativePath: accumulatedPath)
                    current.children[folder] = child
                    current = child
                }
            }
            let label = op.isSecondaryCrossLink ? "\(filename) [APFS Clone]" : filename
            current.files.append(label)
        }

        return root.freeze()
    }
}
