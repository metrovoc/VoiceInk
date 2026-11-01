import Foundation
import os
import ZIPFoundation
import SwiftUI
import Atomics

// MARK: - WhisperModelFile

struct WhisperModelFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var coreMLEncoderURL: URL? // Path to the unzipped .mlmodelc directory
    var isCoreMLDownloaded: Bool { coreMLEncoderURL != nil }

    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
    }

    var filename: String {
        "\(name).bin"
    }

    // Core ML related properties
    var coreMLZipDownloadURL: String? {
        // Only non-quantized models have Core ML versions
        guard !name.contains("q5") && !name.contains("q8") else { return nil }
        return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)-encoder.mlmodelc.zip"
    }

    var coreMLEncoderDirectoryName: String? {
        guard coreMLZipDownloadURL != nil else { return nil }
        return "\(name)-encoder.mlmodelc"
    }
}

// MARK: - Private download task delegate

private final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Never>
    private let finished = ManagedAtomic(false)

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if finished.exchange(true, ordering: .acquiring) == false {
            continuation.resume()
        }
    }
}

private final class DownloadProgressPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdateTime = Date()
    private var lastProgressValue: Double = 0

    func shouldPublish(_ progress: Double, at time: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard time.timeIntervalSince(lastUpdateTime) >= 0.5,
              abs(progress - lastProgressValue) >= 0.01 else {
            return false
        }
        lastUpdateTime = time
        lastProgressValue = progress
        return true
    }
}

enum CoreMLArchiveEntryKind: Equatable {
    case file
    case directory
    case symbolicLink
}

struct CoreMLArchiveEntryPolicy {
    static let maximumEntrySize: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumTotalSize: UInt64 = 16 * 1_024 * 1_024 * 1_024
    static let maximumEntryCount = 10_000

    private(set) var entryCount = 0
    private(set) var declaredSize: UInt64 = 0

