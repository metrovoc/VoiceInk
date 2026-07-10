import Foundation
import Security
import os

/// Securely stores and retrieves API keys using Keychain with iCloud sync.
/// For local (unsigned) builds, uses UserDefaults instead since Keychain
/// requires stable code signing to reliably persist data across rebuilds.
final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private let logger = Logger(subsystem: "com.metrovoc.voiceink", category: "KeychainService")
    private let service = "com.metrovoc.VoiceInk"
    private let testStorageLock = NSLock()
    private var testStorage: [String: Data] = [:]

    #if LOCAL_BUILD
    private let defaults = UserDefaults.standard
    private let localPrefix = "LocalKeychain_"
    #endif

    private init() {}

    /// Unit-test bundles are injected into the app executable before app
    /// initialization. Never contact the user's Keychain from that host: a
    /// locked login keychain can block the main thread before tests even start.
    private var usesEphemeralTestStorage: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    // MARK: - Public API

    /// Saves a string value to Keychain.
    @discardableResult
    func save(_ value: String, forKey key: String, syncable: Bool = true) -> Bool {
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to convert value to data for key: \(key, privacy: .public)")
            return false
        }
        return save(data: data, forKey: key, syncable: syncable)
    }

    /// Saves data to Keychain.
    @discardableResult
    func save(data: Data, forKey key: String, syncable: Bool = true) -> Bool {
        if usesEphemeralTestStorage {
            testStorageLock.lock()
            testStorage[key] = data
            testStorageLock.unlock()
            return true
        }
        #if LOCAL_BUILD
        defaults.set(data, forKey: localPrefix + key)
        return true
        #else
        // First, try to delete any existing item to avoid duplicates
        delete(forKey: key, syncable: syncable)

        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            logger.info("Successfully saved keychain item for key: \(key, privacy: .public)")
            return true
        } else {
            logger.error("Failed to save keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)")
            return false
        }
        #endif
    }

    /// Retrieves a string value from Keychain.
    func getString(forKey key: String, syncable: Bool = true) -> String? {
        guard let data = getData(forKey: key, syncable: syncable) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Retrieves data from Keychain.
    func getData(forKey key: String, syncable: Bool = true) -> Data? {
        if usesEphemeralTestStorage {
            testStorageLock.lock()
            let data = testStorage[key]
            testStorageLock.unlock()
            return data
        }
        #if LOCAL_BUILD
        return defaults.data(forKey: localPrefix + key)
        #else
        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        } else if status != errSecItemNotFound {
            logger.error("Failed to retrieve keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)")
        }

        return nil
        #endif
    }

    /// Deletes an item from Keychain.
    @discardableResult
    func delete(forKey key: String, syncable: Bool = true) -> Bool {
        if usesEphemeralTestStorage {
            testStorageLock.lock()
            testStorage[key] = nil
            testStorageLock.unlock()
            return true
        }
        #if LOCAL_BUILD
        defaults.removeObject(forKey: localPrefix + key)
        return true
        #else
        let query = baseQuery(forKey: key, syncable: syncable)
        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            if status == errSecSuccess {
                logger.info("Successfully deleted keychain item for key: \(key, privacy: .public)")
            }
            return true
        } else {
            logger.error("Failed to delete keychain item for key: \(key, privacy: .public), status: \(status, privacy: .public)")
            return false
        }
        #endif
    }

    /// Checks if a key exists in Keychain.
    func exists(forKey key: String, syncable: Bool = true) -> Bool {
        if usesEphemeralTestStorage {
            testStorageLock.lock()
            let exists = testStorage[key] != nil
            testStorageLock.unlock()
            return exists
        }
        #if LOCAL_BUILD
        return defaults.data(forKey: localPrefix + key) != nil
        #else
        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecReturnData as String] = kCFBooleanFalse

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
        #endif
    }

    // MARK: - Private Helpers

    #if !LOCAL_BUILD
    /// Creates base Keychain query dictionary.
    /// Note: `syncable` parameter is kept for API compatibility but no longer used.
    /// iCloud sync requires code signing, which is disabled for unsigned builds.
    private func baseQuery(forKey key: String, syncable: Bool) -> [String: Any] {
        _ = syncable // Unused - iCloud sync disabled for unsigned builds
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
    #endif
}
