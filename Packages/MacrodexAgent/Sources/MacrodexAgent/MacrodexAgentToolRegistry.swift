import Foundation

public struct MacrodexAgentToolRegistration {
    public var definition: MacrodexAgentToolDefinition
    public var runner: any MacrodexAgentToolRunner

    public init(definition: MacrodexAgentToolDefinition, runner: any MacrodexAgentToolRunner) {
        self.definition = definition
        self.runner = runner
    }
}

public final class MacrodexAgentToolRegistry {
    private var registrationsByName: [String: MacrodexAgentToolRegistration] = [:]

    public init() {}

    public var definitions: [MacrodexAgentToolDefinition] {
        registrationsByName.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    public func register(
        _ definition: MacrodexAgentToolDefinition,
        runner: any MacrodexAgentToolRunner
    ) {
        registrationsByName[definition.name] = MacrodexAgentToolRegistration(
            definition: definition,
            runner: runner
        )
    }

    public func install(on runtime: MacrodexAgentRuntime) {
        for registration in registrationsByName.values {
            runtime.registerTool(registration.runner, named: registration.definition.name)
        }
    }

    public func runner(named name: String) -> (any MacrodexAgentToolRunner)? {
        registrationsByName[name]?.runner
    }

    public static func defaultLocalTools(
        databaseURL: URL,
        requiredSQLCommentMarker: String? = nil,
        webSearchRunner: MacrodexAgentWebSearchToolRunner? = nil
    ) -> MacrodexAgentToolRegistry {
        let registry = MacrodexAgentToolRegistry()
        let sqlRunner = MacrodexAgentSQLiteToolRunner(
            databaseURL: databaseURL,
            requiredLeadingCommentMarker: requiredSQLCommentMarker
        )
        registry.register(MacrodexAgentBuiltInToolDefinitions.sql, runner: sqlRunner)
        registry.register(MacrodexAgentBuiltInToolDefinitions.jsc, runner: MacrodexAgentScriptToolRunner(sqlRunner: sqlRunner))
        registry.register(MacrodexAgentBuiltInToolDefinitions.webSearch, runner: webSearchRunner ?? MacrodexAgentWebSearchToolRunner())
        return registry
    }
}