    mutating func accept(
        path: String,
        kind: CoreMLArchiveEntryKind,
        uncompressedSize: UInt64
    ) -> Bool {
        guard kind != .symbolicLink,
              Self.isSafeRelativePath(path),
              entryCount < Self.maximumEntryCount,
              uncompressedSize <= Self.maximumEntrySize,
              declaredSize <= Self.maximumTotalSize,
              uncompressedSize <= Self.maximumTotalSize - declaredSize,
              kind != .directory || uncompressedSize == 0 else {
            return false
        }
        entryCount += 1
        declaredSize += uncompressedSize
        return true
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.utf8.contains(0) else {
            return false
        }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !normalized.isEmpty else { return false }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

// MARK: - WhisperModelManager

@MainActor
class WhisperModelManager: ObservableObject {
    @Published var availableModels: [WhisperModelFile] = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var whisperContext: WhisperContext?
    @Published var isModelLoaded = false
    @Published var loadedWhisperModel: WhisperModelFile?
    @Published var isModelLoading = false

    private struct ActiveModelLoad {
        let modelName: String
        let generation: UInt64
        let task: Task<WhisperContext, Error>
    }

    private var modelLoadGeneration: UInt64 = 0
    private var activeModelLoad: ActiveModelLoad?

    let modelsDirectory: URL
    let whisperPrompt = WhisperPrompt()

    /// Called when a model is deleted, passing the model name.
    /// TranscriptionModelManager listens to clear currentTranscriptionModel if needed.
    var onModelDeleted: ((String) -> Void)?

    /// Called after a new model is added (downloaded or imported) so
    /// TranscriptionModelManager can rebuild allAvailableModels.
    var onModelsChanged: (() -> Void)?

    let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "WhisperModelManager")

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - Model Directory Management

    func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logError("Error creating models directory", error)
        }
    }

    func loadAvailableModels() {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
            availableModels = fileURLs.compactMap { url in
                guard url.pathExtension == "bin" else { return nil }
                return WhisperModelFile(name: url.deletingPathExtension().lastPathComponent, url: url)
            }
        } catch {
            logError("Error loading available models", error)
        }
    }

    // MARK: - Model Loading

    func loadModel(_ model: WhisperModelFile) async throws {
        if whisperContext != nil, loadedWhisperModel?.name == model.name {
            return
        }

        let load: ActiveModelLoad
        if let activeModelLoad, activeModelLoad.modelName == model.name {
            load = activeModelLoad
        } else {
            modelLoadGeneration &+= 1
            let generation = modelLoadGeneration
            activeModelLoad?.task.cancel()
            activeModelLoad = nil

            let previousContext = whisperContext
            whisperContext = nil
            loadedWhisperModel = nil
            isModelLoaded = false
            if let previousContext {
                await previousContext.releaseResources()
            }
            guard generation == modelLoadGeneration else {
                throw CancellationError()
            }

            isModelLoading = true
            let path = model.url.path
            let task = Task.detached(priority: .userInitiated) {
                try await WhisperContext.createContext(path: path)
            }
            let newLoad = ActiveModelLoad(
                modelName: model.name,
                generation: generation,
                task: task
            )
            activeModelLoad = newLoad
            load = newLoad
        }

        do {
            let context = try await load.task.value
            try await installLoadedContext(
                context,
                model: model,
                generation: load.generation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if activeModelLoad?.generation == load.generation {
                activeModelLoad = nil
                isModelLoading = false
            }
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    func context(forModelNamed name: String) async throws -> WhisperContext {
        guard let model = availableModels.first(where: { $0.name == name }) else {
            throw VoiceInkEngineError.modelLoadFailed
        }
        try await loadModel(model)
        guard let context = whisperContext,
              loadedWhisperModel?.name == name else {
            throw VoiceInkEngineError.modelLoadFailed
        }
        return context
    }

    private func installLoadedContext(
        _ context: WhisperContext,
        model: WhisperModelFile,
        generation: UInt64
    ) async throws {
        if whisperContext === context, loadedWhisperModel?.name == model.name {
            return
        }
        guard generation == modelLoadGeneration else {
            await context.releaseResources()
            throw CancellationError()
        }

        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
            ?? whisperPrompt.transcriptionPrompt
        await context.setPrompt(currentPrompt)

        guard generation == modelLoadGeneration else {
            await context.releaseResources()
            throw CancellationError()
        }
        whisperContext = context
        isModelLoaded = true
        loadedWhisperModel = model
        if activeModelLoad?.generation == generation {
            activeModelLoad = nil
            isModelLoading = false
        }
    }

    // MARK: - Model Download & Management

    private func downloadFileWithProgress(from url: URL, progressKey: String) async throws -> Data {
        let destinationURL = modelsDirectory.appendingPathComponent(UUID().uuidString)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let finished = ManagedAtomic(false)

            let finishOnce: @Sendable (Result<Data, Error>) -> Void = { result in
                if finished.exchange(true, ordering: .acquiring) == false {
                    continuation.resume(with: result)
                }
            }

            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    finishOnce(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let tempURL = tempURL else {
                    finishOnce(.failure(URLError(.badServerResponse)))
                    return
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    let data = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
                    finishOnce(.success(data))
                    try? FileManager.default.removeItem(at: destinationURL)
                } catch {
                    finishOnce(.failure(error))
                }
            }

            task.resume()

            let publicationGate = DownloadProgressPublicationGate()

            let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let currentTime = Date()
                let currentProgress = round(progress.fractionCompleted * 100) / 100

                if publicationGate.shouldPublish(currentProgress, at: currentTime) {
                    Task { @MainActor [weak self] in
                        self?.downloadProgress[progressKey] = currentProgress
                    }
                }
            }

            Task {
                await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }, onCancel: {
                    observation.invalidate()
                    finishOnce(.failure(CancellationError()))
                })
            }
        }
    }

    func downloadModel(_ model: WhisperModel) async {
        guard let url = URL(string: model.downloadURL) else { return }
        await performModelDownload(model, url)
    }

    private func performModelDownload(_ model: WhisperModel, _ url: URL) async {
        do {
            var whisperModel = try await downloadMainModel(model, from: url)

            if let coreMLZipURL = whisperModel.coreMLZipDownloadURL,
               let coreMLURL = URL(string: coreMLZipURL) {
                whisperModel = try await downloadAndSetupCoreMLModel(for: whisperModel, from: coreMLURL)
            }

            availableModels.append(whisperModel)
            self.downloadProgress.removeValue(forKey: model.name + "_main")

            onModelsChanged?()

            if shouldWarmup(model) {
                WhisperModelWarmupCoordinator.shared.scheduleWarmup(for: model, whisperModelManager: self)
            }
        } catch {
            handleModelDownloadError(model, error)
        }
    }

    private func downloadMainModel(_ model: WhisperModel, from url: URL) async throws -> WhisperModelFile {
        let progressKeyMain = model.name + "_main"
        let data = try await downloadFileWithProgress(from: url, progressKey: progressKeyMain)

        let destinationURL = modelsDirectory.appendingPathComponent(model.filename)
        try data.write(to: destinationURL)

        return WhisperModelFile(name: model.name, url: destinationURL)
    }

    private func downloadAndSetupCoreMLModel(for model: WhisperModelFile, from url: URL) async throws -> WhisperModelFile {
        let progressKeyCoreML = model.name + "_coreml"
        let coreMLData = try await downloadFileWithProgress(from: url, progressKey: progressKeyCoreML)

        let coreMLZipPath = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc.zip")
        try coreMLData.write(to: coreMLZipPath)

        return try await unzipAndSetupCoreMLModel(for: model, zipPath: coreMLZipPath, progressKey: progressKeyCoreML)
    }

    private func unzipAndSetupCoreMLModel(for model: WhisperModelFile, zipPath: URL, progressKey: String) async throws -> WhisperModelFile {
        defer { try? FileManager.default.removeItem(at: zipPath) }
        let encoderDirectoryName = "\(model.name)-encoder.mlmodelc"
        let modelsDirectory = modelsDirectory
        let extraction = Task.detached(priority: .utility) {
            try Self.extractCoreMLArchive(
                zipPath,
                encoderDirectoryName: encoderDirectoryName,
                into: modelsDirectory
            )
        }
        let destination = try await withTaskCancellationHandler {
            try await extraction.value
        } onCancel: {
            extraction.cancel()
        }

        var installedModel = model
        installedModel.coreMLEncoderURL = destination
        downloadProgress.removeValue(forKey: progressKey)
        return installedModel
    }

    nonisolated private static func extractCoreMLArchive(
        _ archiveURL: URL,
        encoderDirectoryName: String,
        into modelsDirectory: URL
    ) throws -> URL {
        guard CoreMLArchiveEntryPolicy.isSafeRelativePath(encoderDirectoryName),
              !encoderDirectoryName.contains("/") else {
            throw VoiceInkEngineError.unzipFailed
        }

        let fileManager = FileManager.default
        let stagingDirectory = modelsDirectory.appendingPathComponent(
            ".coreml-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let archive = try Archive(url: archiveURL, accessMode: .read)
        var policy = CoreMLArchiveEntryPolicy()
        var extractedSize: UInt64 = 0
        var extractedPaths = Set<String>()

        for entry in archive {
            try Task.checkCancellation()
            let kind: CoreMLArchiveEntryKind
            switch entry.type {
            case .file:
                kind = .file
            case .directory:
                kind = .directory
            case .symlink:
                kind = .symbolicLink
            @unknown default:
                throw VoiceInkEngineError.unzipFailed
            }

            let declaredSize = UInt64(entry.uncompressedSize)
            guard policy.accept(
                path: entry.path,
                kind: kind,
                uncompressedSize: declaredSize
            ) else {
                throw VoiceInkEngineError.unzipFailed
            }

            let normalizedPath = entry.path.hasSuffix("/")
                ? String(entry.path.dropLast())
                : entry.path
            guard extractedPaths.insert(normalizedPath).inserted else {
                throw VoiceInkEngineError.unzipFailed
            }
            let destination = stagingDirectory.appendingPathComponent(normalizedPath)
            guard isContained(destination, in: stagingDirectory) else {
                throw VoiceInkEngineError.unzipFailed
            }

            let checksum: CRC32
            switch kind {
            case .directory:
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                checksum = entry.checksum
            case .symbolicLink:
                throw VoiceInkEngineError.unzipFailed
            case .file:
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard !fileManager.fileExists(atPath: destination.path),
                      fileManager.createFile(
                        atPath: destination.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                      ) else {
                    throw VoiceInkEngineError.unzipFailed
                }

                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var entrySize: UInt64 = 0
                checksum = try archive.extract(entry) { data in
                    try Task.checkCancellation()
                    let chunkSize = UInt64(data.count)
                    guard entrySize <= declaredSize,
                          chunkSize <= declaredSize - entrySize,
                          entrySize <= CoreMLArchiveEntryPolicy.maximumEntrySize,
                          chunkSize <= CoreMLArchiveEntryPolicy.maximumEntrySize - entrySize,
                          extractedSize <= CoreMLArchiveEntryPolicy.maximumTotalSize,
                          chunkSize <= CoreMLArchiveEntryPolicy.maximumTotalSize - extractedSize else {
                        throw VoiceInkEngineError.unzipFailed
                    }
                    try output.write(contentsOf: data)
                    entrySize += chunkSize
                    extractedSize += chunkSize
                }
                guard entrySize == declaredSize else {
                    throw VoiceInkEngineError.unzipFailed
                }
            }
            guard checksum == entry.checksum else {
                throw Archive.ArchiveError.invalidCRC32
            }
        }

        let stagedEncoder = stagingDirectory.appendingPathComponent(
            encoderDirectoryName,
            isDirectory: true
        )
        let values = try stagedEncoder.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              !(try fileManager.contentsOfDirectory(atPath: stagedEncoder.path)).isEmpty else {
            throw VoiceInkEngineError.unzipFailed
        }
        try Task.checkCancellation()

        let destination = modelsDirectory.appendingPathComponent(
            encoderDirectoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedEncoder)
        } else {
            try fileManager.moveItem(at: stagedEncoder, to: destination)
        }
        return destination
    }

    nonisolated private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path + "/"
        return candidate.standardizedFileURL.path.hasPrefix(root)
    }

    private func shouldWarmup(_ model: WhisperModel) -> Bool {
        !model.name.contains("q5") && !model.name.contains("q8")
    }

    private func handleModelDownloadError(_ model: WhisperModel, _ error: Error) {
        self.downloadProgress.removeValue(forKey: model.name + "_main")
        self.downloadProgress.removeValue(forKey: model.name + "_coreml")
    }

    func deleteModel(_ model: WhisperModelFile) async {
        do {
            try FileManager.default.removeItem(at: model.url)

            if let coreMLURL = model.coreMLEncoderURL {
                try? FileManager.default.removeItem(at: coreMLURL)
            } else {
                let coreMLDir = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
                if FileManager.default.fileExists(atPath: coreMLDir.path) {
                    try? FileManager.default.removeItem(at: coreMLDir)
                }
            }

            availableModels.removeAll { $0.id == model.id }

            // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
            onModelDeleted?(model.name)
        } catch {
            logError("Error deleting model: \(model.name)", error)
        }
    }

    func unloadModel() {
        modelLoadGeneration &+= 1
        activeModelLoad?.task.cancel()
        activeModelLoad = nil
        isModelLoading = false
        let context = whisperContext
        whisperContext = nil
        loadedWhisperModel = nil
        isModelLoaded = false
        Task.detached(priority: .utility) {
            await context?.releaseResources()
        }
    }

    func clearDownloadedModels() async {
        for model in availableModels {
            do {
                try FileManager.default.removeItem(at: model.url)
            } catch {
                logError("Error deleting model during cleanup", error)
            }
        }
        availableModels.removeAll()
    }

    // MARK: - Resource Management

    /// Releases the WhisperContext and resets model-loaded state.
    /// Does NOT call serviceRegistry.cleanup() — that is VoiceInkEngine's responsibility.
    func cleanupResources() async {
        logger.notice("WhisperModelManager.cleanupResources: releasing whisper context")
        modelLoadGeneration &+= 1
        activeModelLoad?.task.cancel()
        activeModelLoad = nil
        isModelLoading = false
        let context = whisperContext
        whisperContext = nil
        loadedWhisperModel = nil
        isModelLoaded = false
        await context?.releaseResources()
        logger.notice("WhisperModelManager.cleanupResources: completed")
    }

    // MARK: - Import Local Model

    func importWhisperModel(from sourceURL: URL) async {
        guard sourceURL.pathExtension.lowercased() == "bin" else { return }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = modelsDirectory.appendingPathComponent("\(baseName).bin")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "A model named %@.bin already exists"), baseName),
                type: .warning,
                duration: 4.0
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let newWhisperModel = WhisperModelFile(name: baseName, url: destinationURL)
            availableModels.append(newWhisperModel)

            onModelsChanged?()

            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Imported %@"), destinationURL.lastPathComponent),
                type: .success,
                duration: 3.0
            )
        } catch {
            logError("Failed to import local model", error)
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Failed to import model: %@"), error.localizedDescription),
                type: .error,
                duration: 5.0
            )
        }
    }

    // MARK: - Helpers

    private func logError(_ message: String, _ error: Error) {
        logger.error("❌ \(message, privacy: .public): \(error, privacy: .public)")
    }
}

