import SwiftUI
import UIKit
import PhotosUI
import os

/// Composer variant for the home screen. When a project is selected, typing
/// and hitting send creates a new thread on (project.serverId, project.cwd)
/// and submits the initial turn. User stays on home — the new thread appears
/// in the task list and streams in place.
struct HomeComposerView: View {
    let project: AppProject?
    let onThreadCreated: (ThreadKey) -> Void
    /// Fires when the composer becomes "active" (keyboard up, text/image
    /// entered, or voice recording/transcribing) or returns to idle.
    var onActiveChange: ((Bool) -> Void)? = nil
    /// When true, the composer requests keyboard focus the moment it
    /// appears. Used when the view is revealed by tapping `+`.
    var autoFocus: Bool = false

    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false

    @State private var inputText = ""
    @State private var attachedImages: [UIImage] = []
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var cameraImage: UIImage?
    @State private var showNutritionLabelPicker = false
    @State private var selectedNutritionLabelPhoto: PhotosPickerItem?
    @State private var scannedNutritionLabel: ScannedNutritionLabelDraft?
    @State private var isScanningNutritionLabel = false
    @State private var isFoodSearchMode = false
    @State private var foodSearchLoading = false
    @State private var foodSearchResults: [ComposerFoodSearchResult] = []
    @State private var foodSearchTask: Task<Void, Never>?
    @State private var foodSearchCache: [String: [ComposerFoodSearchResult]] = [:]
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var composerContentHeight: CGFloat = 56
    /// Plain `@State`, not `@FocusState`: the composer's text view is a
    /// UIKit `UITextView` wrapped in a UIViewRepresentable, not a SwiftUI
    /// focusable view. Using `@FocusState` without a matching `.focused()`
    /// modifier causes SwiftUI's focus manager to immediately revert any
    /// programmatic `true` back to `false`, which made the keyboard close
    /// the moment it opened.
    @State private var isComposerFocused: Bool = false

    private var isDisabled: Bool { project == nil }

    private var isActive: Bool {
        isComposerFocused
            || !inputText.isEmpty
            || !attachedImages.isEmpty
            || isFoodSearchMode
            || voiceManager.isRecording
            || voiceManager.isTranscribing
    }

