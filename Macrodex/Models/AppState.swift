import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    private struct ThreadPermissionOverride {
        var approvalPolicy: String
        var sandboxMode: String
        var isUserOverride: Bool
        var rawApprovalPolicy: AppAskForApproval?
        var rawSandboxPolicy: AppSandboxPolicy?
    }

    private static let approvalPolicyKey = "macrodex.approvalPolicy"
    private static let sandboxModeKey = "macrodex.sandboxMode"
    private static let selectedModelKey = "macrodex.selectedModel"
    static let defaultChatModelKey = "macrodex.defaultChatModel"
    static let defaultImageModelKey = "macrodex.defaultImageModel"
    private static let reasoningEffortKey = "macrodex.reasoningEffort"
    private static let fixedApprovalPolicyValue = "never"
    private static let fixedSandboxModeValue = "danger-full-access"
    private static let inheritPermissionValue = "inherit"
    private static let customPermissionValue = "custom"

    var currentCwd = ""
    var collapsedSessionFolders: Set<String> = []
    var sessionsSelectedServerFilterId: String?
    var sessionsShowOnlyForks = false
    var sessionsWorkspaceSortModeRaw = "mostRecent"
    var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: Self.selectedModelKey)
        }
    }
    var defaultChatModel: String {
        didSet {
            UserDefaults.standard.set(defaultChatModel, forKey: Self.defaultChatModelKey)
        }
    }
    var defaultImageModel: String {
        didSet {
            UserDefaults.standard.set(defaultImageModel, forKey: Self.defaultImageModelKey)
        }
    }
    var reasoningEffort: String {
        didSet {
            UserDefaults.standard.set(reasoningEffort, forKey: Self.reasoningEffortKey)
        }
    }
    /// Collaboration mode the user picked before a thread exists (on the
    /// home composer). Applied to the first `startThread` via
    /// `setThreadCollaborationMode` immediately after creation.
    var pendingCollaborationMode: AppModeKind = .default
    var showModelSelector = false
    var showSettings = false
    var pendingThreadNavigation: ThreadKey?
    var pendingComposerAutofocusThread: ThreadKey?
    var homeComposerFocusRequestID = 0
    private var threadPermissionOverrides: [String: ThreadPermissionOverride] = [:]
    var approvalPolicy: String {
        didSet {
            UserDefaults.standard.set(approvalPolicy, forKey: Self.approvalPolicyKey)
        }
    }
    var sandboxMode: String {
        didSet {
            UserDefaults.standard.set(sandboxMode, forKey: Self.sandboxModeKey)
        }
    }

    init() {
        let storedSelectedModel = UserDefaults.standard.string(forKey: Self.selectedModelKey) ?? ""
        selectedModel = storedSelectedModel.localizedCaseInsensitiveContains("spark") ? "" : storedSelectedModel
        defaultChatModel = UserDefaults.standard.string(forKey: Self.defaultChatModelKey) ?? "gpt-5.4-mini"
        defaultImageModel = UserDefaults.standard.string(forKey: Self.defaultImageModelKey) ?? "gpt-5.4"
        reasoningEffort = UserDefaults.standard.string(forKey: Self.reasoningEffortKey) ?? ""
        approvalPolicy = Self.fixedApprovalPolicyValue
        sandboxMode = Self.fixedSandboxModeValue
        UserDefaults.standard.set(approvalPolicy, forKey: Self.approvalPolicyKey)
        UserDefaults.standard.set(sandboxMode, forKey: Self.sandboxModeKey)
    }

    func toggleSessionFolder(_ folderPath: String) {
        if collapsedSessionFolders.contains(folderPath) {
            collapsedSessionFolders.remove(folderPath)
        } else {
            collapsedSessionFolders.insert(folderPath)
        }
    }

    func isSessionFolderCollapsed(_ folderPath: String) -> Bool {
        collapsedSessionFolders.contains(folderPath)
    }

    func requestComposerAutofocus(for key: ThreadKey) {
        pendingComposerAutofocusThread = key
    }

    func consumeComposerAutofocus(for key: ThreadKey) {
        guard pendingComposerAutofocusThread == key else { return }
        pendingComposerAutofocusThread = nil
    }

    func requestHomeComposerFocus() {
        homeComposerFocusRequestID &+= 1
    }

    func approvalPolicy(for threadKey: ThreadKey?) -> String {
        Self.fixedApprovalPolicyValue
    }

    func sandboxMode(for threadKey: ThreadKey?) -> String {
        Self.fixedSandboxModeValue
    }

    func launchApprovalPolicy(for threadKey: ThreadKey?) -> AppAskForApproval? {
        AppAskForApproval(wireValue: Self.fixedApprovalPolicyValue)
    }

    func launchSandboxMode(for threadKey: ThreadKey?) -> AppSandboxMode? {
        AppSandboxMode(wireValue: Self.fixedSandboxModeValue)
    }

    func turnSandboxPolicy(for threadKey: ThreadKey?) -> AppSandboxPolicy? {
        TurnSandboxPolicy(mode: Self.fixedSandboxModeValue)?.ffiValue
    }

    func setPermissions(approvalPolicy: String, sandboxMode: String, for threadKey: ThreadKey?) {
        self.approvalPolicy = Self.fixedApprovalPolicyValue
        self.sandboxMode = Self.fixedSandboxModeValue

        guard let threadKey else { return }

        threadPermissionOverrides[permissionKey(for: threadKey)] = ThreadPermissionOverride(
            approvalPolicy: Self.fixedApprovalPolicyValue,
            sandboxMode: Self.fixedSandboxModeValue,
            isUserOverride: true,
            rawApprovalPolicy: AppAskForApproval(wireValue: Self.fixedApprovalPolicyValue),
            rawSandboxPolicy: TurnSandboxPolicy(mode: Self.fixedSandboxModeValue)?.ffiValue
        )
    }

    func hydratePermissions(from thread: AppThreadSnapshot?) {
        approvalPolicy = Self.fixedApprovalPolicyValue
        sandboxMode = Self.fixedSandboxModeValue
    }

    private func permissionKey(for threadKey: ThreadKey) -> String {
        "\(threadKey.serverId)/\(threadKey.threadId)"
    }

    private func displayValue(for approvalPolicy: AppAskForApproval?) -> String {
        guard let approvalPolicy else { return Self.inheritPermissionValue }
        return approvalPolicy.launchOverrideWireValue ?? Self.customPermissionValue
    }

    private func displayValue(for sandboxPolicy: AppSandboxPolicy?) -> String {
        guard let sandboxPolicy else { return Self.inheritPermissionValue }
        return sandboxPolicy.launchOverrideModeWireValue ?? Self.customPermissionValue
    }
}
