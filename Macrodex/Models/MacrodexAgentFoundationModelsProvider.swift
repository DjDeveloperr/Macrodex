import Foundation
import MacrodexAgent

#if canImport(FoundationModels)
import FoundationModels
#endif

enum MacrodexAgentFoundationModelsProviderError: Error, LocalizedError {
    case unavailablePlatform
    case unavailableModel(String)
    case unsupportedImages
    case noAssistantOutput
    case pccUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailablePlatform:
            return "Foundation Models are not available on this OS."
        case .unavailableModel(let reason):
            return "Foundation Models are unavailable: \(reason)"
        case .unsupportedImages:
            return "Foundation Models in Macrodex currently support text input only."
        case .noAssistantOutput:
            return "Foundation Models returned no assistant output."
        case .pccUnavailable:
            return "Foundation Models PCC is not exposed by the current public SDK. Select System or update the SDK when Apple exposes the PCC accessor."
        }
    }
}

#if canImport(FoundationModels)
final class MacrodexAgentFoundationModelsProvider: MacrodexAgentStreamingProviderClient, @unchecked Sendable {
    private final class StreamHandlerBox: @unchecked Sendable {
        let handler: MacrodexAgentProviderStreamEventHandler?

        init(_ handler: MacrodexAgentProviderStreamEventHandler?) {
            self.handler = handler
        }
    }

    func complete(_ request: MacrodexAgentProviderRequest) throws -> MacrodexAgentProviderResponse {
        try complete(request, eventHandler: nil)
    }

    func complete(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: MacrodexAgentProviderStreamEventHandler?
    ) throws -> MacrodexAgentProviderResponse {
        guard #available(iOS 26.0, *) else {
            throw MacrodexAgentFoundationModelsProviderError.unavailablePlatform
        }
        return try waitFor {
            try await self.completeAsync(request, eventHandler: StreamHandlerBox(eventHandler))
        }
    }

    private func waitFor<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultQueue = DispatchQueue(label: "com.dj.macrodex.foundation-models.result")
        var result: Result<T, Error>?

        Task {
            do {
                let value = try await operation()
                resultQueue.sync {
                    result = .success(value)
                }
            } catch {
                resultQueue.sync {
                    result = .failure(error)
                }
            }
            semaphore.signal()
        }

        semaphore.wait()
        let finalResult = resultQueue.sync { result }
        return try finalResult!.get()
    }

    @available(iOS 26.0, *)
    private func completeAsync(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        guard request.messages.allSatisfy({ $0.imageURLs.isEmpty }) else {
            throw MacrodexAgentFoundationModelsProviderError.unsupportedImages
        }

        let model = try foundationModel(for: request.model)
        try validate(model: model)

        let instructions = Self.instructions(from: request)
        let prompt = Self.prompt(from: request.messages)
        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        if eventHandler.handler != nil {
            return try await streamResponse(
                session: session,
                prompt: prompt,
                request: request,
                eventHandler: eventHandler
            )
        }

        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 900)
        )
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
        }
        return MacrodexAgentProviderResponse(
            message: MacrodexAgentMessage(role: .assistant, content: content)
        )
    }

    @available(iOS 26.0, *)
    private func streamResponse(
        session: LanguageModelSession,
        prompt: String,
        request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        var previous = ""
        var deltas: [String] = []
        let stream = session.streamResponse(
            to: prompt,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 900)
        )

        for try await snapshot in stream {
            let content = snapshot.content
            let delta = Self.delta(from: previous, to: content)
            previous = content
            guard !delta.isEmpty else { continue }
            deltas.append(delta)
            eventHandler.handler?(
                MacrodexAgentProviderStreamEvent(
                    type: "output_text.delta",
                    providerID: request.providerID,
                    threadID: request.threadID,
                    payload: [
                        "delta": .string(delta),
                        "aggregate": .string(content)
                    ]
                )
            )
        }

        let content = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
        }
        return MacrodexAgentProviderResponse(
            message: MacrodexAgentMessage(role: .assistant, content: content),
            outputDeltas: deltas
        )
    }

    @available(iOS 26.0, *)
    private func foundationModel(for modelID: String) throws -> SystemLanguageModel {
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "system", "foundationmodels/system":
            return SystemLanguageModel(useCase: .general)
        case "pcc", "foundationmodels/pcc":
            throw MacrodexAgentFoundationModelsProviderError.pccUnavailable
        default:
            return SystemLanguageModel(useCase: .general)
        }
    }

    @available(iOS 26.0, *)
    private func validate(model: SystemLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw MacrodexAgentFoundationModelsProviderError.unavailableModel(Self.availabilityReason(reason))
        @unknown default:
            throw MacrodexAgentFoundationModelsProviderError.unavailableModel("unknown")
        }
    }

    @available(iOS 26.0, *)
    private static func availabilityReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .deviceNotEligible:
            return "this device is not eligible"
        case .modelNotReady:
            return "the model is not ready yet"
        @unknown default:
            return "unknown"
        }
    }

    private static func instructions(from request: MacrodexAgentProviderRequest) -> String {
        var parts = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !request.tools.isEmpty {
            parts.append(
                "You are running through Apple's local Foundation Models provider. This provider currently cannot execute Macrodex runtime tools. Answer directly when possible; for data-changing app actions, tell the user which Macrodex Siri/App Shortcut action to use or ask them to switch to a ChatGPT/Google model."
            )
        }

        return parts.joined(separator: "\n\n")
    }

    private static func prompt(from messages: [MacrodexAgentMessage]) -> String {
        messages
            .filter { $0.role != .system }
            .map { message in
                switch message.role {
                case .user:
                    return "User: \(message.content)"
                case .assistant:
                    return "Assistant: \(message.content)"
                case .tool:
                    let trimmedName = message.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let name = trimmedName.isEmpty ? "tool" : trimmedName
                    return "Tool \(name): \(message.content)"
                case .system:
                    return ""
                }
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func delta(from previous: String, to current: String) -> String {
        guard !current.isEmpty else { return "" }
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
    }
}
#endif
