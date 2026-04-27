import XCTest
@testable import PiJSC

final class PiJSCTests: XCTestCase {
    func testCapabilitiesComeFromEmbeddedJavaScriptRuntime() throws {
        let runtime = try PiJSCRuntime()

        let capabilities = try runtime.capabilities()

        XCTAssertEqual(capabilities.runtime, "PiJSC")
        XCTAssertEqual(capabilities.engine, "JavaScriptCore")
        XCTAssertTrue(capabilities.supportsPersistentThreads)
        XCTAssertTrue(capabilities.supportsNativeProviderHooks)
        XCTAssertTrue(capabilities.supportsNativeToolHooks)
        XCTAssertTrue(capabilities.supportsEventStreaming)
        XCTAssertTrue(capabilities.supportsThreadSnapshots)
        XCTAssertTrue(capabilities.supportsModelCatalogs)
    }

    func testBuiltInProviderRegistryIncludesFutureProviderTargets() {
        let ids = Set(PiBuiltInProviderRegistry.all.map(\.id))

        XCTAssertTrue(ids.contains("openai"))
        XCTAssertTrue(ids.contains("anthropic"))
        XCTAssertTrue(ids.contains("google"))
        XCTAssertTrue(ids.contains("openai_compatible"))
        XCTAssertTrue(PiBuiltInProviderRegistry.openAI.supportsChatGPTAuth)
    }

    func testBuiltInToolSchemasAreProviderCompatible() throws {
        let tools = [
            PiBuiltInToolDefinitions.title,
            PiBuiltInToolDefinitions.sql,
            PiBuiltInToolDefinitions.jsc,
            PiBuiltInToolDefinitions.webSearch
        ]

        for tool in tools {
            let errors = providerSchemaCompatibilityErrors(in: tool.inputSchema, path: tool.name)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        }
    }