// MARK: - WhisperModelProvider

extension WhisperModelManager: WhisperModelProvider {}

// MARK: - Download Progress View

struct DownloadProgressView: View {
    let modelName: String
    let downloadProgress: [String: Double]
    var isOptimizing = false

    @Environment(\.colorScheme) private var colorScheme

    private var mainProgress: Double {
        downloadProgress[modelName + "_main"] ?? 0
    }

    private var coreMLProgress: Double {
        supportsCoreML ? (downloadProgress[modelName + "_coreml"] ?? 0) : 0
    }

    private var supportsCoreML: Bool {
        !modelName.contains("q5") && !modelName.contains("q8")
    }

    private var totalProgress: Double {
        if isOptimizing {
            return 1
        }

        return supportsCoreML ? (mainProgress * 0.5) + (coreMLProgress * 0.5) : mainProgress
    }

    private var downloadPhase: String {
        if isOptimizing {
            return String(localized: "Optimizing model for your device")
        }

        if supportsCoreML && downloadProgress[modelName + "_coreml"] != nil {
            return String(format: String(localized: "Downloading Core ML Model for %@"), modelName)
        }
        return String(format: String(localized: "Downloading %@ Model"), modelName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(downloadPhase)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(totalProgress * 100))%")
                    .fontDesign(.monospaced)
            }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(.secondaryLabelColor))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.Border.control.opacity(0.3))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.Accent.primary)
                        .frame(width: max(0, min(geometry.size.width * totalProgress, geometry.size.width)), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .animation(.smooth, value: totalProgress)
    }
}
