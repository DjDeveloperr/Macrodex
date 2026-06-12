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
    case pccRequiresNewSDK
    case pccRequiresNewOS
    case pccUnavailable(String)
    case pccQuotaLimitReached(String)

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
        case .pccRequiresNewSDK:
            return "Foundation Models PCC requires building Macrodex with the iOS 27 SDK. Select System on this build."
        case .pccRequiresNewOS:
            return "Foundation Models PCC requires iOS 27. Select System on this device."
        case .pccUnavailable(let reason):
            return "Foundation Models PCC is unavailable: \(reason)"
        case .pccQuotaLimitReached(let reason):
            return "Foundation Models PCC quota limit reached: \(reason)"
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

        if Self.isPCCModel(request.model) {
#if compiler(>=6.4)
            guard #available(iOS 27.0, *) else {
                throw MacrodexAgentFoundationModelsProviderError.pccRequiresNewOS
            }
            return try await completePCCAsync(request, eventHandler: eventHandler)
#else
            throw MacrodexAgentFoundationModelsProviderError.pccRequiresNewSDK
#endif
        }

        return try await completeSystemAsync(request, eventHandler: eventHandler)
    }

    @available(iOS 26.0, *)
    private func completeSystemAsync(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        let model = foundationModel(for: request.model)
        try validate(model: model)

        let instructions = Self.instructions(from: request)
        let prompt = Self.prompt(from: request.messages)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 900)
        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        if eventHandler.handler != nil {
            return try await streamResponse(
                stream: session.streamResponse(to: prompt, options: options),
                request: request,
                eventHandler: eventHandler
            )
        }

        let response = try await session.respond(
            to: prompt,
            options: options
        )
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
        }
        return MacrodexAgentProviderResponse(
            message: MacrodexAgentMessage(role: .assistant, content: content)
        )
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    private func completePCCAsync(
        _ request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        let model = PrivateCloudComputeLanguageModel()
        try validatePCC(model: model)
        try validatePCCQuota(model: model)

        let instructions = Self.instructions(from: request)
        let prompt = Self.prompt(from: request.messages)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 900)
        let contextOptions = ContextOptions(reasoningLevel: Self.pccReasoningLevel(from: request))
        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        do {
            if eventHandler.handler != nil {
                return try await streamResponse(
                    stream: session.streamResponse(
                        to: prompt,
                        options: options,
                        contextOptions: contextOptions
                    ),
                    request: request,
                    eventHandler: eventHandler
                )
            }

            let response = try await session.respond(
                to: prompt,
                options: options,
                contextOptions: contextOptions
            )
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw MacrodexAgentFoundationModelsProviderError.noAssistantOutput
            }
            return MacrodexAgentProviderResponse(
                message: MacrodexAgentMessage(role: .assistant, content: content),
                usage: MacrodexAgentUsage(
                    inputTokens: response.usage.input.totalTokenCount,
                    cachedInputTokens: response.usage.input.cachedTokenCount,
                    outputTokens: response.usage.output.totalTokenCount,
                    totalTokens: response.usage.totalTokenCount
                )
            )
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            throw Self.pccProviderError(from: error)
        }
    }
#endif

    @available(iOS 26.0, *)
    private func streamResponse(
        stream: LanguageModelSession.ResponseStream<String>,
        request: MacrodexAgentProviderRequest,
        eventHandler: StreamHandlerBox
    ) async throws -> MacrodexAgentProviderResponse {
        var previous = ""
        var deltas: [String] = []

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
    private func foundationModel(for modelID: String) -> SystemLanguageModel {
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "system", "foundationmodels/system":
            return SystemLanguageModel(useCase: .general)
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

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    private func validatePCC(model: PrivateCloudComputeLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw MacrodexAgentFoundationModelsProviderError.pccUnavailable(Self.pccAvailabilityReason(reason))
        @unknown default:
            throw MacrodexAgentFoundationModelsProviderError.pccUnavailable("unknown")
        }
    }

    @available(iOS 27.0, *)
    private func validatePCCQuota(model: PrivateCloudComputeLanguageModel) throws {
        let usage = model.quotaUsage
        guard usage.isLimitReached else { return }
        throw MacrodexAgentFoundationModelsProviderError.pccQuotaLimitReached(
            Self.pccQuotaDescription(resetDate: usage.resetDate)
        )
    }

    @available(iOS 27.0, *)
    private static func pccAvailabilityReason(
        _ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this device is not eligible"
        case .systemNotReady:
            return "the system is not ready yet"
        @unknown default:
            return "unknown"
        }
    }

    @available(iOS 27.0, *)
    private static func pccProviderError(
        from error: PrivateCloudComputeLanguageModel.Error
    ) -> MacrodexAgentFoundationModelsProviderError {
        switch error {
        case .networkFailure(let networkFailure):
            return .pccUnavailable("network failure: \(networkFailure.debugDescription)")
        case .quotaLimitReached(let quotaLimit):
            return .pccQuotaLimitReached(
                pccQuotaDescription(
                    resetDate: quotaLimit.resetDate,
                    fallback: quotaLimit.debugDescription
                )
            )
        case .serviceUnavailable(let serviceUnavailable):
            return .pccUnavailable("service unavailable: \(serviceUnavailable.debugDescription)")
        @unknown default:
            return .pccUnavailable(error.localizedDescription)
        }
    }

    @available(iOS 27.0, *)
    private static func pccReasoningLevel(from request: MacrodexAgentProviderRequest) -> ContextOptions.ReasoningLevel {
        let effort = request.metadata["reasoning_effort"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch effort {
        case "low", "light", "none":
            return .light
        case "high", "xhigh", "deep":
            return .deep
        default:
            return .moderate
        }
    }

    private static func pccQuotaDescription(resetDate: Date?, fallback: String? = nil) -> String {
        if let resetDate {
            return "try again after \(resetDate.formatted(date: .abbreviated, time: .shortened))"
        }
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedFallback.isEmpty ? "try again later" : trimmedFallback
    }
#endif

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

    private static func isPCCModel(_ modelID: String) -> Bool {
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pcc",
             "privatecloudcompute",
             "private-cloud-compute",
             "foundationmodels/pcc",
             "foundationmodels/privatecloudcompute",
             "foundationmodels/private-cloud-compute":
            return true
        default:
            return false
        }
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