    func testSingleProviderTurnProducesFinalMessage() throws {
        let runtime = try PiJSCRuntime()
        let provider = ScriptedProvider(responses: [
            PiProviderResponse(
                message: PiMessage(role: .assistant, content: "Hello from PiJSC."),
                usage: PiUsage(inputTokens: 10, outputTokens: 7, totalTokens: 17)
            )
        ])
        runtime.registerProvider(provider, for: "openai")

        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "Say hello",
                providerID: "openai",
                model: "gpt-test"
            )
        )

        XCTAssertEqual(result.finalMessage?.content, "Hello from PiJSC.")
        XCTAssertEqual(result.usage?.totalTokens, 17)
        XCTAssertEqual(provider.requests.first?.providerID, "openai")
        XCTAssertEqual(provider.requests.first?.model, "gpt-test")
        XCTAssertEqual(provider.requests.first?.messages.last?.content, "Say hello")
        XCTAssertTrue(result.events.contains { $0.type == "turn.started" })
        XCTAssertTrue(result.events.contains { $0.type == "turn.completed" })
    }

    func testToolCallRoundTripsThroughNativeSwiftAndContinuesTurn() throws {
        let runtime = try PiJSCRuntime()
        var requests: [PiProviderRequest] = []

        runtime.registerProvider(id: "openai") { request in
            requests.append(request)

            if requests.count == 1 {
                return PiProviderResponse(
                    toolCalls: [
                        PiToolCall(
                            id: "call-sum",
                            name: "sum",
                            arguments: [
                                "a": 2,
                                "b": 3
                            ]
                        )
                    ]
                )
            }

            XCTAssertEqual(request.messages.last?.role, .tool)
            XCTAssertEqual(request.messages.last?.name, "sum")
            XCTAssertEqual(request.messages.last?.toolCallID, "call-sum")
            XCTAssertEqual(request.messages.last?.content, "{\"sum\":5}")
            return PiProviderResponse(
                message: PiMessage(role: .assistant, content: "The sum is 5.")
            )
        }

        runtime.registerTool(name: "sum") { call in
            XCTAssertEqual(call.arguments.objectValue?["a"], 2)
            XCTAssertEqual(call.arguments.objectValue?["b"], 3)
            return PiToolResult(
                callID: call.id,
                output: [
                    "sum": 5
                ]
            )
        }

        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "Add 2 and 3",
                providerID: "openai",
                model: "gpt-test",
                tools: [
                    PiToolDefinition(
                        name: "sum",
                        description: "Adds two numbers.",
                        inputSchema: [
                            "type": "object",
                            "required": ["a", "b"]
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(result.finalMessage?.content, "The sum is 5.")
        XCTAssertTrue(result.events.contains { $0.type == "tool.started" })
        XCTAssertTrue(result.events.contains { $0.type == "tool.completed" })
        let startedEvent = try XCTUnwrap(result.events.first { $0.type == "tool.started" })
        XCTAssertEqual(startedEvent.payload["arguments"]?.objectValue?["a"]?.numberValue, 2)
    }

    func testToolCallsCanExceedLegacyRoundLimit() throws {
        let runtime = try PiJSCRuntime()
        var requestCount = 0

        runtime.registerProvider(id: "openai") { _ in
            requestCount += 1
            if requestCount <= 5 {
                return PiProviderResponse(
                    toolCalls: [
                        PiToolCall(
                            id: "call-\(requestCount)",
                            name: "echo",
                            arguments: ["round": .number(Double(requestCount))]
                        )
                    ]
                )
            }
            return PiProviderResponse(
                message: PiMessage(role: .assistant, content: "done")
            )
        }

        runtime.registerTool(name: "echo") { call in
            PiToolResult(callID: call.id, output: call.arguments)
        }

        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "loop tools",
                providerID: "openai",
                model: "gpt-test",
                maxToolRounds: 1
            )
        )

        XCTAssertEqual(result.finalMessage?.content, "done")
        XCTAssertEqual(result.events.last(where: { $0.type == "turn.completed" })?.payload["tool_rounds"]?.numberValue, 5)
    }

    func testRuntimeSuppressesDuplicateWebSearchesWithinTurn() throws {
        let runtime = try PiJSCRuntime()
        var requestCount = 0
        var webSearchRunCount = 0

        runtime.registerProvider(id: "openai") { _ in
            requestCount += 1
            if requestCount <= 2 {
                return PiProviderResponse(
                    toolCalls: [
                        PiToolCall(
                            id: "search-\(requestCount)",
                            name: "web_search",
                            arguments: ["query": "Quaker rice cakes macros"]
                        )
                    ]
                )
            }
            return PiProviderResponse(message: PiMessage(role: .assistant, content: "done"))
        }

        runtime.registerTool(name: "web_search") { call in
            webSearchRunCount += 1
            return PiToolResult(
                callID: call.id,
                output: [
                    "query": call.arguments.objectValue?["query"] ?? .string(""),
                    "results": .array([])
                ]
            )
        }

        let result = try runtime.runTurn(
            PiTurnRequest(prompt: "macros", providerID: "openai", model: "gpt-test")
        )

        XCTAssertEqual(result.finalMessage?.content, "done")
        XCTAssertEqual(webSearchRunCount, 1)
        XCTAssertTrue(result.messages.contains { message in
            message.role == .tool && message.content.contains(#""duplicate":true"#)
        })
    }

    func testRuntimeHonorsCancellationBetweenToolRounds() throws {
        let runtime = try PiJSCRuntime()
        var shouldCancel = false

        runtime.registerProvider(id: "openai") { _ in
            PiProviderResponse(
                toolCalls: [
                    PiToolCall(id: "call", name: "noop", arguments: [:])
                ]
            )
        }
        runtime.registerTool(name: "noop") { call in
            shouldCancel = true
            return PiToolResult(callID: call.id, output: [:])
        }

        XCTAssertThrowsError(
            try runtime.runTurn(
                PiTurnRequest(prompt: "cancel", providerID: "openai", model: "gpt-test"),
                eventHandler: nil,
                shouldCancel: { shouldCancel }
            )
        ) { error in
            guard case PiRuntimeError.javaScriptException(let message) = error else {
                return XCTFail("Expected JavaScript cancellation, got \(error)")
            }
            XCTAssertTrue(message.contains("Turn cancelled"))
        }
    }

    func testThreadIDContinuesMessageHistoryAcrossTurns() throws {
        let runtime = try PiJSCRuntime()
        var requests: [PiProviderRequest] = []

        runtime.registerProvider(id: "openai") { request in
            requests.append(request)
            return PiProviderResponse(
                message: PiMessage(role: .assistant, content: "turn \(requests.count)")
            )
        }

        let first = try runtime.runTurn(
            PiTurnRequest(
                prompt: "First",
                providerID: "openai",
                model: "gpt-test"
            )
        )
        let second = try runtime.runTurn(
            PiTurnRequest(
                threadID: first.threadID,
                prompt: "Second",
                providerID: "openai",
                model: "gpt-test"
            )
        )

        XCTAssertEqual(second.threadID, first.threadID)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].messages.map(\.content),
            ["First", "turn 1", "Second"]
        )
    }

    private func providerSchemaCompatibilityErrors(in value: PiJSONValue, path: String) -> [String] {
        switch value {
        case .object(let object):
            var errors: [String] = []
            if object["type"]?.stringValue == "array", object["items"] == nil {
                errors.append("\(path): array schema is missing items")
            }
            for (key, child) in object {
                errors.append(contentsOf: providerSchemaCompatibilityErrors(in: child, path: "\(path).\(key)"))
            }
            return errors
        case .array(let array):
            return array.enumerated().flatMap { index, child in
                providerSchemaCompatibilityErrors(in: child, path: "\(path)[\(index)]")
            }
        case .null, .bool, .number, .string:
            return []
        }
    }

    func testMissingProviderSurfacesAsJavaScriptRuntimeError() throws {
        let runtime = try PiJSCRuntime()

        XCTAssertThrowsError(
            try runtime.runTurn(
                PiTurnRequest(
                    prompt: "Hello",
                    providerID: "missing",
                    model: "test"
                )
            )
        ) { error in
            guard case PiRuntimeError.javaScriptException(let message) = error else {
                return XCTFail("Expected a JavaScript exception, got \(error)")
            }

            XCTAssertTrue(message.contains("Provider not registered: missing"))
        }
    }

    func testCodexChatGPTProviderMapsResponsesSSEIntoPiResponse() throws {
        let transport = RecordingTransport(
            statusCode: 200,
            body: """
            data: {"type":"response.output_text.delta","delta":"PiJSC "}

            data: {"type":"response.output_text.delta","delta":"OK"}

            data: {"type":"response.completed","response":{"id":"resp_test","usage":{"input_tokens":4,"input_tokens_details":{"cached_tokens":1},"output_tokens":2,"total_tokens":6}}}

            """
        )
        let provider = PiCodexChatGPTProvider(
            auth: PiCodexAuth(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                accountID: "account-id"
            ),
            transport: transport
        )

        let response = try provider.complete(
            PiProviderRequest(
                threadID: "thread-test",
                providerID: "openai",
                model: "gpt-test",
                messages: [
                    PiMessage(role: .system, content: "System instructions"),
                    PiMessage(role: .user, content: "Say OK")
                ],
                metadata: [
                    "source": "unit-test"
                ]
            )
        )

        XCTAssertEqual(response.message?.content, "PiJSC OK")
        XCTAssertEqual(response.outputDeltas, ["PiJSC ", "OK"])
        XCTAssertEqual(response.usage?.cachedInputTokens, 1)
        XCTAssertEqual(response.usage?.totalTokens, 6)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-id")

        let body = try XCTUnwrap(transport.requestBodies.first)
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertEqual(body["instructions"] as? String, "System instructions")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
    }

    func testCodexChatGPTProviderSendsImagesAsImageInputs() throws {
        let transport = RecordingTransport(
            statusCode: 200,
            body: """
            data: {"type":"response.output_text.delta","delta":"Seen"}

            data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

            """
        )
        let provider = PiCodexChatGPTProvider(
            auth: PiCodexAuth(accessToken: "access-token", accountID: "account-id"),
            transport: transport
        )
        let imageURL = "data:image/jpeg;base64,abc123"

        _ = try provider.complete(
            PiProviderRequest(
                threadID: "thread-image",
                providerID: "openai",
                model: "gpt-test",
                messages: [
                    PiMessage(role: .user, content: "What is this?", imageURLs: [imageURL])
                ]
            )
        )

        let body = try XCTUnwrap(transport.requestBodies.first)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let message = try XCTUnwrap(input.first)
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "What is this?")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image_url"] as? String, imageURL)
    }

    func testPiMessageDecodesLegacyMessagesWithoutImageURLs() throws {
        let data = #"{"role":"user","content":"hello"}"#.data(using: .utf8)!

        let message = try JSONDecoder().decode(PiMessage.self, from: data)

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "hello")
        XCTAssertTrue(message.imageURLs.isEmpty)
    }

    func testCodexChatGPTProviderSendsFunctionCallContinuationItems() throws {
        let transport = RecordingTransport(
            statusCode: 200,
            body: """
            data: {"type":"response.output_text.delta","delta":"Done"}

            data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

            """
        )
        let provider = PiCodexChatGPTProvider(
            auth: PiCodexAuth(accessToken: "access-token", accountID: "account-id"),
            transport: transport
        )

        _ = try provider.complete(
            PiProviderRequest(
                threadID: "thread-tools",
                providerID: "openai",
                model: "gpt-test",
                messages: [
                    PiMessage(role: .user, content: "Use a tool"),
                    PiMessage(
                        role: .assistant,
                        content: "",
                        toolCalls: [
                            PiToolCall(
                                id: "call-1",
                                name: "sql",
                                arguments: ["statement": "SELECT 1"]
                            )
                        ]
                    ),
                    PiMessage(role: .tool, content: "{\"ok\":true}", name: "sql", toolCallID: "call-1")
                ]
            )
        )

        let body = try XCTUnwrap(transport.requestBodies.first)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["message", "function_call", "function_call_output"])
        XCTAssertEqual(input[1]["call_id"] as? String, "call-1")
        XCTAssertEqual(input[1]["name"] as? String, "sql")
        let arguments = try XCTUnwrap(input[1]["arguments"] as? String)
        let argumentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
        )
        XCTAssertEqual(argumentObject["statement"] as? String, "SELECT 1")
        XCTAssertEqual(input[2]["call_id"] as? String, "call-1")
    }

    func testGoogleAIProviderSendsImagesToolsAndToolResponses() throws {
        let transport = RecordingTransport(
            statusCode: 200,
            body: """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {"text": "Done"}
                    ]
                  }
                }
              ],
              "usageMetadata": {"promptTokenCount": 2, "candidatesTokenCount": 3, "totalTokenCount": 5}
            }
            """
        )
        let provider = PiGoogleAIProvider(apiKey: "google-key", transport: transport)

        let response = try provider.complete(
            PiProviderRequest(
                threadID: "thread-google",
                providerID: "google",
                model: "google/gemini-2.5-flash",
                messages: [
                    PiMessage(role: .system, content: "Be brief."),
                    PiMessage(role: .user, content: "What is this?", imageURLs: ["data:image/png;base64,abc123"]),
                    PiMessage(role: .assistant, content: "", toolCalls: [
                        PiToolCall(id: "call-1", name: "sql", arguments: ["purpose": "Checking meals"])
                    ]),
                    PiMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "call-1")
                ],
                tools: [
                    PiToolDefinition(
                        name: "sql",
                        description: "Run SQL",
                        inputSchema: [
                            "type": "object",
                            "properties": [
                                "purpose": ["type": "string"],
                                "statement": ["type": "string"]
                            ],
                            "required": ["purpose"]
                        ]
                    )
                ],
                metadata: ["reasoning_effort": "low"]
            )
        )

        XCTAssertEqual(response.message?.content, "Done")
        XCTAssertEqual(response.usage?.totalTokens, 5)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "x-goog-api-key"), "google-key")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")

        let body = try XCTUnwrap(transport.requestBodies.first)
        let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        let systemParts = try XCTUnwrap(system["parts"] as? [[String: Any]])
        XCTAssertEqual(systemParts.first?["text"] as? String, "Be brief.")

        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 3)
        let userParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(userParts[0]["text"] as? String, "What is this?")
        let inlineData = try XCTUnwrap(userParts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/png")
        XCTAssertEqual(inlineData["data"] as? String, "abc123")

        let assistantParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(assistantParts.first?["functionCall"] as? [String: Any])
        XCTAssertEqual(functionCall["name"] as? String, "sql")

        let toolParts = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try XCTUnwrap(toolParts.first?["functionResponse"] as? [String: Any])
        XCTAssertEqual(functionResponse["name"] as? String, "sql")

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["name"] as? String, "sql")
    }

    func testGoogleAIProviderParsesFunctionCalls() throws {
        let transport = RecordingTransport(
            statusCode: 200,
            body: """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "functionCall": {
                          "name": "log_food",
                          "args": {"name": "Greek yogurt", "meal_type": "snack"}
                        }
                      }
                    ]
                  }
                }
              ]
            }
            """
        )
        let provider = PiGoogleAIProvider(apiKey: "google-key", transport: transport)

        let response = try provider.complete(
            PiProviderRequest(
                threadID: "thread-google-tools",
                providerID: "google",
                model: "google/gemini-2.5-flash",
                messages: [PiMessage(role: .user, content: "Log yogurt")]
            )
        )

        XCTAssertNil(response.message)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "log_food")
        XCTAssertEqual(response.toolCalls[0].arguments["name"]?.stringValue, "Greek yogurt")
        XCTAssertEqual(response.toolCalls[0].arguments["meal_type"]?.stringValue, "snack")
    }

    func testLiveCodexChatGPTProviderEndToEndWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["PIJSC_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Set PIJSC_LIVE_CODEX=1 to run the live Codex ChatGPT smoke test.")
        }

        let runtime = try PiJSCRuntime()
        runtime.registerProvider(try PiCodexChatGPTProvider(), for: "openai")

        let model = ProcessInfo.processInfo.environment["PIJSC_LIVE_MODEL"] ?? "gpt-5.4"
        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "Return exactly this text and nothing else: PiJSC OK",
                providerID: "openai",
                model: model,
                instructions: "You are a smoke-test responder. Return only the literal requested text."
            )
        )

        let final = try XCTUnwrap(result.finalMessage?.content)
        XCTAssertTrue(
            final.localizedCaseInsensitiveContains("PiJSC OK"),
            "Expected live response to contain PiJSC OK, got: \(final)"
        )
    }

    func testLiveCodexChatGPTProviderToolLoopWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["PIJSC_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Set PIJSC_LIVE_CODEX=1 to run the live Codex ChatGPT tool-loop smoke test.")
        }

        let runtime = try PiJSCRuntime()
        runtime.registerProvider(try PiCodexChatGPTProvider(), for: "openai")
        runtime.registerTool(name: "echo") { call in
            PiToolResult(
                callID: call.id,
                output: [
                    "text": call.arguments["text"] ?? "missing"
                ]
            )
        }

        let model = ProcessInfo.processInfo.environment["PIJSC_LIVE_MODEL"] ?? "gpt-5.4"
        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "Call the echo tool exactly once with text `PiJSC TOOL OK`, then respond with `FINAL: PiJSC TOOL OK`.",
                providerID: "openai",
                model: model,
                tools: [
                    PiToolDefinition(
                        name: "echo",
                        description: "Echoes a text field.",
                        inputSchema: [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"]
                            ],
                            "required": ["text"]
                        ]
                    )
                ],
                instructions: "You must use the provided echo tool before giving the final answer."
            )
        )

        let final = try XCTUnwrap(result.finalMessage?.content)
        XCTAssertTrue(result.events.contains { $0.type == "tool.completed" })
        XCTAssertTrue(
            final.localizedCaseInsensitiveContains("FINAL: PiJSC TOOL OK"),
            "Expected final tool-loop response, got: \(final)"
        )
    }

    func testRuntimeEventHandlerReceivesProviderOutputDeltas() throws {
        let runtime = try PiJSCRuntime()
        runtime.registerProvider(id: "openai") { _ in
            PiProviderResponse(
                message: PiMessage(role: .assistant, content: "Hello"),
                outputDeltas: ["Hel", "lo"]
            )
        }

        var streamedEvents: [PiRuntimeEvent] = []
        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "Say hello",
                providerID: "openai",
                model: "gpt-test"
            ),
            eventHandler: { streamedEvents.append($0) }
        )

        XCTAssertEqual(result.finalMessage?.content, "Hello")
        XCTAssertEqual(
            streamedEvents.filter { $0.type == "message.delta" }.compactMap { $0.payload["delta"]?.stringValue },
            ["Hel", "lo"]
        )
        XCTAssertTrue(streamedEvents.contains { $0.type == "turn.started" })
        XCTAssertTrue(streamedEvents.contains { $0.type == "turn.completed" })
    }

    func testThreadSnapshotsListReadDeleteAndStateRoundTrip() throws {
        let runtime = try PiJSCRuntime()
        runtime.registerProvider(id: "openai") { request in
            PiProviderResponse(
                message: PiMessage(role: .assistant, content: "reply to \(request.messages.last?.content ?? "")")
            )
        }

        let first = try runtime.runTurn(
            PiTurnRequest(prompt: "First", providerID: "openai", model: "gpt-test")
        )
        _ = try runtime.runTurn(
            PiTurnRequest(threadID: first.threadID, prompt: "Second", providerID: "openai", model: "gpt-test")
        )

        let listed = try runtime.listThreads()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, first.threadID)
        XCTAssertEqual(listed[0].messageCount, 4)

        let snapshot = try XCTUnwrap(try runtime.threadSnapshot(threadID: first.threadID))
        XCTAssertEqual(snapshot.messages?.map(\.content), ["First", "reply to First", "Second", "reply to Second"])

        let exported = try runtime.exportState()
        let imported = try PiJSCRuntime()
        try imported.importState(exported)
        XCTAssertEqual(try imported.listThreads().first?.messageCount, 4)

        XCTAssertTrue(try runtime.deleteThread(threadID: first.threadID))
        XCTAssertTrue(try runtime.listThreads().isEmpty)
    }

    func testRuntimeStateCanPersistToDiskAndReload() throws {
        let runtime = try PiJSCRuntime()
        runtime.registerProvider(id: "openai") { _ in
            PiProviderResponse(message: PiMessage(role: .assistant, content: "persisted"))
        }
        let result = try runtime.runTurn(
            PiTurnRequest(prompt: "Save me", providerID: "openai", model: "gpt-test")
        )
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pi-state.json")

        try runtime.saveState(to: stateURL)
        let restored = try PiJSCRuntime(loadingStateFrom: stateURL)
        let snapshot = try XCTUnwrap(try restored.threadSnapshot(threadID: result.threadID))

        XCTAssertEqual(snapshot.messages?.map(\.content), ["Save me", "persisted"])
    }

    func testBuiltInModelCatalogSupportsPickerDefaults() throws {
        let runtime = try PiJSCRuntime()

        let models = runtime.availableModels(providerID: "openai")

        XCTAssertFalse(models.contains { $0.id == "gpt-5.3-codex-spark" })
        XCTAssertEqual(runtime.preferredModelID(providerID: "openai"), "gpt-5.4-mini")
        XCTAssertTrue(models.allSatisfy(\.supportsTools))
        XCTAssertTrue(models.allSatisfy(\.supportsChatGPTAuth))
    }

    func testSQLiteToolRunnerExecutesCommentedQueriesAndWrites() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiresLeadingComment: true
        )

        _ = try runner.runTool(
            PiToolCall(
                id: "setup",
                name: "sql",
                arguments: [
                    "statement": """
                    /* macrodex: Setting up foods */
                    CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL, calories REAL NOT NULL);
                    INSERT INTO foods (id, name, calories) VALUES ('eggs', 'Eggs', 140);
                    """,
                    "mode": "exec"
                ]
            )
        )

        let result = try runner.runTool(
            PiToolCall(
                id: "query",
                name: "sql",
                arguments: [
                    "statement": "-- macrodex: Checking foods\nSELECT name, calories FROM foods WHERE id = ?",
                    "bindings": ["eggs"]
                ]
            )
        )

        let rows = try XCTUnwrap(result.output.objectValue?["rows"]?.arrayValue)
        XCTAssertEqual(rows.first?.objectValue?["name"]?.stringValue, "Eggs")
        XCTAssertEqual(rows.first?.objectValue?["calories"]?.numberValue, 140)

        let badResult = try runner.runTool(
            PiToolCall(
                id: "bad",
                name: "sql",
                arguments: ["statement": "SELECT 1"]
            )
        )
        XCTAssertTrue(badResult.isError)
        XCTAssertEqual(badResult.output.objectValue?["recoverable"]?.boolValue, true)
        XCTAssertEqual(badResult.output.objectValue?["error"]?.stringValue, PiSQLiteToolError.missingLeadingComment.localizedDescription)
    }

    func testSQLiteToolRunnerCanRequireSpecificCommentMarker() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )

        XCTAssertNoThrow(
            try runner.exec("/* macrodex: Creating table */ CREATE TABLE items (name TEXT);")
        )
        XCTAssertThrowsError(
            try runner.exec("/* other: Creating table */ CREATE TABLE other_items (name TEXT);")
        ) { error in
            XCTAssertEqual(error as? PiSQLiteToolError, .missingRequiredCommentMarker("macrodex:"))
        }
    }

    func testSQLiteSchemaModeDoesNotRequireStatementAndReturnsForeignKeys() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec(
            """
            /* macrodex: Setting up recipes */
            CREATE TABLE food_library_items (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL);
            CREATE TABLE recipe_components (
                id TEXT PRIMARY KEY,
                recipe_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
                component_name TEXT NOT NULL
            );
            """
        )

        let result = try runner.runTool(
            PiToolCall(
                id: "schema",
                name: "sql",
                arguments: [
                    "purpose": "Checking schema",
                    "mode": "schema",
                    "tables": ["recipe_components"]
                ]
            )
        )

        XCTAssertFalse(result.isError)
        let table = try XCTUnwrap(result.output.objectValue?["tables"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(table["name"]?.stringValue, "recipe_components")
        let columns = try XCTUnwrap(table["columns"]?.arrayValue)
        XCTAssertTrue(columns.contains { $0.objectValue?["name"]?.stringValue == "recipe_id" })
        let foreignKeys = try XCTUnwrap(table["foreignKeys"]?.arrayValue)
        XCTAssertEqual(foreignKeys.first?.objectValue?["table"]?.stringValue, "food_library_items")
        XCTAssertEqual(result.output.objectValue?["purpose"]?.stringValue, "Checking schema")
        XCTAssertTrue(result.output.objectValue?["notes"]?.arrayValue?.contains(.string("recipe_components.recipe_id references food_library_items.id.")) == true)
    }

    func testSQLiteValidateModePreparesStatementWithoutExecutingIt() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")

        let validation = try runner.runTool(
            PiToolCall(
                id: "validate",
                name: "sql",
                arguments: [
                    "purpose": "Checking insert",
                    "mode": "validate",
                    "statement": "/* macrodex: Checking insert */ INSERT INTO foods (id, name) VALUES (?, ?)",
                    "bindings": ["eggs", "Eggs"]
                ]
            )
        )
        let countRows = try runner.query("/* macrodex: Counting foods */ SELECT COUNT(*) AS count FROM foods")

        XCTAssertEqual(validation.output.objectValue?["ok"]?.boolValue, true)
        XCTAssertEqual(validation.output.objectValue?["mode"]?.stringValue, "validate")
        XCTAssertEqual(validation.output.objectValue?["firstKeyword"]?.stringValue, "insert")
        XCTAssertEqual(validation.output.objectValue?["readOnly"]?.boolValue, false)
        XCTAssertEqual(countRows.first?.objectValue?["count"]?.numberValue, 0)
    }

    func testSQLiteErrorsIncludeActionableStructuredFeedback() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")

        let result = try runner.runTool(
            PiToolCall(
                id: "bad-update",
                name: "sql",
                arguments: [
                    "purpose": "Updating food",
                    "statement": "/* macrodex: Updating food */ UPDATE foods SET missing_column = 1 WHERE id = ?",
                    "bindings": ["eggs"]
                ]
            )
        )

        XCTAssertTrue(result.isError)
        let output = try XCTUnwrap(result.output.objectValue)
        XCTAssertEqual(output["ok"]?.boolValue, false)
        XCTAssertEqual(output["errorType"]?.stringValue, "sqlite")
        XCTAssertEqual(output["firstKeyword"]?.stringValue, "update")
        XCTAssertTrue(output["statementPreview"]?.stringValue?.contains("Updating food") == true)
        XCTAssertTrue(output["error"]?.stringValue?.contains("missing_column") == true)
        XCTAssertTrue(output["hint"]?.stringValue?.contains("db_transaction") == true)
    }

    func testSQLiteTransactionCommitsAtomicallyAndRollsBackOnFailure() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")

        let committed = try runner.transaction([
            PiSQLiteTransactionOperation(
                purpose: "Adding eggs",
                statement: "/* macrodex: Adding eggs */ INSERT INTO foods (id, name) VALUES (?, ?)",
                bindings: ["eggs", "Eggs"]
            ),
            PiSQLiteTransactionOperation(
                purpose: "Confirming eggs",
                statement: "/* macrodex: Confirming eggs */ SELECT name FROM foods WHERE id = ?",
                bindings: ["eggs"],
                mode: .query
            )
        ])

        XCTAssertEqual(committed.objectValue?["ok"]?.boolValue, true)
        let operations = try XCTUnwrap(committed.objectValue?["operations"]?.arrayValue)
        XCTAssertEqual(operations[0].objectValue?["changes"]?.numberValue, 1)
        XCTAssertEqual(operations[1].objectValue?["rows"]?.arrayValue?.first?.objectValue?["name"]?.stringValue, "Eggs")

        XCTAssertThrowsError(
            try runner.transaction([
                PiSQLiteTransactionOperation(
                    purpose: "Adding yogurt",
                    statement: "/* macrodex: Adding yogurt */ INSERT INTO foods (id, name) VALUES (?, ?)",
                    bindings: ["yogurt", "Greek yogurt"]
                ),
                PiSQLiteTransactionOperation(
                    purpose: "Breaking write",
                    statement: "/* macrodex: Breaking write */ INSERT INTO foods (missing_column) VALUES (?)",
                    bindings: ["nope"]
                )
            ])
        )
        let rows = try runner.query("/* macrodex: Checking rollback */ SELECT id FROM foods ORDER BY id")
        XCTAssertEqual(rows.map { $0.objectValue?["id"]?.stringValue }, ["eggs"])
    }

    func testSQLiteDryRunTransactionReturnsConfirmationsButDoesNotPersist() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")

        let result = try runner.transaction([
            PiSQLiteTransactionOperation(
                purpose: "Adding salmon",
                statement: "/* macrodex: Adding salmon */ INSERT INTO foods (id, name) VALUES (?, ?)",
                bindings: ["salmon", "Salmon"]
            ),
            PiSQLiteTransactionOperation(
                purpose: "Confirming salmon",
                statement: "/* macrodex: Confirming salmon */ SELECT name FROM foods WHERE id = ?",
                bindings: ["salmon"],
                mode: .query
            )
        ], dryRun: true)
        let persistedRows = try runner.query("/* macrodex: Checking foods */ SELECT id FROM foods")

        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["dryRun"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["operations"]?.arrayValue?[1].objectValue?["rowCount"]?.numberValue, 1)
        XCTAssertTrue(persistedRows.isEmpty)
    }

    func testSQLiteTransactionRejectsUnlabeledOperationBeforeWriting() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")

        XCTAssertThrowsError(
            try runner.transaction([
                PiSQLiteTransactionOperation(
                    purpose: "Adding eggs",
                    statement: "/* macrodex: Adding eggs */ INSERT INTO foods (id, name) VALUES (?, ?)",
                    bindings: ["eggs", "Eggs"]
                ),
                PiSQLiteTransactionOperation(
                    purpose: "Adding rice",
                    statement: "INSERT INTO foods (id, name) VALUES (?, ?)",
                    bindings: ["rice", "Rice bowl"]
                )
            ])
        ) { error in
            XCTAssertEqual(error as? PiSQLiteToolError, .missingLeadingComment)
        }

        let rows = try runner.query("/* macrodex: Checking foods */ SELECT id FROM foods")
        XCTAssertTrue(rows.isEmpty)
    }

    func testSQLiteTransactionParserAcceptsSQLAliasAndValidateMode() throws {
        let operationsValue: PiJSONValue = .array([
            .object([
                "purpose": "Checking insert",
                "sql": "/* macrodex: Checking insert */ INSERT INTO foods (id, name) VALUES (?, ?)",
                "bindings": ["rice", "Rice bowl"],
                "mode": "validate"
            ])
        ])

        let operations = try PiSQLiteToolRunner.transactionOperations(from: operationsValue)

        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0].purpose, "Checking insert")
        XCTAssertEqual(operations[0].statement, "/* macrodex: Checking insert */ INSERT INTO foods (id, name) VALUES (?, ?)")
        XCTAssertEqual(operations[0].bindings, ["rice", "Rice bowl"])
        XCTAssertEqual(operations[0].mode, .validate)
    }

    func testSQLiteTransactionsEnforceForeignKeysAndRollback() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec(
            """
            /* macrodex: Creating recipe tables */
            CREATE TABLE food_library_items (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL);
            CREATE TABLE recipe_components (
                id TEXT PRIMARY KEY,
                recipe_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
                component_name TEXT NOT NULL
            );
            """
        )

        XCTAssertThrowsError(
            try runner.transaction([
                PiSQLiteTransactionOperation(
                    purpose: "Adding component",
                    statement: "/* macrodex: Adding component */ INSERT INTO recipe_components (id, recipe_id, component_name) VALUES (?, ?, ?)",
                    bindings: ["component-1", "missing-recipe", "Eggs"]
                )
            ])
        )

        let rows = try runner.query("/* macrodex: Checking components */ SELECT id FROM recipe_components")
        XCTAssertTrue(rows.isEmpty)
    }

    func testSQLiteRunToolRejectsInvalidBindingsWithStructuredFeedback() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")

        let result = try runner.runTool(
            PiToolCall(
                id: "bad-bindings",
                name: "sql",
                arguments: [
                    "purpose": "Checking food",
                    "statement": "/* macrodex: Checking food */ SELECT name FROM foods WHERE id = ?",
                    "bindings": ["id": "eggs"]
                ]
            )
        )

        XCTAssertTrue(result.isError)
        let output = try XCTUnwrap(result.output.objectValue)
        XCTAssertEqual(output["ok"]?.boolValue, false)
        XCTAssertEqual(output["errorType"]?.stringValue, "validation")
        XCTAssertEqual(output["mode"]?.stringValue, "auto")
        XCTAssertEqual(output["firstKeyword"]?.stringValue, "select")
        XCTAssertTrue(output["hint"]?.stringValue?.contains("bindings as a JSON array") == true)
    }

    func testSQLiteAutoModeTreatsCTEAsQueryAndHonorsMaxRows() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:",
            maxRows: 2
        )
        _ = try runner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")
        _ = try runner.exec(
            """
            /* macrodex: Adding foods */
            INSERT INTO foods (id, name) VALUES ('eggs', 'Eggs');
            INSERT INTO foods (id, name) VALUES ('rice', 'Rice bowl');
            INSERT INTO foods (id, name) VALUES ('salmon', 'Salmon');
            """
        )

        let result = try runner.runTool(
            PiToolCall(
                id: "cte-query",
                name: "sql",
                arguments: [
                    "statement": """
                    /* macrodex: Listing foods */
                    WITH ordered AS (
                        SELECT name FROM foods ORDER BY name
                    )
                    SELECT name FROM ordered
                    """
                ]
            )
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output.objectValue?["mode"]?.stringValue, "query")
        XCTAssertEqual(result.output.objectValue?["rowCount"]?.numberValue, 2)
        XCTAssertEqual(
            result.output.objectValue?["rows"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue },
            ["Eggs", "Rice bowl"]
        )
    }

    func testSQLiteSchemaModeReturnsExistingKnownTablesWhenNotRequested() throws {
        let runner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try runner.exec(
            """
            /* macrodex: Creating food schema */
            CREATE TABLE unrelated (id TEXT PRIMARY KEY);
            CREATE TABLE food_log_items (id TEXT PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE recipe_components (id TEXT PRIMARY KEY, component_name TEXT NOT NULL);
            """
        )

        let schema = try runner.schema()
        let tableNames = schema.objectValue?["tables"]?.arrayValue?
            .compactMap { $0.objectValue?["name"]?.stringValue }

        XCTAssertEqual(tableNames, ["food_log_items", "recipe_components"])
        XCTAssertTrue(schema.objectValue?["notes"]?.arrayValue?.contains(.string("Recipes are food_library_items rows with kind='recipe'.")) == true)
    }

    func testJSCTransactionRollsBackWhenOperationFails() throws {
        let sqlRunner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try sqlRunner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")
        let runner = PiJSCScriptToolRunner(sqlRunner: sqlRunner)

        let result = try runner.runTool(
            PiToolCall(
                id: "script-failure",
                name: "jsc",
                arguments: [
                    "script": """
                    sql.transaction([
                      { purpose: "Adding eggs", statement: "/* macrodex: Adding eggs */ INSERT INTO foods (id, name) VALUES (?, ?)", bindings: ["eggs", "Eggs"] },
                      { purpose: "Breaking write", statement: "/* macrodex: Breaking write */ INSERT INTO foods (missing_column) VALUES (?)", bindings: ["nope"] }
                    ]);
                    """
                ]
            )
        )
        let rows = try sqlRunner.query("/* macrodex: Checking rollback */ SELECT id FROM foods")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.objectValue?["error"]?.stringValue?.contains("missing_column") == true)
        XCTAssertTrue(rows.isEmpty)
    }

    func testJSCRequiresLabeledSQLBeforeWriting() throws {
        let sqlRunner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try sqlRunner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")
        let runner = PiJSCScriptToolRunner(sqlRunner: sqlRunner)

        let result = try runner.runTool(
            PiToolCall(
                id: "script-unlabeled-sql",
                name: "jsc",
                arguments: [
                    "script": """
                    db.exec("INSERT INTO foods (id, name) VALUES (?, ?)", ["eggs", "Eggs"]);
                    """
                ]
            )
        )
        let rows = try sqlRunner.query("/* macrodex: Checking foods */ SELECT id FROM foods")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.objectValue?["error"]?.stringValue?.contains("SQL statement must start") == true)
        XCTAssertTrue(rows.isEmpty)
    }

    func testJSCToolRunnerCanScriptSQLite() throws {
        let sqlRunner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiresLeadingComment: true
        )
        _ = try sqlRunner.exec(
            """
            /* macrodex: Setting up logs */
            CREATE TABLE logs (id TEXT PRIMARY KEY, name TEXT NOT NULL, calories REAL NOT NULL);
            """
        )
        let runner = PiJSCScriptToolRunner(sqlRunner: sqlRunner)

        let result = try runner.runTool(
            PiToolCall(
                id: "script",
                name: "jsc",
                arguments: [
                    "script": """
                    const id = crypto.randomUUID();
                    sql.exec("/* macrodex: Logging snack */ INSERT INTO logs (id, name, calories) VALUES (?, ?, ?)", [id, "Banana", 105]);
                    const rows = sql.query("/* macrodex: Checking snack */ SELECT name, calories FROM logs WHERE id = ?", [id]);
                    console.log(rows[0].name + " " + rows[0].calories);
                    rows[0];
                    """
                ]
            )
        )

        let output = try XCTUnwrap(result.output.objectValue)
        XCTAssertEqual(output["stdout"]?.stringValue, "Banana 105")
        XCTAssertEqual(output["result"]?.objectValue?["name"]?.stringValue, "Banana")
        XCTAssertEqual(output["result"]?.objectValue?["calories"]?.numberValue, 105)
    }

    func testJSCToolRunnerExposesSchemaValidateAndAtomicTransactionHelpers() throws {
        let sqlRunner = PiSQLiteToolRunner(
            databaseURL: temporaryDatabaseURL(),
            requiredLeadingCommentMarker: "macrodex:"
        )
        _ = try sqlRunner.exec("/* macrodex: Creating foods */ CREATE TABLE foods (id TEXT PRIMARY KEY, name TEXT NOT NULL);")
        let runner = PiJSCScriptToolRunner(sqlRunner: sqlRunner)

        let dryRun = try runner.run(script: """
        const schema = sql.schema(["foods"]);
        const validation = sql.validate("/* macrodex: Checking food */ INSERT INTO foods (id, name) VALUES (?, ?)", ["rice", "Rice bowl"]);
        const tx = sql.dryRun([
          { purpose: "Adding rice", statement: "/* macrodex: Adding rice */ INSERT INTO foods (id, name) VALUES (?, ?)", bindings: ["rice", "Rice bowl"] },
          { purpose: "Reading rice", statement: "/* macrodex: Reading rice */ SELECT name FROM foods WHERE id = ?", bindings: ["rice"], mode: "query" }
        ]);
        ({ column: schema.tables[0].columns[0].name, readOnly: validation.readOnly, operationCount: tx.operations.length });
        """)
        let rowsAfterDryRun = try sqlRunner.query("/* macrodex: Checking dry run */ SELECT id FROM foods")
        XCTAssertEqual(dryRun.objectValue?["result"]?.objectValue?["column"]?.stringValue, "id")
        XCTAssertEqual(dryRun.objectValue?["result"]?.objectValue?["readOnly"]?.boolValue, false)
        XCTAssertEqual(dryRun.objectValue?["result"]?.objectValue?["operationCount"]?.numberValue, 2)
        XCTAssertTrue(rowsAfterDryRun.isEmpty)

        let committed = try runner.run(script: """
        sql.transaction([
          { purpose: "Adding rice", statement: "/* macrodex: Adding rice */ INSERT INTO foods (id, name) VALUES (?, ?)", bindings: ["rice", "Rice bowl"] }
        ]);
        sql.query("/* macrodex: Reading foods */ SELECT name FROM foods WHERE id = ?", ["rice"])[0];
        """)
        XCTAssertEqual(committed.objectValue?["result"]?.objectValue?["name"]?.stringValue, "Rice bowl")
    }

    func testWebSearchToolRunnerParsesDuckDuckGoResults() throws {
        let transport = RecordingWebTransport(
            statusCode: 200,
            body: """
            <html>
              <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fnutrition&amp;rut=abc">Example &amp; Nutrition</a>
              <a class="result__a" href="https://openai.com/">OpenAI</a>
            </html>
            """
        )
        let runner = PiWebSearchToolRunner(transport: transport)

        let result = try runner.runTool(
            PiToolCall(
                id: "search",
                name: "web_search",
                arguments: [
                    "query": "banana nutrition",
                    "maxResults": 2
                ]
            )
        )

        let results = try XCTUnwrap(result.output.objectValue?["results"]?.arrayValue)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].objectValue?["title"]?.stringValue, "Example & Nutrition")
        XCTAssertEqual(results[0].objectValue?["url"]?.stringValue, "https://example.com/nutrition")
        XCTAssertEqual(transport.requests.first?.url?.host, "html.duckduckgo.com")
    }

    func testCodexProviderEmitsStreamingEventsFromChunkedSSE() throws {
        let transport = ChunkedCodexTransport(
            statusCode: 200,
            chunks: [
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Pi\"}\n\n",
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"JSC\"}\n\n",
                "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n\n"
            ]
        )
        let provider = PiCodexChatGPTProvider(
            auth: PiCodexAuth(accessToken: "access-token", accountID: "account-id"),
            transport: transport
        )
        var events: [PiProviderStreamEvent] = []

        let response = try provider.complete(
            PiProviderRequest(
                threadID: "thread-stream",
                providerID: "openai",
                model: "gpt-test",
                messages: [PiMessage(role: .user, content: "stream")]
            ),
            eventHandler: { events.append($0) }
        )

        XCTAssertEqual(response.message?.content, "PiJSC")
        XCTAssertEqual(events.map(\.type), ["output_text.delta", "output_text.delta", "completed"])
        XCTAssertEqual(events.compactMap { $0.payload["delta"]?.stringValue }, ["Pi", "JSC"])
    }

    func testRuntimeBridgesStreamingProviderEvents() throws {
        let runtime = try PiJSCRuntime()
        runtime.registerProvider(StreamingScriptedProvider(), for: "openai")
        var events: [PiRuntimeEvent] = []

        _ = try runtime.runTurn(
            PiTurnRequest(prompt: "stream", providerID: "openai", model: "gpt-test"),
            eventHandler: { events.append($0) }
        )

        XCTAssertEqual(
            events.filter { $0.type == "provider.output_text.delta" }.compactMap { $0.payload["delta"]?.stringValue },
            ["A", "B"]
        )
    }

    func testToolRegistryInstallsDefaultLocalTools() throws {
        let runtime = try PiJSCRuntime()
        let registry = PiToolRegistry.defaultLocalTools(
            databaseURL: temporaryDatabaseURL(),
            requiredSQLCommentMarker: "macrodex:"
        )
        registry.install(on: runtime)
        runtime.registerProvider(id: "openai") { request in
            if request.messages.last?.role != .tool {
                return PiProviderResponse(
                    toolCalls: [
                        PiToolCall(
                            id: "setup",
                            name: "sql",
                            arguments: [
                                "statement": "/* macrodex: Creating foods */ CREATE TABLE foods (name TEXT);",
                                "mode": "exec"
                            ]
                        )
                    ]
                )
            }
            return PiProviderResponse(message: PiMessage(role: .assistant, content: "done"))
        }

        let result = try runtime.runTurn(
            PiTurnRequest(
                prompt: "create table",
                providerID: "openai",
                model: "gpt-test",
                tools: registry.definitions
            )
        )

        XCTAssertEqual(result.finalMessage?.content, "done")
        XCTAssertTrue(registry.definitions.map(\.name).contains("jsc"))
        XCTAssertTrue(registry.definitions.map(\.name).contains("sql"))
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("db.sqlite")
    }
}

