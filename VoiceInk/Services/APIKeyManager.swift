import Foundation
import os

/// Manages API keys using secure Keychain storage.
final class APIKeyManager: @unchecked Sendable {
    static let shared = APIKeyManager()

    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "APIKeyManager")
    private let keychain = KeychainService.shared
    private let cacheLock = NSLock()
    private var cachedValues: [String: String] = [:]

    /// Provider to Keychain identifier mapping (iOS compatible for iCloud sync).
    private static let providerToKeychainKey: [String: String] = [
        "groq": "groqAPIKey",
        "deepgram": "deepgramAPIKey",
        "cerebras": "cerebrasAPIKey",
        "gemini": "geminiAPIKey",
        "mistral": "mistralAPIKey",
        "elevenlabs": "elevenLabsAPIKey",
        "soniox": "sonioxAPIKey",
        "speechmatics": "speechmaticsAPIKey",
        "assemblyai": "assemblyAIAPIKey",
        "xai": "xaiAPIKey",
        "cartesia": "cartesiaAPIKey",
        "openai": "openAIAPIKey",
        "anthropic": "anthropicAPIKey",
        "openrouter": "openRouterAPIKey"
    ]

    private init() {}

    // MARK: - Standard Provider API Keys

    /// Saves an API key for a provider.
    @discardableResult
    func saveAPIKey(_ key: String, forProvider provider: String) -> Bool {
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        let success = keychain.save(key, forKey: keyIdentifier)
        if success {
            storeCachedValue(key, for: keyIdentifier)
            logger.info("Saved API key for provider: \(provider, privacy: .public) with key: \(keyIdentifier, privacy: .public)")
        }
        return success
    }

    /// Retrieves an API key for a provider.
    func getAPIKey(forProvider provider: String) -> String? {
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        return cachedOrLoadedValue(for: keyIdentifier)
    }

    /// Deletes an API key for a provider.
    @discardableResult
    func deleteAPIKey(forProvider provider: String) -> Bool {
        let keyIdentifier = keychainIdentifier(forProvider: provider)
        let success = keychain.delete(forKey: keyIdentifier)
        if success {
            removeCachedValue(for: keyIdentifier)
            logger.info("Deleted API key for provider: \(provider, privacy: .public)")
        }
        return success
    }

    /// Checks if an API key exists for a provider.
    func hasAPIKey(forProvider provider: String) -> Bool {
        guard let key = getAPIKey(forProvider: provider) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Custom Model API Keys

    /// Saves an API key for a custom model.
    @discardableResult
    func saveCustomModelAPIKey(_ key: String, forModelId modelId: UUID) -> Bool {
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        let success = keychain.save(key, forKey: keyIdentifier)
        if success {
            storeCachedValue(key, for: keyIdentifier)
            logger.info("Saved API key for custom model: \(modelId.uuidString, privacy: .public)")
        }
        return success
    }

    /// Retrieves an API key for a custom model.
    func getCustomModelAPIKey(forModelId modelId: UUID) -> String? {
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        return cachedOrLoadedValue(for: keyIdentifier)
    }

    /// Deletes an API key for a custom model.
    @discardableResult
    func deleteCustomModelAPIKey(forModelId modelId: UUID) -> Bool {
        let keyIdentifier = customModelKeyIdentifier(for: modelId)
        let success = keychain.delete(forKey: keyIdentifier)
        if success {
            removeCachedValue(for: keyIdentifier)
            logger.info("Deleted API key for custom model: \(modelId.uuidString, privacy: .public)")
        }
        return success
    }

    // MARK: - Custom AI Provider API Keys

    @discardableResult
    func saveCustomAIProviderAPIKey(_ key: String, forProviderId providerId: UUID) -> Bool {
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        let success = keychain.save(key, forKey: keyIdentifier)
        if success {
            storeCachedValue(key, for: keyIdentifier)
            logger.info("Saved API key for custom AI provider: \(providerId.uuidString, privacy: .public)")
        }
        return success
    }

    func getCustomAIProviderAPIKey(forProviderId providerId: UUID) -> String? {
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        return cachedOrLoadedValue(for: keyIdentifier)
    }

    @discardableResult
    func deleteCustomAIProviderAPIKey(forProviderId providerId: UUID) -> Bool {
        let keyIdentifier = customAIProviderKeyIdentifier(for: providerId)
        let success = keychain.delete(forKey: keyIdentifier)
        if success {
            removeCachedValue(for: keyIdentifier)
            logger.info("Deleted API key for custom AI provider: \(providerId.uuidString, privacy: .public)")
        }
        return success
    }

    // MARK: - Key Identifier Helpers

    /// Returns Keychain identifier for a provider (case-insensitive).
    private func keychainIdentifier(forProvider provider: String) -> String {
        let lowercased = provider.lowercased()
        if let mapped = Self.providerToKeychainKey[lowercased] {
            return mapped
        }
        return "\(lowercased)APIKey"
    }

    /// Generates Keychain identifier for custom model API key.
    private func customModelKeyIdentifier(for modelId: UUID) -> String {
        "customModel_\(modelId.uuidString)_APIKey"
    }

    private func customAIProviderKeyIdentifier(for providerId: UUID) -> String {
        "customAIProvider_\(providerId.uuidString)_APIKey"
    }

    /// Successful reads are immutable for the lifetime of the configured key;
    /// every in-process save/delete updates this cache synchronously. This keeps
    /// Keychain IPC out of recurring preconnects without caching misses or
    /// changing persistence semantics.
    private func cachedOrLoadedValue(for identifier: String) -> String? {
        cacheLock.lock()
        if let cached = cachedValues[identifier] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let loaded = keychain.getString(forKey: identifier) else {
            return nil
        }
        storeCachedValue(loaded, for: identifier)
        return loaded
    }

    private func storeCachedValue(_ value: String, for identifier: String) {
        cacheLock.lock()
        cachedValues[identifier] = value
        cacheLock.unlock()
    }

    private func removeCachedValue(for identifier: String) {
        cacheLock.lock()
        cachedValues[identifier] = nil
        cacheLock.unlock()
    }
}
