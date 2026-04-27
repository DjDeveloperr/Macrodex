import Foundation

protocol AgentRuntimeBackend: AnyObject, Sendable {
    var store: AppStore { get }
    var client: AppClient { get }
    var serverBridge: ServerBridge { get }

    func startAsync()
    func waitUntilReady() async
    func defaultCwd() async -> String
    func prewarm()
}

enum AgentRuntimeBootstrap {
    static func startAsync() {
        PiAgentRuntimeBackend.shared.startAsync()
    }

    static func waitUntilReady() async {
        await PiAgentRuntimeBackend.shared.waitUntilReady()
    }

    static func defaultCwd() async -> String {
        await PiAgentRuntimeBackend.shared.defaultCwd()
    }

    static func prewarm() {
        PiAgentRuntimeBackend.shared.prewarm()
    }
}
