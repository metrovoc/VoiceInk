import Foundation
import SwiftData
import os

/// Sendable source that bridges audio chunks from any thread into an AsyncStream.
private final class AudioChunkSource: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func send(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }
}

/// Lifecycle states for a streaming transcription session.
enum StreamingState {
    case idle
    case connecting
    case streaming
    case committing
    case done
    case failed
    case cancelled
}

protocol StreamingTranscriptionServicing: AnyObject {
    @MainActor
    var isActive: Bool { get }

    @MainActor
    func startStreaming(model: any TranscriptionModel) async throws

    nonisolated func sendAudioChunk(_ data: Data)

    @MainActor
    func stopAndGetFinalText() async throws -> String

    @MainActor
    func cancel()
}

/// Manages a streaming transcription lifecycle: buffers audio chunks, sends them to the provider, and collects the final text.
@MainActor
class StreamingTranscriptionService: StreamingTranscriptionServicing {
    typealias ProviderFactory = (any TranscriptionModel, ModelContext, ParakeetTranscriptionService?) -> StreamingTranscriptionProvider

    private let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "StreamingTranscriptionService")
    private var provider: StreamingTranscriptionProvider?
    private var sendTask: Task<Void, Never>?
    private var sendLoopFinishedStream: AsyncStream<Void>?
    private var sendLoopFinishedContinuation: AsyncStream<Void>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?
    private let chunkSource = AudioChunkSource()
    private var state: StreamingState = .idle
    private var committedSegments: [String] = []
    private let modelContext: ModelContext
    private let parakeetService: ParakeetTranscriptionService?
    private let providerFactory: ProviderFactory
    private let drainTimeoutNanoseconds: UInt64
    private let finalCommitTimeoutNanoseconds: UInt64
    private var onPartialTranscript: ((String) -> Void)?

    init(
        modelContext: ModelContext,
        parakeetService: ParakeetTranscriptionService? = nil,
        onPartialTranscript: ((String) -> Void)? = nil,
        providerFactory: ProviderFactory? = nil,
        drainTimeoutNanoseconds: UInt64 = 3_000_000_000,
        finalCommitTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.modelContext = modelContext
        self.parakeetService = parakeetService
        self.providerFactory = providerFactory ?? Self.defaultProviderFactory
        self.drainTimeoutNanoseconds = drainTimeoutNanoseconds
        self.finalCommitTimeoutNanoseconds = finalCommitTimeoutNanoseconds
        self.onPartialTranscript = onPartialTranscript
    }

    deinit {
        onPartialTranscript = nil
        sendTask?.cancel()
        sendLoopFinishedContinuation?.finish()
        eventConsumerTask?.cancel()
        chunkSource.finish()
        commitSignal?.finish()
    }

    /// Signal used to notify `waitForFinalCommit` when a new committed segment arrives.
    private var commitSignal: AsyncStream<Void>.Continuation?

    /// Whether the streaming connection is fully established and actively sending.
    var isActive: Bool { state == .streaming || state == .committing }

    /// Start a streaming transcription session for the given model.
    func startStreaming(model: any TranscriptionModel) async throws {
        state = .connecting
        committedSegments = []

        let provider = providerFactory(model, modelContext, parakeetService)
        self.provider = provider

        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"

        try await provider.connect(model: model, language: selectedLanguage)

        // If cancel() was called while we were awaiting the connection, tear down immediately.
        if state == .cancelled {
            await provider.disconnect()
            self.provider = nil
            return
        }

        state = .streaming
        startSendLoop()
        startEventConsumer()

        logger.notice("Streaming started for model: \(model.displayName, privacy: .public)")
    }

    /// Buffers an audio chunk for sending. Safe to call from the audio callback thread.
    nonisolated func sendAudioChunk(_ data: Data) {
        chunkSource.send(data)
    }

    /// Stops streaming, commits remaining audio, and returns the final transcribed text.
    func stopAndGetFinalText() async throws -> String {
        guard let provider = provider, state == .streaming else {
            throw StreamingTranscriptionError.notConnected
        }

        state = .committing

        // Finish the chunk source so the send loop drains remaining chunks and exits naturally.
        do {
            try await drainRemainingChunks()
        } catch {
            state = .failed
            await cleanupStreaming()
            throw error
        }

        // Set up the commit signal BEFORE sending commit to avoid a race with the response.
        let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
        self.commitSignal = signalContinuation

        // Send commit to finalize any remaining audio
        do {
            try await provider.commit()
        } catch {
            commitSignal?.finish()
            commitSignal = nil
            logger.error("Failed to send commit: \(error.localizedDescription, privacy: .public)")
            state = .failed
            await cleanupStreaming()
            throw error
        }

        // Wait for the server to acknowledge our commit (or timeout)
        let finalText: String
        do {
            finalText = try await waitForFinalCommit(signalStream: signalStream)
        } catch {
            state = .failed
            await cleanupStreaming()
            throw error
        }

        state = .done
        await cleanupStreaming()

        return finalText
    }

    /// Cancels the streaming session without waiting for results.
    func cancel() {
        state = .cancelled
        onPartialTranscript = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        sendLoopFinishedContinuation?.finish()
        sendLoopFinishedContinuation = nil
        sendLoopFinishedStream = nil
        chunkSource.finish()

        // Clean up commit signal if waiting
        commitSignal?.finish()
        commitSignal = nil

        let providerToDisconnect = provider
        provider = nil

        Task {
            await providerToDisconnect?.disconnect()
        }

        committedSegments = []
        logger.notice("Streaming cancelled")
    }

    // MARK: - Private

    private static func defaultProviderFactory(
        model: any TranscriptionModel,
        modelContext: ModelContext,
        parakeetService: ParakeetTranscriptionService?
    ) -> StreamingTranscriptionProvider {
        switch model.provider {
        case .elevenLabs:
            return ElevenLabsStreamingProvider()
        case .deepgram:
            return DeepgramStreamingProvider(modelContext: modelContext)
        case .mistral:
            return MistralStreamingProvider()
        case .soniox:
            return SonioxStreamingProvider(modelContext: modelContext)
        case .parakeet:
            guard let parakeetService else {
                fatalError("ParakeetTranscriptionService required for Parakeet streaming. Ensure it is passed to StreamingTranscriptionService.")
            }
            return ParakeetStreamingProvider(parakeetService: parakeetService)
        default:
            fatalError("Unsupported streaming provider: \(model.provider). Check supportsStreaming() before calling startStreaming().")
        }
    }

    /// Consumes audio chunks from the AsyncStream and sends them to the provider.
    private func startSendLoop() {
        let source = chunkSource
        let provider = provider
        let logger = logger
        let (finishedStream, finishedContinuation) = AsyncStream.makeStream(of: Void.self)
        sendLoopFinishedStream = finishedStream
        sendLoopFinishedContinuation = finishedContinuation

        sendTask = Task.detached { [finishedContinuation, logger] in
            defer {
                finishedContinuation.yield()
                finishedContinuation.finish()
            }
            for await chunk in source.stream {
                do {
                    try await provider?.sendAudioChunk(chunk)
                } catch {
                    let desc = error.localizedDescription
                    logger.error("Failed to send audio chunk: \(desc, privacy: .public)")
                }
            }
        }
    }

    /// Finishes the chunk source and waits for the send loop to process all remaining buffered chunks.
    private func drainRemainingChunks() async throws {
        chunkSource.finish()
        guard let sendTask else { return }
        guard let finishedStream = sendLoopFinishedStream else {
            sendTask.cancel()
            self.sendTask = nil
            throw StreamingTranscriptionError.timeout
        }

        let timeoutNanoseconds = drainTimeoutNanoseconds
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in finishedStream {
                    return true
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if !drained {
            sendTask.cancel()
            self.sendTask = nil
            logger.error("Timed out while draining streaming audio chunks")
            throw StreamingTranscriptionError.timeout
        }

        self.sendTask = nil
        sendLoopFinishedContinuation = nil
        sendLoopFinishedStream = nil
    }

    /// Consumes transcription events throughout the session, accumulating committed segments.
    private func startEventConsumer() {
        guard let provider = provider else { return }
        let events = provider.transcriptionEvents

        eventConsumerTask = Task.detached { [weak self] in
            for await event in events {
                guard let self = self else { break }
                switch event {
                case .committed(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if !trimmed.isEmpty {
                            self.committedSegments.append(trimmed)
                        }

                        // Signal for any committed response (including empty) during committing phase.
                        if self.state == .committing {
                            self.commitSignal?.yield()
                        }
                    }
                case .partial(let text):
                    await MainActor.run {
                        if self.state == .streaming {
                            self.onPartialTranscript?(text)
                        }
                    }
                case .sessionStarted:
                    break
                case .error(let error):
                    await MainActor.run {
                        self.logger.error("Streaming event error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }  
        }
    }

    /// Waits for the server to acknowledge our explicit commit, with a 10-second timeout.
    private func waitForFinalCommit(signalStream: AsyncStream<Void>) async throws -> String {
        // Race: wait for commit acknowledgment vs timeout
        let timeoutNanoseconds = finalCommitTimeoutNanoseconds
        let receivedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in signalStream {
                    return true
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        // Clean up the signal
        commitSignal?.finish()
        commitSignal = nil

        if !receivedInTime && committedSegments.isEmpty {
            logger.warning("No transcript received from streaming")
            throw StreamingTranscriptionError.timeout
        }

        return committedSegments.isEmpty ? "" : committedSegments.joined(separator: " ")
    }

    private func cleanupStreaming() async {
        onPartialTranscript = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        sendLoopFinishedContinuation?.finish()
        sendLoopFinishedContinuation = nil
        sendLoopFinishedStream = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
        await provider?.disconnect()
        provider = nil
        state = .idle
        committedSegments = []
    }
}
