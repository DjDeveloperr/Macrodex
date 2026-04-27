import Foundation

enum CrossServerTools {
    static let listSessionsToolName = "list_sessions"

    /// Build the dynamic tool specs for local chat lookup.
    static func buildDynamicToolSpecs() -> [DynamicToolSpecParams] {
        [
            listSessionsSpec()
        ]
    }

    /// Returns true if the given tool name is a cross-server tool that
    /// should be rendered with rich formatting in the conversation timeline.
    static func isRichTool(_ toolName: String) -> Bool {
        switch toolName {
        case listSessionsToolName:
            return true
        default:
            return false
        }
    }

    private static func listSessionsSpec() -> DynamicToolSpecParams {
        DynamicToolSpecParams(
            name: listSessionsToolName,
            description: "List recent chats on this iPhone. After calling this tool, briefly tell the user what you found.",
            inputSchema: AnyEncodable(JSONSchema.object([:], required: []))
        )
    }
}
