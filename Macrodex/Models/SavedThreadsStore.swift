import Foundation

/// Thin Swift wrapper around the local preferences functions.
/// Swift picks the directory and exposes a Swift-shaped API to the rest of the app.
@MainActor
enum SavedThreadsStore {
    static func pinnedKeys() -> [PinnedThreadKey] {
        preferencesLoad(directory: MobilePreferencesDirectory.path).pinnedThreads
    }

    static func add(_ key: PinnedThreadKey) {
        _ = preferencesAddPinnedThread(directory: MobilePreferencesDirectory.path, key: key)
    }

    static func remove(_ key: PinnedThreadKey) {
        _ = preferencesRemovePinnedThread(directory: MobilePreferencesDirectory.path, key: key)
    }

    static func contains(_ key: PinnedThreadKey) -> Bool {
        pinnedKeys().contains(key)
    }

    static func hiddenKeys() -> [PinnedThreadKey] {
        preferencesLoad(directory: MobilePreferencesDirectory.path).hiddenThreads
    }

    static func hide(_ key: PinnedThreadKey) {
        _ = preferencesAddHiddenThread(directory: MobilePreferencesDirectory.path, key: key)
    }

    static func unhide(_ key: PinnedThreadKey) {
        _ = preferencesRemoveHiddenThread(directory: MobilePreferencesDirectory.path, key: key)
    }

    /// Compatibility shim for the old `PinnedKey` type used elsewhere in the app.
    typealias PinnedKey = PinnedThreadKey
}

extension PinnedThreadKey {
    init(threadKey: ThreadKey) {
        self.init(serverId: threadKey.serverId, threadId: threadKey.threadId)
    }

    var threadKey: ThreadKey {
        ThreadKey(serverId: serverId, threadId: threadId)
    }
}

enum ManualThreadTitleStore {
    private static let defaultsKey = "manualThreadTitleKeys"

    static func markManuallyRenamed(_ key: ThreadKey) {
        var keys = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        keys.insert(storageKey(for: key))
        UserDefaults.standard.set(Array(keys), forKey: defaultsKey)
    }

    static func isManuallyRenamed(_ key: ThreadKey?) -> Bool {
        guard let key else { return false }
        let keys = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        return keys.contains(storageKey(for: key))
    }

    private static func storageKey(for key: ThreadKey) -> String {
        "\(key.serverId)::\(key.threadId)"
    }
}
