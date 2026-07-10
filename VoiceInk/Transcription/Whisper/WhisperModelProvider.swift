import Foundation
import SwiftData

/// Protocol that WhisperModelManager conforms to, decoupling TranscriptionServiceRegistry
/// and WhisperTranscriptionService from concrete manager types.
@MainActor
protocol WhisperModelProvider: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var whisperContext: WhisperContext? { get }
    var loadedWhisperModel: WhisperModelFile? { get }
    var availableModels: [WhisperModelFile] { get }

    /// Returns the shared generation-safe context for this model, joining an
    /// in-flight load instead of creating a second native context.
    func context(forModelNamed name: String) async throws -> WhisperContext
}