private final class ScriptedProvider: PiProviderClient {
    private(set) var requests: [PiProviderRequest] = []
    private var responses: [PiProviderResponse]

    init(responses: [PiProviderResponse]) {
        self.responses = responses
    }

    func complete(_ request: PiProviderRequest) throws -> PiProviderResponse {
        requests.append(request)

        guard !responses.isEmpty else {
            throw TestProviderError.noResponse
        }

        return responses.removeFirst()
    }
}

private enum TestProviderError: Error {
    case noResponse
}

private final class StreamingScriptedProvider: PiStreamingProviderClient {
    func complete(_ request: PiProviderRequest) throws -> PiProviderResponse {
        try complete(request, eventHandler: nil)
    }

    func complete(
        _ request: PiProviderRequest,
        eventHandler: PiProviderStreamEventHandler?
    ) throws -> PiProviderResponse {
        eventHandler?(
            PiProviderStreamEvent(
                type: "output_text.delta",
                providerID: request.providerID,
                threadID: request.threadID,
                payload: ["delta": "A"]
            )
        )
        eventHandler?(
            PiProviderStreamEvent(
                type: "output_text.delta",
                providerID: request.providerID,
                threadID: request.threadID,
                payload: ["delta": "B"]
            )
        )
        return PiProviderResponse(
            message: PiMessage(role: .assistant, content: "AB"),
            outputDeltas: ["A", "B"]
        )
    }
}

private final class RecordingTransport: PiCodexHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [[String: Any]] = []
    private let statusCode: Int
    private let body: String

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let httpBody = request.httpBody,
           let json = try JSONSerialization.jsonObject(with: httpBody) as? [String: Any] {
            requestBodies.append(json)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (Data(body.utf8), response)
    }
}

private final class ChunkedCodexTransport: PiCodexStreamingHTTPTransport {
    private let statusCode: Int
    private let chunks: [String]

    init(statusCode: Int, chunks: [String]) {
        self.statusCode = statusCode
        self.chunks = chunks
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body = chunks.joined()
        return (Data(body.utf8), response(for: request))
    }

    func performStreaming(
        _ request: URLRequest,
        onData: @escaping (Data) -> Void
    ) throws -> (Data, HTTPURLResponse) {
        var body = Data()
        for chunk in chunks {
            let data = Data(chunk.utf8)
            body.append(data)
            onData(data)
        }
        return (body, response(for: request))
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }
}

private final class RecordingWebTransport: PiWebSearchHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let statusCode: Int
    private let body: String

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )!
        return (Data(body.utf8), response)
    }
}
