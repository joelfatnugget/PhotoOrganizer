import Foundation
import Darwin

/// Errors raised during filesystem execution or undo rollback.
public enum FileExecutionError: Error, LocalizedError {
    case copyfileFailed(source: String, destination: String, errnoValue: Int32)
    case undoJournalNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .copyfileFailed(let src, let dst, let err):
            let msg = String(cString: strerror(err))
            return "Failed to clone/copy '\(src)' to '\(dst)': \(msg) (errno \(err))"
        case .undoJournalNotFound(let url):
            return "No undo journal found at \(url.path)"
        }
    }
}

/// Executes an `OrganizationPlan` using APFS `COPYFILE_CLONE` / atomic move and writes an Undo journal.
public struct FileExecutor: Sendable {
    public init() {}

    /// Executes all planned operations and persists `.photo-organizer-journal.json` for 1-click Undo.
    @discardableResult
    public func execute(
        plan: OrganizationPlan,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> UndoJournal {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: plan.destinationRootURL, withIntermediateDirectories: true)

        var records: [UndoRecord] = []
        var relocatedSourceByOriginalURL: [URL: URL] = [:]

        // Execute primary operations before secondary cross-links so moved files exist at their new path before cloning.
        let orderedOps = plan.operations.sorted { lhs, rhs in
            if lhs.isSecondaryCrossLink != rhs.isSecondaryCrossLink {
                return !lhs.isSecondaryCrossLink
            }
            return lhs.destinationRelativePath < rhs.destinationRelativePath
        }

        let total = orderedOps.count
        for (index, op) in orderedOps.enumerated() {
            let parentDir = op.destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let effectiveSourceURL = relocatedSourceByOriginalURL[op.sourceURL] ?? op.sourceURL
            let shouldMove = (plan.options.executionMode == .inPlaceMove) && !op.isSecondaryCrossLink

            if shouldMove {
                if effectiveSourceURL.standardizedFileURL != op.destinationURL.standardizedFileURL {
                    try fileManager.moveItem(at: effectiveSourceURL, to: op.destinationURL)
                    relocatedSourceByOriginalURL[op.sourceURL] = op.destinationURL
                    records.append(
                        UndoRecord(
                            sourcePath: op.sourceURL.path,
                            destinationPath: op.destinationURL.path,
                            wasMoved: true
                        )
                    )
                }
            } else {
                try Self.cloneOrCopyFile(from: effectiveSourceURL, to: op.destinationURL)
                records.append(
                    UndoRecord(
                        sourcePath: effectiveSourceURL.path,
                        destinationPath: op.destinationURL.path,
                        wasMoved: false
                    )
                )
            }

            onProgress?(index + 1, total)
        }

        let journal = UndoJournal(
            timestamp: Date(),
            mode: plan.options.executionMode,
            destinationRootPath: plan.destinationRootURL.path,
            records: records
        )

        let journalURL = plan.destinationRootURL.appendingPathComponent(UndoJournal.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(journal)
        try data.write(to: journalURL, options: .atomic)

        return journal
    }

    /// Reverts the last organization recorded in `.photo-organizer-journal.json`.
    public func undoLastOrganization(at destinationRootURL: URL) throws {
        let fileManager = FileManager.default
        let journalURL = destinationRootURL.appendingPathComponent(UndoJournal.filename)
        guard fileManager.fileExists(atPath: journalURL.path) else {
            throw FileExecutionError.undoJournalNotFound(journalURL)
        }

        let data = try Data(contentsOf: journalURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(UndoJournal.self, from: data)

        // Reverse order ensures clones from moved files are deleted before moving primary files back.
        for record in journal.records.reversed() {
            let dstURL = URL(fileURLWithPath: record.destinationPath)
            let srcURL = URL(fileURLWithPath: record.sourcePath)

            if record.wasMoved {
                if fileManager.fileExists(atPath: dstURL.path) {
                    let srcParent = srcURL.deletingLastPathComponent()
                    try fileManager.createDirectory(at: srcParent, withIntermediateDirectories: true)
                    if !fileManager.fileExists(atPath: srcURL.path) {
                        try fileManager.moveItem(at: dstURL, to: srcURL)
                    }
                }
            } else {
                if fileManager.fileExists(atPath: dstURL.path) {
                    try fileManager.removeItem(at: dstURL)
                }
            }
        }

        try fileManager.removeItem(at: journalURL)
        pruneEmptyDirectories(under: destinationRootURL)
    }

    /// Checks whether an undo journal exists at `destinationRootURL`.
    public static func hasUndoJournal(at destinationRootURL: URL) -> Bool {
        let journalURL = destinationRootURL.appendingPathComponent(UndoJournal.filename)
        return FileManager.default.fileExists(atPath: journalURL.path)
    }

    /// Uses macOS `copyfile(COPYFILE_ALL | COPYFILE_CLONE)` for 0-byte APFS clones with cross-volume copy fallback.
    public static func cloneOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { srcPtr in
            destinationURL.path.withCString { dstPtr in
                copyfile(srcPtr, dstPtr, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
            }
        }
        if result != 0 {
            throw FileExecutionError.copyfileFailed(
                source: sourceURL.path,
                destination: destinationURL.path,
                errnoValue: errno
            )
        }
    }

    private func pruneEmptyDirectories(under rootURL: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(url)
            }
        }

        // Remove deepest directories first.
        for dir in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fileManager.removeItem(at: dir)
            }
        }
    }
}
