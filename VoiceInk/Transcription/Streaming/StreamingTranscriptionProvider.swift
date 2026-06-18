import Foundation

/// Events emitted by a streaming transcription provider
enum StreamingTranscriptionEvent {
    case sessionStarted
    case partial(text: String)
    case committed(text: String)
    case error(Error)
}

/// Errors specific to streaming transcription
enum StreamingTranscriptionError: LocalizedError {
    case missingAPIKey
    case connectionFailed(String)
    case timeout
    case serverError(String)
    case notConnected
    case audioConversionFailed
    case emptyTranscript
    case audioDropped(chunks: Int, bytes: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "API key not configured for streaming transcription")
        case .connectionFailed(let message):
            return String(format: String(localized: "Streaming connection failed: %@"), message)
        case .timeout:
            return String(localized: "Streaming transcription timed out waiting for final result")
        case .serverError(let message):
            return String(format: String(localized: "Streaming server error: %@"), message)
        case .notConnected:
            return String(localized: "Not connected to streaming transcription service")
        case .audioConversionFailed:
            return String(localized: "Failed to convert audio chunk for streaming")
        case .emptyTranscript:
            return String(localized: "Streaming transcription returned no text")
        case .audioDropped(let chunks, let bytes):
            return String(format: String(localized: "Streaming audio dropped %d chunks (%d bytes)"), chunks, bytes)
        }
    }
}

/// Protocol for streaming transcription providers.
protocol StreamingTranscriptionProvider: AnyObject {
    /// Connect to the streaming transcription endpoint
    func connect(model: any TranscriptionModel, language: String?) async throws

    /// Send a chunk of raw PCM audio data (16-bit, 16kHz, mono, little-endian)
    func sendAudioChunk(_ data: Data) async throws

    /// Commit the current audio buffer to finalize transcription
    func commit() async throws

    /// Disconnect from the streaming endpoint
    func disconnect() async

    /// Stream of transcription events from the provider
    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> { get }
}
