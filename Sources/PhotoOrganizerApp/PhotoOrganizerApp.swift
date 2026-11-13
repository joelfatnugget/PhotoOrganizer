import SwiftUI
import UniformTypeIdentifiers
import AppKit
import PhotoOrganizerCore

@main
struct PhotoOrganizerApp: App {
    @StateObject private var viewModel = OrganizerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 960, minHeight: 700)
                .onAppear {
                    if let icon = AppArtworkLoader.loadImage(named: "AppIcon.icns")
                        ?? AppArtworkLoader.loadImage(named: "HeroSilhouette1.png") {
                        NSApplication.shared.applicationIconImage = icon
                    }
                }
        }
        .windowStyle(.automatic)
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: OrganizerViewModel

    var body: some View {
        VStack(spacing: 0) {
            WizardHeaderView(currentStep: viewModel.currentStep)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if let errorMessage = viewModel.errorMessage {
                StatusBannerView(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    onDismiss: { viewModel.errorMessage = nil }
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
            } else if let statusMessage = viewModel.statusMessage, viewModel.currentStep != .completed {
                StatusBannerView(
                    text: statusMessage,
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    onDismiss: { viewModel.statusMessage = nil }
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }

            Group {
                switch viewModel.currentStep {
                case .selectFolders:
                    Step1FolderDropView(viewModel: viewModel)
                case .previewDryRun:
                    Step2DryRunPreviewView(viewModel: viewModel)
                case .completed:
                    Step3CompletionView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Header

private struct WizardHeaderView: View {
    let currentStep: OrganizerViewModel.Step

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PhotoOrganizer")
                        .font(.title2.bold())
                    Text("Offline Apple Neural Engine Photo & Video Sorter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 16) {
                stepPill(number: 1, title: "Select Folder", active: currentStep == .selectFolders, done: currentStep.rawValue > 1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                stepPill(number: 2, title: "Dry-Run Preview", active: currentStep == .previewDryRun, done: currentStep.rawValue > 2)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                stepPill(number: 3, title: "Organize & Undo", active: currentStep == .completed, done: false)
            }
        }
    }

    private func stepPill(number: Int, title: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.2)))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption2.bold())
                        .foregroundStyle(active ? .white : .secondary)
                }
            }
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }
}

