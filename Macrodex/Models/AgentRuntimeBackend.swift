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
        MacrodexAgentRuntimeBackend.shared.startAsync()
    }

    static func waitUntilReady() async {
        await MacrodexAgentRuntimeBackend.shared.waitUntilReady()
    }

    static func defaultCwd() async -> String {
        await MacrodexAgentRuntimeBackend.shared.defaultCwd()
    }

    static func prewarm() {
        MacrodexAgentRuntimeBackend.shared.prewarm()
    }
}
