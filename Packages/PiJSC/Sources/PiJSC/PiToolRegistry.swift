import Foundation

public struct PiToolRegistration {
    public var definition: PiToolDefinition
    public var runner: any PiToolRunner

    public init(definition: PiToolDefinition, runner: any PiToolRunner) {
        self.definition = definition
        self.runner = runner
    }
}

public final class PiToolRegistry {
    private var registrationsByName: [String: PiToolRegistration] = [:]

    public init() {}

    public var definitions: [PiToolDefinition] {
        registrationsByName.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    public func register(
        _ definition: PiToolDefinition,
        runner: any PiToolRunner
    ) {
        registrationsByName[definition.name] = PiToolRegistration(
            definition: definition,
            runner: runner
        )
    }

    public func install(on runtime: PiJSCRuntime) {
        for registration in registrationsByName.values {
            runtime.registerTool(registration.runner, named: registration.definition.name)
        }
    }

    public func runner(named name: String) -> (any PiToolRunner)? {
        registrationsByName[name]?.runner
    }

    public static func defaultLocalTools(
        databaseURL: URL,
        requiredSQLCommentMarker: String? = nil,
        webSearchRunner: PiWebSearchToolRunner? = nil
    ) -> PiToolRegistry {
        let registry = PiToolRegistry()
        let sqlRunner = PiSQLiteToolRunner(
            databaseURL: databaseURL,
            requiredLeadingCommentMarker: requiredSQLCommentMarker
        )
        registry.register(PiBuiltInToolDefinitions.sql, runner: sqlRunner)
        registry.register(PiBuiltInToolDefinitions.jsc, runner: PiJSCScriptToolRunner(sqlRunner: sqlRunner))
        registry.register(PiBuiltInToolDefinitions.webSearch, runner: webSearchRunner ?? PiWebSearchToolRunner())
        return registry
    }
}
