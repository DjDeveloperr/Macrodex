import Foundation
import Observation

@MainActor
@Observable
final class AppRuntimeController {
    static let shared = AppRuntimeController()

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var voiceRuntime: VoiceRuntimeController?
    @ObservationIgnored private let lifecycle = AppLifecycleController()

    func bind(appModel: AppModel, voiceRuntime: VoiceRuntimeController) {
        self.appModel = appModel
        self.voiceRuntime = voiceRuntime
    }

    func setDevicePushToken(_ token: Data) {
        lifecycle.setDevicePushToken(token)
    }

    func openThreadFromNotification(key: ThreadKey) async {
        guard let appModel else { return }
        LLog.info(
            "push",
            "runtime opening thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        lifecycle.markThreadOpenedFromNotification(key)
        appModel.activateThread(key)
        await appModel.refreshSnapshot()

        if let resolvedKey = await appModel.ensureThreadLoaded(key: key) {
            lifecycle.markThreadOpenedFromNotification(resolvedKey)
            LLog.info(
                "push",
                "notification thread resolved and activated",
                fields: ["serverId": resolvedKey.serverId, "threadId": resolvedKey.threadId]
            )
            appModel.activateThread(resolvedKey)
            await appModel.refreshSnapshot()
        } else {
            LLog.warn(
                "push",
                "notification thread could not be resolved",
                fields: ["serverId": key.serverId, "threadId": key.threadId]
            )
        }
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        _ = snapshot
    }

    func appDidEnterBackground() {
        guard let appModel else { return }
        lifecycle.appDidEnterBackground(
            snapshot: appModel.snapshot,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil
        )
    }

    func appDidBecomeInactive() {
    }

    func appDidBecomeActive() {
        guard let appModel else { return }
        lifecycle.appDidBecomeActive(
            appModel: appModel,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil
        )
    }

    func handleBackgroundPush() async {
        guard let appModel else { return }
        LLog.info("push", "runtime handling background push")
        await lifecycle.handleBackgroundPush(appModel: appModel)
        LLog.info("push", "runtime finished background push")
    }
}