    private var popupState: ConversationComposerPopupState {
        guard isFoodSearchMode else { return .none }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .foodSearch(loading: false, suggestions: recentFoodSuggestions())
        }
        return .foodSearch(loading: foodSearchLoading, suggestions: foodSearchResults)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacrodexTheme.warning)
                    Text(errorMessage)
                        .macrodexFont(.caption)
                        .foregroundStyle(MacrodexTheme.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        self.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MacrodexTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            ConversationComposerContentView(
                attachedImages: attachedImages,
                collaborationMode: .default,
                activePlanProgress: nil,
                pendingUserInputRequest: nil,
                hasPendingPlanImplementation: false,
                activeTaskSummary: nil,
                queuedFollowUps: [],
                rateLimits: nil,
                contextPercent: nil,
                isTurnActive: isSubmitting,
                showModeChip: false,
                voiceManager: voiceManager,
                isFoodSearchMode: isFoodSearchMode,
                showsFoodSearchButton: true,
                keepsAttachmentButtonVisible: true,
                showAttachMenu: $showAttachMenu,
                onRemoveAttachment: { index in
                    guard attachedImages.indices.contains(index) else { return }
                    attachedImages.remove(at: index)
                },
                onRespondToPendingUserInput: { _ in },
                onSteerQueuedFollowUp: { _ in },
                onDeleteQueuedFollowUp: { _ in },
                onPasteImage: { image in
                    guard attachedImages.count < 6 else { return }
                    attachedImages.append(image)
                },
                onToggleFoodSearchMode: toggleFoodSearchMode,
                onOpenModePicker: {},
                onSendText: handleSend,
                onStopRecording: stopVoiceRecording,
                onStartRecording: startVoiceRecording,
                onInterrupt: {},
                inputText: $inputText,
                isComposerFocused: Binding(
                    get: { isComposerFocused },
                    set: { isComposerFocused = $0 }
                )
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ConversationComposerContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .overlay(alignment: .bottom) {
            ConversationComposerPopupOverlayView(
                state: popupState,
                onApplySlashSuggestion: { _ in },
                onApplyFileSuggestion: { _ in },
                onApplySkillSuggestion: { _ in },
                bottomInset: composerContentHeight + 8,
                popupLift: 10,
                onApplyFoodSuggestion: applyFoodSuggestion
            )
        }
        .onPreferenceChange(ConversationComposerContentHeightPreferenceKey.self) { height in
            composerContentHeight = max(56, height)
        }
        .onChange(of: isActive) { _, active in
            onActiveChange?(active)
        }
        .onChange(of: inputText) { _, next in
            scheduleFoodSearch(for: next)
        }
        .sheet(isPresented: $showAttachMenu) {
            ConversationComposerAttachSheet(
                onPickPhotoLibrary: {
                    showAttachMenu = false
                    showPhotoPicker = true
                },
                onTakePhoto: {
                    showAttachMenu = false
                    showCamera = true
                },
                onScanNutritionLabel: {
                    showAttachMenu = false
                    showNutritionLabelPicker = true
                }
            )
            .presentationDetents([.height(274)])
            .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 6, matching: .images)
        .photosPicker(isPresented: $showNutritionLabelPicker, selection: $selectedNutritionLabelPhoto, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $cameraImage)
                .ignoresSafeArea()
        }
        .sheet(item: $scannedNutritionLabel) { draft in
            CalorieLogFoodSheet(
                store: CalorieTrackerStore.shared,
                scannedLabel: draft.result,
                photoData: draft.photoData,
                title: "Food Details"
            )
        }
        .overlay(alignment: .top) {
            if isScanningNutritionLabel {
                Label("Scanning label...", systemImage: "text.viewfinder")
                    .macrodexFont(.caption, weight: .semibold)
                    .foregroundStyle(MacrodexTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(MacrodexTheme.surface.opacity(0.92), in: Capsule())
                    .offset(y: -42)
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadSelectedPhotos(items) }
        }
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            attachedImages.append(image)
            cameraImage = nil
        }
        .onChange(of: selectedNutritionLabelPhoto) { _, item in
            guard let item else { return }
            Task { await scanNutritionLabel(item) }
        }
        .onDisappear {
            foodSearchTask?.cancel()
            foodSearchTask = nil
        }
        .task {
            // Focus as early as possible so the keyboard rises in parallel
            // with the glass-morph spring — the two animations then feel
            // like one fluid motion. A tiny 40ms yield lets the view land
            // in the window tree; the UIViewRepresentable picks up focus on
            // its next `updateUIView` pass. Re-issue once after the spring
            // settles as a safety net for edge cases where the first pass
            // fired before the window attachment.
            guard autoFocus else { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
            isComposerFocused = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !isComposerFocused {
                isComposerFocused = true
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        var next = attachedImages
        for item in items {
            guard next.count < 6,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { continue }
            next.append(image)
        }
        attachedImages = next
        selectedPhotos = []
    }

    private func scanNutritionLabel(_ item: PhotosPickerItem) async {
        selectedNutritionLabelPhoto = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        isScanningNutritionLabel = true
        defer { isScanningNutritionLabel = false }
        do {
            let result = try await PiAgentRuntimeBackend.shared.scanNutritionLabel(imageData: data)
            scannedNutritionLabel = ScannedNutritionLabelDraft(result: result, photoData: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleFoodSearchMode() {
        isFoodSearchMode.toggle()
        if isFoodSearchMode {
            isComposerFocused = true
            scheduleFoodSearch(for: inputText)
        } else {
            clearFoodSearchState(cancelTask: true)
        }
    }

    private func clearFoodSearchState(cancelTask: Bool) {
        if cancelTask {
            foodSearchTask?.cancel()
            foodSearchTask = nil
        }
        foodSearchLoading = false
        foodSearchResults = []
    }

    private func scheduleFoodSearch(for query: String) {
        guard isFoodSearchMode else {
            clearFoodSearchState(cancelTask: true)
            return
        }
        foodSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            foodSearchLoading = false
            foodSearchResults = recentFoodSuggestions()
            return
        }
        if let cached = foodSearchCache[trimmed] {
            foodSearchResults = cached
            foodSearchLoading = false
            return
        }
        foodSearchLoading = true
        foodSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await CalorieTrackerStore.shared.refresh()
            guard !Task.isCancelled else { return }
            let localResults = foodSearchMatches(for: trimmed)
            foodSearchResults = localResults
            let rankedResults = await FoodSearchAIResolver.results(
                query: trimmed,
                candidates: localResults,
                timeoutSeconds: 10
            )
            guard !Task.isCancelled else { return }
            foodSearchResults = rankedResults
            foodSearchCache[trimmed] = rankedResults
            foodSearchLoading = false
        }
    }

    private func recentFoodSuggestions() -> [ComposerFoodSearchResult] {
        CalorieTrackerStore.shared.recentFoodMemories.prefix(5).map { item in
            ComposerFoodSearchResult(
                id: "recent-\(item.id)",
                title: item.title,
                detail: item.detail,
                insertText: item.title,
                servingQuantity: item.defaultServingQty,
                servingUnit: item.defaultServingUnit,
                servingWeight: item.defaultServingWeight,
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat,
                source: "Recent food",
                notes: "Logged before",
                confidence: 0.9
            )
        }
    }

    private func foodSearchMatches(for query: String) -> [ComposerFoodSearchResult] {
        let store = CalorieTrackerStore.shared
        let libraryMatches = store.libraryItems.compactMap { item -> (ComposerFoodSearchResult, Int)? in
            let candidates = [item.name, item.brand, item.kind, item.sourceTitle] + item.aliases.map(Optional.some)
            let score = candidates.compactMap { $0 }.compactMap { HomeFoodSearchScoring.score(candidate: $0, query: query) }.max()
            guard let score else { return nil }
            let title = item.brand.map { "\($0) \(item.name)" } ?? item.name
            return (
                ComposerFoodSearchResult(
                    id: "library-\(item.id)",
                    title: title,
                    detail: item.detail,
                    insertText: title,
                    servingQuantity: item.defaultServingQty,
                    servingUnit: item.defaultServingUnit,
                    servingWeight: item.defaultServingWeight,
                    calories: item.calories,
                    protein: item.protein,
                    carbs: item.carbs,
                    fat: item.fat,
                    source: item.sourceTitle,
                    sourceURL: item.sourceURL,
                    notes: item.notes,
                    confidence: confidence(from: score + (item.isFavorite ? 12 : 0))
                ),
                score + (item.isFavorite ? 12 : 0)
            )
        }
        let recentMatches = store.recentFoodMemories.compactMap { item -> (ComposerFoodSearchResult, Int)? in
            let candidates = [item.title, item.displayName, item.brand, item.canonicalName]
            let score = candidates.compactMap { $0 }.compactMap { HomeFoodSearchScoring.score(candidate: $0, query: query) }.max()
            guard let score else { return nil }
            return (
                ComposerFoodSearchResult(
                    id: "recent-\(item.id)",
                    title: item.title,
                    detail: item.detail,
                    insertText: item.title,
                    servingQuantity: item.defaultServingQty,
                    servingUnit: item.defaultServingUnit,
                    servingWeight: item.defaultServingWeight,
                    calories: item.calories,
                    protein: item.protein,
                    carbs: item.carbs,
                    fat: item.fat,
                    source: "Recent food",
                    notes: "Logged before",
                    confidence: confidence(from: score + 6)
                ),
                score + 6
            )
        }
        let standardMatches = StandardFoodDatabase.matches(query: query).map { food, score in
            (
                ComposerFoodSearchResult(
                    id: "standard-\(food.id)",
                    title: food.name,
                    detail: food.detail,
                    insertText: food.name,
                    servingQuantity: food.servingQuantity,
                    servingUnit: food.servingUnit,
                    servingWeight: food.servingWeight,
                    calories: food.calories,
                    protein: food.protein,
                    carbs: food.carbs,
                    fat: food.fat,
                    source: "Foundation food",
                    notes: "Built-in common food estimate",
                    confidence: confidence(from: score + 3)
                ),
                score + 3
            )
        }
        return (libraryMatches + recentMatches + standardMatches)
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private func confidence(from score: Int) -> Double {
        if score >= 9_500 { return 0.98 }
        if score >= 7_500 { return 0.94 }
        if score >= 5_500 { return 0.88 }
        return min(max(0.54 + Double(score) / 10_000, 0.56), 0.84)
    }

    private func applyFoodSuggestion(_ suggestion: ComposerFoodSearchResult) {
        inputText = suggestion.insertText
        isComposerFocused = true
        clearFoodSearchState(cancelTask: true)
        isFoodSearchMode = false
    }

    private func handleSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachedImages
        guard !text.isEmpty || !images.isEmpty else { return }
        guard !isSubmitting else { return }
        guard let project else {
            errorMessage = "Pick a project before sending."
            return
        }

        inputText = ""
        attachedImages = []
        isComposerFocused = false
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelOverride = appModel.selectedModelID(
                    for: project.serverId,
                    selectedModel: pendingModel.isEmpty ? nil : pendingModel,
                    requiresImageInput: !images.isEmpty
                )
                let pendingEffort = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                let effortOverride = ReasoningEffort(wireValue: pendingEffort.isEmpty ? nil : pendingEffort)
                let launchConfig = AppThreadLaunchConfig(
                    model: modelOverride,
                    approvalPolicy: appState.launchApprovalPolicy(for: nil),
                    sandbox: appState.launchSandboxMode(for: nil),
                    developerInstructions: AgentRuntimeInstructions.developerInstructions(),
                    persistExtendedHistory: true
                )
                let threadKey = try await appModel.client.startThread(
                    serverId: project.serverId,
                    params: launchConfig.threadStartRequest(
                        cwd: project.cwd,
                        dynamicTools: AgentDynamicToolSpecs.defaultThreadTools(
                            includeGenerativeUI: false
                        )
                    )
                )
                RecentDirectoryStore.shared.record(path: project.cwd, for: project.serverId)
                let additionalInputs = images
                    .compactMap(ConversationAttachmentSupport.prepareImage)
                    .map(\.userInput)
                let payload = AppComposerPayload(
                    text: text,
                    additionalInputs: additionalInputs,
                    approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
                    sandboxPolicy: appState.turnSandboxPolicy(for: threadKey),
                    model: modelOverride,
                    effort: effortOverride,
                    serviceTier: ServiceTier(wireValue: fastMode ? "fast" : nil)
                )
                try await appModel.startTurn(key: threadKey, payload: payload)
                await appModel.refreshSnapshot()
                onThreadCreated(threadKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else { return }
            voiceManager.startRecording()
        }
    }

    private func stopVoiceRecording() {
        guard let project else {
            voiceManager.cancelRecording()
            return
        }
        Task {
            let auth = try? await appModel.client.authStatus(
                serverId: project.serverId,
                params: AuthStatusRequest(includeToken: true, refreshToken: false)
            )
            if let text = await voiceManager.stopAndTranscribe(
                authMethod: auth?.authMethod,
                authToken: auth?.authToken
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = text
                DispatchQueue.main.async {
                    isComposerFocused = true
                }
            }
        }
    }
}

private struct ScannedNutritionLabelDraft: Identifiable {
    let id = UUID()
    let result: NutritionLabelScanResult
    let photoData: Data
}

private enum HomeFoodSearchScoring {
    static func score(candidate: String, query: String) -> Int? {
        let candidate = candidate.lowercased()
        let query = query.lowercased()
        guard !query.isEmpty else { return 0 }
        if candidate == query { return 10_000 }
        if candidate.hasPrefix(query) { return 8_000 - candidate.count }
        if candidate.contains(query) { return 6_000 - candidate.count }

        var score = 0
        var searchStart = candidate.startIndex
        for scalar in query {
            guard let found = candidate[searchStart...].firstIndex(of: scalar) else { return nil }
            score += candidate.distance(from: searchStart, to: found) == 0 ? 90 : 25
            searchStart = candidate.index(after: found)
        }
        return score - candidate.count
    }
}
