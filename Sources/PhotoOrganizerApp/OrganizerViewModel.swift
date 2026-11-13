import Foundation
import SwiftUI
import AppKit
import PhotoOrganizerCore

@MainActor
final class OrganizerViewModel: ObservableObject {
    enum Step: Int {
        case selectFolders = 1
        case previewDryRun = 2
        case completed = 3
    }

    @Published var currentStep: Step = .selectFolders
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    @Published var options = OrganizationOptions()

    @Published var isAnalyzing = false
    @Published var isExecuting = false
    @Published var progress: PipelineProgress?
    @Published var executionProgress: (completed: Int, total: Int)?

    @Published var plan: OrganizationPlan?
    @Published var faceClusters: [FaceCluster] = []
    @Published var lastJournal: UndoJournal?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let engine = OrganizationEngine()
    private var analysisTask: Task<Void, Never>?

    var canAnalyze: Bool {
        sourceURL != nil && destinationURL != nil && !isAnalyzing && !isExecuting
    }

    var canUndoAtDestination: Bool {
        guard let destinationURL else { return false }
        return FileExecutor.hasUndoJournal(at: destinationURL)
    }

    func setSourceFolder(_ url: URL) {
        sourceURL = url
        if destinationURL == nil {
            let parent = url.deletingLastPathComponent()
            let defaultName = "\(url.lastPathComponent)_Organized"
            destinationURL = parent.appendingPathComponent(defaultName, isDirectory: true)
        }
        errorMessage = nil
        statusMessage = nil
    }

    func pickSourceFolder() {
        if let url = openFolderPanel(title: "Choose Source Media Folder") {
            setSourceFolder(url)
        }
    }

    func pickDestinationFolder() {
        if let url = openFolderPanel(title: "Choose Destination Folder", allowCreate: true) {
            destinationURL = url
            errorMessage = nil
            statusMessage = nil
        }
    }

    func startAnalysis() {
        guard let sourceURL, let destinationURL else { return }
        analysisTask?.cancel()
        isAnalyzing = true
        errorMessage = nil
        statusMessage = nil
        progress = PipelineProgress(stage: .scanning, completed: 0, total: 1)

        let selectedOptions = options
        let engine = self.engine
        let reportProgress: @Sendable (PipelineProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.progress = update
            }
        }

        analysisTask = Task { [weak self] in
            do {
                let generatedPlan = try await Task.detached(priority: .userInitiated) {
                    try await engine.analyzeAndPlan(
                        sourceRootURL: sourceURL,
                        destinationRootURL: destinationURL,
                        options: selectedOptions,
                        onProgress: reportProgress
                    )
                }.value

                guard let self, !Task.isCancelled else { return }
                self.plan = generatedPlan
                self.faceClusters = generatedPlan.faceClusters
                self.isAnalyzing = false
                self.currentStep = .previewDryRun
            } catch is CancellationError {
                self?.isAnalyzing = false
            } catch {
                self?.isAnalyzing = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        isAnalyzing = false
    }

    func updateFaceClusterName(clusterID: Int, name: String) {
        guard let idx = faceClusters.firstIndex(where: { $0.id == clusterID }) else { return }
        faceClusters[idx].customName = name
        refreshPlanFromCurrentOptions()
    }

    func refreshPlanFromCurrentOptions() {
        guard let existing = plan else { return }
        plan = engine.rebuildPlan(from: existing, faceClusters: faceClusters, options: options)
    }

    func executePlan() {
        guard let activePlan = plan else { return }
        isExecuting = true
        errorMessage = nil
        executionProgress = (0, activePlan.operations.count)

        let engine = self.engine
        let reportExecProgress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                self?.executionProgress = (done, total)
            }
        }

        Task { [weak self] in
            do {
                let journal = try await Task.detached(priority: .userInitiated) {
                    try engine.execute(plan: activePlan, onProgress: reportExecProgress)
                }.value

                guard let self else { return }
                self.lastJournal = journal
                self.isExecuting = false
                self.currentStep = .completed
                self.statusMessage = "Organized \(journal.records.count) file operations cleanly."
            } catch {
                self?.isExecuting = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func undoLastSort() {
        guard let destinationURL else { return }
        errorMessage = nil
        do {
            try engine.undo(at: destinationURL)
            lastJournal = nil
            statusMessage = "Reverted last sort and restored original state."
            currentStep = .selectFolders
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetToStart() {
        plan = nil
        faceClusters = []
        progress = nil
        executionProgress = nil
        errorMessage = nil
        statusMessage = nil
        currentStep = .selectFolders
    }

    func revealDestinationInFinder() {
        guard let destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    }

    private func openFolderPanel(title: String, allowCreate: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = allowCreate
        return panel.runModal() == .OK ? panel.url : nil
    }
}