private struct StatusBannerView: View {
    let text: String
    let systemImage: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step 1: Folder Dropzone & Options

private struct Step1FolderDropView: View {
    @ObservedObject var viewModel: OrganizerViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.isAnalyzing {
                AnalysisProgressCard(
                    progress: viewModel.progress,
                    onCancel: viewModel.cancelAnalysis
                )
            } else {
                dropZone
                folderSelectionCards
                optionsCard
                Spacer(minLength: 0)
                footerBar
            }
        }
        .padding(24)
    }

    private var dropZone: some View {
        HStack(spacing: 24) {
            AnimatedSilhouetteHeroView(cornerRadius: 12, showSparkles: true)
                .frame(width: 192, height: 128)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Color.white.opacity(0.6), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 10) {
                Text("Drop a Messy Photo & Video Folder Here")
                    .font(.title3.weight(.semibold))

                Text("100% offline on-device sorting by date, venue, face clusters, dining sessions, and image quality.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ForEach([".HEIC", ".JPG", ".RAW", "Live Photos", ".MOV"], id: \.self) { format in
                        Text(format)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }

                Button {
                    viewModel.pickSourceFolder()
                } label: {
                    Label("Browse Source Folder...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            isDropTargeted
                                ? Color.accentColor.opacity(0.08)
                                : Color(nsColor: .controlBackgroundColor).opacity(0.75)
                        )
                )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var folderSelectionCards: some View {
        HStack(spacing: 12) {
            FolderPathBox(
                title: "Source Folder",
                systemImage: "folder.fill",
                url: viewModel.sourceURL,
                placeholder: "No folder selected",
                actionTitle: "Choose...",
                action: viewModel.pickSourceFolder
            )

            Image(systemName: "arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(viewModel.sourceURL == nil ? Color.secondary.opacity(0.45) : Color.accentColor)

            FolderPathBox(
                title: "Organized Output Folder",
                systemImage: "folder.badge.gearshape",
                url: viewModel.destinationURL,
                placeholder: "Auto-created beside source",
                actionTitle: "Change...",
                action: viewModel.pickDestinationFolder
            )
        }
    }

    private var optionsCard: some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox("Workflow & Location") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File Handling")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("File Handling", selection: $viewModel.options.executionMode) {
                            ForEach(ExecutionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        Text(
                            viewModel.options.executionMode == .safeCopyAPFSClone
                                ? "Creates zero-byte APFS clones; original files stay untouched."
                                : "Moves originals into organized folders with full 1-click undo."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fallback Venue / Location (Optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                            TextField(
                                "e.g. National University of Singapore",
                                text: $viewModel.options.fallbackLocationQuery
                            )
                            .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        Text("Applied to non-GPS camera photos lacking nearby geotagged shots.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            GroupBox("Smart Curation & Output") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            OptionToggleRow(
                                title: "Cross-Link Groups",
                                badge: "0 B APFS",
                                isOn: $viewModel.options.enableMultiCategoryCrossLinks
                            )
                            OptionToggleRow(
                                title: "Isolate Duplicates",
                                badge: "_Duplicates/",
                                isOn: $viewModel.options.deduplicateExactMatches
                            )
                        }
                        GridRow {
                            OptionToggleRow(
                                title: "Separate Blurry",
                                badge: "_Blurry & Outtakes/",
                                isOn: $viewModel.options.separateBlurryPhotos
                            )
                            OptionToggleRow(
                                title: "Separate Bursts",
                                badge: "_Burst Extras/",
                                isOn: $viewModel.options.separateBurstExtras
                            )
                        }
                    }

                    Divider()

                    OptionToggleRow(
                        title: "Generate Interactive Map & Analytics Dashboard",
                        badge: "index.html",
                        isOn: $viewModel.options.generateHTMLReport
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.canAnalyze ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(viewModel.canAnalyze ? Color.green : Color.secondary)
                if let sourceURL = viewModel.sourceURL {
                    Text("Ready to analyze \(sourceURL.lastPathComponent)")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Select or drop a source folder to begin")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.canUndoAtDestination {
                Button("Undo Previous Sort") {
                    viewModel.undoLastSort()
                }
                .buttonStyle(.bordered)
            }

            Button {
                viewModel.startAnalysis()
            } label: {
                Label("Analyze & Preview", systemImage: "sparkles")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canAnalyze)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return
            }
            Task { @MainActor in
                viewModel.setSourceFolder(url)
            }
        }
        return true
    }
}

private struct OptionToggleRow: View {
    let title: String
    let badge: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                Text(badge)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct FolderPathBox: View {
    let title: String
    let systemImage: String
    let url: URL?
    let placeholder: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(url?.path ?? placeholder)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .tertiary : .primary)
            }

            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(url == nil ? Color.secondary.opacity(0.16) : Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct AnalysisProgressCard: View {
    let progress: PipelineProgress?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress?.fractionCompleted ?? 0.0) {
                Text(progress?.stage.rawValue ?? "Preparing...")
                    .font(.headline)
            } currentValueLabel: {
                if let progress {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 460)

            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Step 2: Dry-Run Preview & Face Naming

private struct Step2DryRunPreviewView: View {
    @ObservedObject var viewModel: OrganizerViewModel

    var body: some View {
        VStack(spacing: 14) {
            if let plan = viewModel.plan {
                summaryStrip(plan: plan)

                if !viewModel.faceClusters.isEmpty {
                    faceNamingStrip
                }

                if !plan.diningSessions.isEmpty {
                    restaurantSummaryStrip(sessions: plan.diningSessions)
                }

                dryRunTreeCard(root: plan.treeRoot)

                HStack {
                    Button("Back") {
                        viewModel.resetToStart()
                    }

                    Toggle("Cross-Link Multi-Category", isOn: Binding(
                        get: { viewModel.options.enableMultiCategoryCrossLinks },
                        set: { newValue in
                            viewModel.options.enableMultiCategoryCrossLinks = newValue
                            viewModel.refreshPlanFromCurrentOptions()
                        }
                    ))
                    .padding(.leading, 8)

                    Toggle("Separate Blurry", isOn: Binding(
                        get: { viewModel.options.separateBlurryPhotos },
                        set: { newValue in
                            viewModel.options.separateBlurryPhotos = newValue
                            viewModel.refreshPlanFromCurrentOptions()
                        }
                    ))

                    Toggle("Separate Burst Extras", isOn: Binding(
                        get: { viewModel.options.separateBurstExtras },
                        set: { newValue in
                            viewModel.options.separateBurstExtras = newValue
                            viewModel.refreshPlanFromCurrentOptions()
                        }
                    ))

                    Spacer()

                    if viewModel.isExecuting {
                        ProgressView(
                            value: Double(viewModel.executionProgress?.completed ?? 0),
                            total: Double(max(1, viewModel.executionProgress?.total ?? 1))
                        )
                        .frame(width: 180)
                    }

                    Button {
                        viewModel.executePlan()
                    } label: {
                        Label("Organize Now (\(plan.operations.count) files)", systemImage: "folder.badge.gearshape")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isExecuting || plan.operations.isEmpty)
                }
            }
        }
        .padding(20)
    }

    private func summaryStrip(plan: OrganizationPlan) -> some View {
        HStack(spacing: 12) {
            StatBadge(title: "Media Items", value: "\(plan.items.count)", icon: "photo.stack")
            StatBadge(title: "Restaurant Visits", value: "\(plan.diningSessions.count)", icon: "fork.knife")
            StatBadge(title: "People Clusters", value: "\(viewModel.faceClusters.count)", icon: "person.2")
            StatBadge(title: "Receipts", value: "\(plan.items.filter { $0.isReceipt }.count)", icon: "doc.text.viewfinder")
            StatBadge(title: "Pets", value: "\(plan.items.filter { $0.isPet }.count)", icon: "pawprint")
            StatBadge(title: "Duplicates", value: "\(plan.items.filter { $0.isDuplicate }.count)", icon: "doc.on.doc")
        }
    }

    private var faceNamingStrip: some View {
        GroupBox("Detected People (Optional: Name Before Sorting)") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(viewModel.faceClusters) { cluster in
                        VStack(spacing: 6) {
                            faceAvatar(jpegData: cluster.sampleThumbnailJPEG)
                            Text("\(cluster.photoIDs.count) photos")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField(
                                "Person \(cluster.id + 1)",
                                text: Binding(
                                    get: { cluster.customName },
                                    set: { viewModel.updateFaceClusterName(clusterID: cluster.id, name: $0) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .multilineTextAlignment(.center)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func faceAvatar(jpegData: Data?) -> some View {
        if let jpegData, let nsImage = NSImage(data: jpegData) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }

    private func restaurantSummaryStrip(sessions: [DiningSession]) -> some View {
        GroupBox("Grouped Restaurant & Dining Sessions") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sessions) { session in
                        HStack(spacing: 6) {
                            Image(systemName: "fork.knife.circle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.folderName)
                                    .font(.caption.weight(.semibold))
                                Text("\(session.itemIDs.count) items")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func dryRunTreeCard(root: FolderTreeNode) -> some View {
        GroupBox("Dry-Run Destination Structure") {
            List {
                OutlineGroup(root.children, children: \.optionalChildren) { node in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(node.name)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(node.totalFileCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !node.files.isEmpty {
                            ForEach(node.files.prefix(25), id: \.self) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: "photo")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(file)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 20)
                            }
                            if node.files.count > 25 {
                                Text("+ \(node.files.count - 25) more files")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct StatBadge: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step 3: Completion & 1-Click Undo

private struct Step3CompletionView: View {
    @ObservedObject var viewModel: OrganizerViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Organization Complete")
                .font(.title.bold())

            if let journal = viewModel.lastJournal {
                Text("Executed \(journal.records.count) file operations in \(journal.mode.rawValue) mode.\nTransaction log saved to \(UndoJournal.filename).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                if viewModel.canOpenHTMLReport {
                    Button {
                        viewModel.openHTMLReport()
                    } label: {
                        Label("Open Interactive Map & Report", systemImage: "map")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Button {
                    viewModel.revealDestinationInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    viewModel.undoLastSort()
                } label: {
                    Label("Undo Last Sort", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Organize Another Folder") {
                    viewModel.resetToStart()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum AppArtworkLoader {
    static func loadImage(named filename: String) -> NSImage? {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidateURLs: [URL] = []

        if let resURL = Bundle.main.resourceURL {
            candidateURLs.append(resURL.appendingPathComponent(filename))
            candidateURLs.append(resURL.appendingPathComponent("PhotoOrganizer_PhotoOrganizerCore.bundle/Contents/Resources/\(filename)"))
            candidateURLs.append(resURL.appendingPathComponent("PhotoOrganizer_PhotoOrganizerCore.bundle/\(filename)"))
        }
        let execSibling = Bundle.main.bundleURL.appendingPathComponent("PhotoOrganizer_PhotoOrganizerCore.bundle")
        candidateURLs.append(execSibling.appendingPathComponent(filename))
        candidateURLs.append(execSibling.appendingPathComponent("Contents/Resources/\(filename)"))

        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: stem, withExtension: ext) {
                candidateURLs.append(url)
            }
        }

        for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }
}

private struct AnimatedSilhouetteHeroView: View {
    let cornerRadius: CGFloat
    let showSparkles: Bool

    private let frame1 = AppArtworkLoader.loadImage(named: "HeroSilhouette1.png")
    private let frame2 = AppArtworkLoader.loadImage(named: "HeroSilhouette2.png")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 1.4
            let crossfade = 0.5 * (1.0 - cos(t))
            let floatY = sin(t) * (showSparkles ? 2.5 : 1.0)
            let breathScale = 1.0 + 0.015 * sin(t)

            ZStack {
                if let frame1 {
                    Image(nsImage: frame1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }

                if let frame2 {
                    Image(nsImage: frame2)
                        .resizable()
                        .scaledToFill()
                        .opacity(crossfade)
                }

                if showSparkles {
                    Canvas { gfx, size in
                        let anchors: [(Double, Double, Double)] = [
                            (0.18, 0.28, 0.0),
                            (0.28, 0.18, 1.4),
                            (0.76, 0.22, 2.3),
                            (0.86, 0.36, 3.6)
                        ]
                        for (ax, ay, offset) in anchors {
                            let x = ax * size.width + sin(t + offset) * 3.0
                            let y = ay * size.height - ((t * 4.0 + offset * 5.0).truncatingRemainder(dividingBy: 10.0))
                            let alpha = 0.35 + 0.55 * (0.5 + 0.5 * sin(t * 2.0 + offset))
                            let rect = CGRect(x: x - 2.0, y: y - 2.0, width: 4.0, height: 4.0)
                            gfx.fill(
                                Path(ellipseIn: rect),
                                with: .color(Color(red: 1.0, green: 0.90, blue: 0.62).opacity(alpha))
                            )
                        }
                    }
                }
            }
            .scaleEffect(breathScale)
            .offset(y: floatY)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
