import Foundation

/// Orchestrates the full scan -> metadata -> Vision ANE -> clustering -> dry-run planning pipeline.
public struct OrganizationEngine: Sendable {
    private let scanner = MediaScanner()
    private let metadataExtractor = MetadataExtractor()
    private let geocoder: OfflineGeocoder
    private let venueResolver: VenueResolver
    private let visionAnalyzer = VisionAnalyzer()
    private let burstClusterer = BurstClusterer()
    private let diningClusterer = DiningSessionClusterer()
    private let faceClusterer = FaceDBSCANClusterer()
    private let planner = OrganizationPlanner()
    private let executor = FileExecutor()

    public init(
        geocoder: OfflineGeocoder = OfflineGeocoder(),
        venueResolver: VenueResolver = VenueResolver()
    ) {
        self.geocoder = geocoder
        self.venueResolver = venueResolver
    }

    /// Runs the full offline analysis and returns a dry-run `OrganizationPlan` without modifying files.
    public func analyzeAndPlan(
        sourceRootURL: URL,
        destinationRootURL: URL,
        options: OrganizationOptions = OrganizationOptions(),
        onProgress: (@Sendable (PipelineProgress) -> Void)? = nil
    ) async throws -> OrganizationPlan {
        onProgress?(PipelineProgress(stage: .scanning, completed: 0, total: 1))
        let entries = try await scanner.scan(rootURL: sourceRootURL)
        onProgress?(PipelineProgress(stage: .scanning, completed: 1, total: 1))

        let total = entries.count
        var items: [AnalyzedMediaItem] = []
        items.reserveCapacity(total)
        var seenHashes = Set<String>()

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let meta = await metadataExtractor.extract(entry: entry)
            let isDuplicate: Bool
            if !meta.sha256Hash.isEmpty {
                isDuplicate = !seenHashes.insert(meta.sha256Hash).inserted
            } else {
                isDuplicate = false
            }

            items.append(
                AnalyzedMediaItem(
                    sourceURL: entry.primaryURL,
                    companionVideoURL: entry.companionVideoURL,
                    mediaKind: entry.mediaKind,
                    fileSize: meta.fileSize,
                    sha256Hash: meta.sha256Hash,
                    isDuplicate: isDuplicate,
                    captureDate: meta.captureDate,
                    dateSource: meta.dateSource,
                    rawGPS: meta.gps,
                    isScreenshot: meta.isScreenshot,
                    cameraModel: meta.cameraModel
                )
            )
            onProgress?(PipelineProgress(stage: .metadata, completed: index + 1, total: max(1, total)))
        }

        // Fill indoor GPS gaps (+-2h) and resolve offline reverse-geocoded locations.
        geocoder.inferMissingGPS(for: &items)
        geocoder.resolveLocations(for: &items)

        // Stage 2: On-device Vision Neural Engine pass (skip exact duplicates and screenshots).
        for idx in items.indices {
            try Task.checkCancellation()
            if !(options.deduplicateExactMatches && items[idx].isDuplicate) && !items[idx].isScreenshot {
                let visionResult = await visionAnalyzer.analyze(
                    url: items[idx].sourceURL,
                    mediaKind: items[idx].mediaKind
                )
                items[idx].isReceipt = visionResult.isReceipt
                items[idx].receiptMetadata = visionResult.receiptMetadata
                items[idx].isFood = visionResult.isFood
                items[idx].isPet = visionResult.isPet
                items[idx].faces = visionResult.faces
                items[idx].sharpnessScore = visionResult.sharpnessScore
                items[idx].isBlurry = visionResult.isBlurry
                items[idx].hasClosedEyes = visionResult.hasClosedEyes
            }
            onProgress?(PipelineProgress(stage: .vision, completed: idx + 1, total: max(1, total)))
        }

        onProgress?(PipelineProgress(stage: .clustering, completed: 0, total: 4))
        // Apply fallback query for non-GPS cameras and correlate clusters to nearby venues/POIs.
        await venueResolver.enrichLocationsAndVenues(
            for: &items,
            fallbackQuery: options.fallbackLocationQuery,
            geocoder: geocoder
        )
        OrganizationPlanner.classifyCategories(for: &items)
        onProgress?(PipelineProgress(stage: .clustering, completed: 1, total: 4))
        burstClusterer.cluster(items: &items)
        onProgress?(PipelineProgress(stage: .clustering, completed: 2, total: 4))
        let diningSessions = diningClusterer.cluster(items: &items, timeZone: options.timeZone)
        onProgress?(PipelineProgress(stage: .clustering, completed: 3, total: 4))
        let faceClusters = faceClusterer.cluster(items: &items)
        onProgress?(PipelineProgress(stage: .clustering, completed: 4, total: 4))

        onProgress?(PipelineProgress(stage: .planning, completed: 0, total: 1))
        let plan = planner.buildPlan(
            sourceRootURL: sourceRootURL,
            destinationRootURL: destinationRootURL,
            items: items,
            faceClusters: faceClusters,
            diningSessions: diningSessions,
            options: options
        )
        onProgress?(PipelineProgress(stage: .planning, completed: 1, total: 1))

        return plan
    }

    /// Rebuilds an `OrganizationPlan` instantaneously after the user renames face clusters or toggles options.
    public func rebuildPlan(
        from existingPlan: OrganizationPlan,
        faceClusters: [FaceCluster],
        options: OrganizationOptions
    ) -> OrganizationPlan {
        planner.buildPlan(
            sourceRootURL: existingPlan.sourceRootURL,
            destinationRootURL: existingPlan.destinationRootURL,
            items: existingPlan.items,
            faceClusters: faceClusters,
            diningSessions: existingPlan.diningSessions,
            options: options
        )
    }

    /// Executes an approved `OrganizationPlan` on disk.
    @discardableResult
    public func execute(
        plan: OrganizationPlan,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> UndoJournal {
        try executor.execute(plan: plan, onProgress: onProgress)
    }

    /// Reverts the last executed organization at `destinationRootURL`.
    public func undo(at destinationRootURL: URL) throws {
        try executor.undoLastOrganization(at: destinationRootURL)
    }
}
