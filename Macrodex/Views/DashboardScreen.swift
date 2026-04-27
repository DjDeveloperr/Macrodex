import Foundation
import PhotosUI
import SQLite3
import SwiftUI
import UIKit

private enum DashboardTone {
    static let bg = Color(uiColor: .systemBackground)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let divider = adaptive(light: "#DADAE0", dark: "#1C1C1E")
    static let elevated = adaptive(light: "#F2F2F7", dark: "#1C1C1E")
    static let macroFill = adaptive(light: "#526A80", dark: "#91A7BA")
    static let accent = Color(red: 0.302, green: 0.639, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.271, blue: 0.227)

    static let sectionPadding: CGFloat = 20
    static let itemSpacing: CGFloat = 12
    static let blockSpacing: CGFloat = 24

    private static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private enum DashboardMetricsAnimation {
    static let reveal: Animation = .easeOut(duration: 0.34)
    static let revealDelayNanoseconds: UInt64 = 45_000_000
    static let dateSwitchFallbackDelayNanoseconds: UInt64 = 360_000_000

    static func calorieBlockReveal(index: Int, count: Int) -> Animation {
        let segmentDuration = 0.14
        let totalDuration = 0.34
        let stagger = max((totalDuration - segmentDuration) / Double(max(count - 1, 1)), 0)
        return .easeOut(duration: segmentDuration).delay(Double(index) * stagger)
    }
}

struct DashboardScreen: View {
    @Environment(DrawerController.self) private var drawerController
    let bottomInset: CGFloat
    let onQuickComposerSend: ((String, [UIImage]) async throws -> Void)?
    let composerFocusRequestID: Int

    @StateObject private var store = CalorieTrackerStore.shared
    @State private var activeSheet: DashboardSheet?
    @State private var selectedLogItem: CalorieLogItem?
    @State private var selectedMeal: MealLogSelection?
    @State private var showDailyNoteDeleteConfirmation = false
    @State private var dismissedKeyboardForDrawerOpen = false
    @State private var dashboardMetricsAreRevealed: Bool
    @State private var dashboardMetricsRevealTask: Task<Void, Never>?
    @State private var keyboardOverlayProgress: CGFloat = 0
    @State private var dashboardSummary = ""
    @State private var dashboardSuggestions: [DashboardFoodSuggestion] = []

    init(
        bottomInset: CGFloat = 0,
        onQuickComposerSend: ((String, [UIImage]) async throws -> Void)? = nil,
        composerFocusRequestID: Int = 0
    ) {
        self.bottomInset = bottomInset
        self.onQuickComposerSend = onQuickComposerSend
        self.composerFocusRequestID = composerFocusRequestID
        _dashboardMetricsAreRevealed = State(
            initialValue: CalorieTrackerStore.shared.hasClaimedInitialDashboardMetricsReveal
        )
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DashboardTone.blockSpacing) {
                    dashboardHeader
                    calorieProgressSection
                    WeeklyMacroStrip(store: store)
                    macroSummary
                    dashboardSummarySection
                    dailyNoteCard
                    todayLogSection
                }
                .padding(.horizontal, DashboardTone.sectionPadding)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .blur(radius: dashboardContentBlurRadius)

            dashboardKeyboardBlurOverlay
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .scrollDisabled(drawerController.progress > 0.001)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
        .onChange(of: drawerController.progress) { _, progress in
            if progress > 0.001 {
                dismissKeyboardForDrawerOpenIfNeeded()
                dismissDashboardSheets()
            } else {
                dismissedKeyboardForDrawerOpen = false
            }
        }
        .onChange(of: drawerController.isOpen) { _, isOpen in
            if isOpen {
                dismissKeyboardForDrawerOpenIfNeeded()
                dismissDashboardSheets()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dashboardComposerInset
        }
        .background(calorieBackground)
        .task(id: dashboardInsightHash) {
            await refreshDashboardInsights()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerMenuButton()
            }
            ToolbarItem(placement: .principal) {
                Button {
                    guard canOpenDashboardSheet else { return }
                    AppHaptics.light()
                    activeSheet = .dateSwitcher
                } label: {
                    VStack(spacing: 1) {
                        Text(selectedDateTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(DashboardTone.textPrimary)
                        Text(selectedDateSubtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DashboardTone.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change day")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    guard canOpenDashboardSheet else { return }
                    AppHaptics.light()
                    activeSheet = .goals
                } label: {
                    Image(systemName: "target")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DashboardTone.textPrimary.opacity(0.78))
                }
                .accessibilityLabel("Edit calorie goals")
                Button {
                    guard canOpenDashboardSheet else { return }
                    AppHaptics.medium()
                    activeSheet = .searchFood
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DashboardTone.textPrimary)
                }
                .accessibilityLabel("Log food")
            }
        }
        .onAppear {
            dismissKeyboard()
            dismissedKeyboardForDrawerOpen = false
            prepareDashboardMetricsForOpen()
        }
        .onDisappear {
            dashboardMetricsRevealTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            setKeyboardOverlayProgress(1, notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardOverlayProgress(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            setKeyboardOverlayProgress(0, notification: notification)
        }
        .task {
            await store.refresh()
            revealDashboardMetrics()
        }
        .onChange(of: store.selectedDate) { _, _ in
            prepareDashboardMetricsForDateSwitch()
        }
        .onChange(of: store.dashboardRefreshGeneration) { _, _ in
            revealDashboardMetrics()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .logFood:
                CalorieLogFoodSheet(store: store)
            case .searchFood:
                LibrarySearchScreen(store: store, mode: .quickAdd)
            case .goals:
                CalorieGoalsSheet(store: store)
            case .dailyNote:
                DailyNoteSheet(store: store)
            case .dateSwitcher:
                DashboardDateSwitcherSheet(store: store)
            }
        }
        .sheet(item: $selectedLogItem) { item in
            CalorieLogItemDetailSheet(store: store, item: item)
        }
        .sheet(item: $selectedMeal) { selection in
            MealLogDetailSheet(store: store, meal: selection.meal)
        }
        .alert("Calorie Tracker Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var dashboardKeyboardBlurOverlay: some View {
        if keyboardOverlayProgress > 0.001 {
            GeometryReader { proxy in
                let bleed = dashboardKeyboardBlurBottomBleed
                let overlayHeight = proxy.size.height + bleed
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.72 * keyboardOverlayProgress)
                    .frame(width: proxy.size.width, height: overlayHeight, alignment: .top)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black.opacity(0.28), location: 0.18),
                                .init(color: .black.opacity(0.76), location: 0.62),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: proxy.size.width, height: overlayHeight, alignment: .top)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.macrodexDismissKeyboard()
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.opacity)
        }
    }

    private var dashboardContentBlurRadius: CGFloat {
        3.6 * keyboardOverlayProgress
    }

    private var dashboardKeyboardBlurBottomBleed: CGFloat {
        max(bottomInset, 0) + dashboardKeyboardBlurKeyboardOverlap
    }

    private var dashboardKeyboardBlurKeyboardOverlap: CGFloat {
        24
    }

    @ViewBuilder
    private var dashboardComposerInset: some View {
        if let onQuickComposerSend {
            DashboardQuickComposerBar(
                bottomInset: bottomInset,
                focusRequestID: composerFocusRequestID,
                onSend: onQuickComposerSend
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(20)
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                AnimatedCalorieNumberText(value: displayedCalories)
                    .animation(DashboardMetricsAnimation.reveal, value: displayedCalories)
                Text("/ \(store.goal.calories.formatted(.number.precision(.fractionLength(0)))) kcal")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textSecondary)
                    .padding(.bottom, 9)
            }
            remainingStatusText
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories")
        .accessibilityValue("\(store.todayTotals.calories.formatted(.number.precision(.fractionLength(0)))) of \(store.goal.calories.formatted(.number.precision(.fractionLength(0)))) kilocalories, \(remainingLabel)")
    }

    @ViewBuilder
    private var remainingStatusText: some View {
        if remainingCalories < 0 {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(overCaloriesText)
                    .foregroundStyle(DashboardTone.danger)
                Text("over")
                    .foregroundStyle(DashboardTone.textSecondary)
            }
            .font(.subheadline.weight(.semibold))
        } else {
            Text(remainingLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DashboardTone.textSecondary)
        }
    }

    private var calorieProgressSection: some View {
        SlantedCalorieProgressBar(
            progress: displayedProgressRaw,
            isOver: dashboardMetricsAreRevealed && remainingCalories < 0
        )
        .frame(height: 24)
        .animation(DashboardMetricsAnimation.reveal, value: dashboardMetricsAreRevealed && remainingCalories < 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calorie progress")
        .accessibilityValue("\(Int(progressClamped * 100)) percent, \(remainingLabel)")
    }

    private var macroSummary: some View {
        VStack(alignment: .leading, spacing: DashboardTone.itemSpacing) {
            DashboardSectionTitle(title: "Macros")
            VStack(spacing: DashboardTone.itemSpacing) {
                MacroProgressLine(title: "Protein", value: displayedTotals.protein, goal: store.goal.protein)
                MacroProgressLine(title: "Carbs", value: displayedTotals.carbs, goal: store.goal.carbs)
                MacroProgressLine(title: "Fat", value: displayedTotals.fat, goal: store.goal.fat)
            }
        }
    }

    @ViewBuilder
    private var dailyNoteCard: some View {
        if let note = store.dailyNote?.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                guard canOpenDashboardSheet else { return }
                AppHaptics.light()
                activeSheet = .dailyNote
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Daily Note")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(DashboardTone.textPrimary)
                        Spacer()
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DashboardTone.textSecondary)
                    }
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(DashboardTone.textPrimary.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(cardBackground(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    showDailyNoteDeleteConfirmation = true
                } label: {
                    Label("Delete Note", systemImage: "trash")
                }
            }
            .confirmationDialog("Delete daily note?", isPresented: $showDailyNoteDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) {
                    Task { await store.deleteDailyNote() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var todayLogSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                DashboardSectionTitle(title: "Meal Log")
                Text(mealLogCountLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textSecondary)
            }

            if dashboardMealSections.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(DashboardTone.textSecondary.opacity(0.72))
                    Text("No food logged yet")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(DashboardTone.textPrimary)
                    Text("Log breakfast, lunch, dinner, snacks, or drinks as you go. Empty meals stay out of the way.")
                        .font(.subheadline)
                        .foregroundStyle(DashboardTone.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 22) {
                    ForEach(dashboardMealSections, id: \.meal) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            if group.items.isEmpty {
                                MealSuggestionHeader(meal: group.meal)
                                    .padding(.horizontal, 4)
                            } else {
                                MealLogSection(
                                    meal: group.meal,
                                    items: group.items,
                                    store: store,
                                    onOpenMeal: {
                                        guard canOpenDashboardSheet else { return }
                                        selectedMeal = MealLogSelection(meal: group.meal)
                                    },
                                    onOpenItem: { item in
                                        guard canOpenDashboardSheet else { return }
                                        selectedLogItem = item
                                    }
                                )
                                .padding(.horizontal, -8)
                            }

                            if !group.suggestions.isEmpty {
                                DashboardSuggestionsSection(suggestions: group.suggestions) { suggestion in
                                    Task { await logDashboardSuggestion(suggestion) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dashboardSummarySection: some View {
        if !dashboardSummary.trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DashboardSectionTitle(title: "Summary")
                Text(dashboardSummary)
                    .font(.subheadline)
                    .foregroundStyle(DashboardTone.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var remainingCalories: Double {
        store.goal.calories - store.todayTotals.calories
    }

    private var displayedCalories: Double {
        dashboardMetricsAreRevealed ? store.todayTotals.calories : 0
    }

    private var displayedTotals: CalorieTotals {
        dashboardMetricsAreRevealed ? store.todayTotals : CalorieTotals()
    }

    private var remainingLabel: String {
        if remainingCalories >= 0 {
            return "\(remainingCalories.formatted(.number.precision(.fractionLength(0)))) left"
        }
        return "\(overCaloriesText) over"
    }

    private var overCaloriesText: String {
        (-remainingCalories).formatted(.number.precision(.fractionLength(0)))
    }

    private var progressClamped: CGFloat {
        CGFloat(min(max(store.todayTotals.calories / max(store.goal.calories, 1), 0), 1))
    }

    private var progressRaw: CGFloat {
        CGFloat(max(store.todayTotals.calories / max(store.goal.calories, 1), 0))
    }

    private var displayedProgressRaw: CGFloat {
        CGFloat(max(displayedCalories / max(store.goal.calories, 1), 0))
    }

    private func dismissKeyboard() {
        NotificationCenter.default.post(name: .dashboardComposerShouldDismissKeyboard, object: nil)
        UIApplication.shared.macrodexDismissKeyboard()
    }

    private func dismissKeyboardForDrawerOpenIfNeeded() {
        guard !dismissedKeyboardForDrawerOpen else { return }
        dismissedKeyboardForDrawerOpen = true
        dismissKeyboard()
    }

    private func updateKeyboardOverlayProgress(from notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow)
        else {
            setKeyboardOverlayProgress(0, notification: notification)
            return
        }

        let keyboardFrame = window.convert(endFrame, from: nil)
        let isVisible = keyboardFrame.minY < window.bounds.maxY - 1
        setKeyboardOverlayProgress(isVisible ? 1 : 0, notification: notification)
    }

    private func setKeyboardOverlayProgress(_ progress: CGFloat, notification: Notification?) {
        let clamped = min(max(progress, 0), 1)
        guard abs(keyboardOverlayProgress - clamped) > 0.01 else { return }

        let update = {
            keyboardOverlayProgress = clamped
        }

        guard let notification,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              duration > 0
        else {
            withAnimation(.easeOut(duration: 0.18), update)
            return
        }

        withAnimation(.easeOut(duration: min(max(duration, 0.16), 0.34)), update)
    }

    private var canOpenDashboardSheet: Bool {
        !drawerController.shouldSuppressContentInteractions
    }

    private func dismissDashboardSheets() {
        activeSheet = nil
        selectedLogItem = nil
        selectedMeal = nil
    }

    private func prepareDashboardMetricsForOpen() {
        guard store.claimInitialDashboardMetricsReveal() else {
            dashboardMetricsAreRevealed = true
            return
        }
        dashboardMetricsRevealTask?.cancel()
        dashboardMetricsAreRevealed = false
    }

    private func prepareDashboardMetricsForDateSwitch() {
        dashboardMetricsRevealTask?.cancel()
        if !dashboardMetricsAreRevealed {
            revealDashboardMetrics(after: DashboardMetricsAnimation.dateSwitchFallbackDelayNanoseconds)
        }
    }

    private func revealDashboardMetrics(
        after delay: UInt64 = DashboardMetricsAnimation.revealDelayNanoseconds
    ) {
        guard !dashboardMetricsAreRevealed else { return }
        dashboardMetricsRevealTask?.cancel()
        dashboardMetricsRevealTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, !dashboardMetricsAreRevealed else { return }
            withAnimation(DashboardMetricsAnimation.reveal) {
                dashboardMetricsAreRevealed = true
            }
        }
    }

    private var mealLogCountLabel: String {
        "\(store.todayLogs.count) item\(store.todayLogs.count == 1 ? "" : "s")"
    }

    private var selectedDateTitle: String {
        if Calendar.current.isDateInToday(store.selectedDate) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(store.selectedDate) {
            return "Yesterday"
        }
        return store.selectedDate.formatted(.dateTime.weekday(.wide))
    }

    private var selectedDateSubtitle: String {
        store.selectedDate.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var loggedMeals: [(meal: CalorieMealType, items: [CalorieLogItem])] {
        CalorieMealType.allCases.compactMap { meal in
            let items = store.logs(for: meal)
            return items.isEmpty ? nil : (meal, items)
        }
    }

    private var dashboardMealSections: [(meal: CalorieMealType, items: [CalorieLogItem], suggestions: [DashboardFoodSuggestion])] {
        CalorieMealType.allCases.compactMap { meal in
            let items = store.logs(for: meal)
            let suggestions = dashboardSuggestions.filter { $0.mealType == meal }
            guard !items.isEmpty || !suggestions.isEmpty else { return nil }
            return (meal, items, suggestions)
        }
    }

    private var dashboardInsightHash: String {
        let logKey = store.todayLogs
            .map { "\($0.id):\($0.name):\($0.calories):\($0.protein):\($0.carbs):\($0.fat):\($0.loggedAtMs)" }
            .joined(separator: "|")
        let weekKey = store.recentDaySummaries
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.totals.calories):\($0.value.logCount)" }
            .joined(separator: "|")
        return "\(store.selectedDate.timeIntervalSince1970)|\(store.goal.calories)|\(store.goal.protein)|\(logKey)|\(weekKey)|\(store.recentFoodMemories.map(\.id).joined(separator: ","))"
    }

    @MainActor
    private func refreshDashboardInsights() async {
        let hash = dashboardInsightHash
        let candidates = localDashboardSuggestionCandidates()
        dashboardSuggestions = balancedDashboardSuggestions(from: candidates)
        dashboardSummary = safeDashboardSummary(DashboardSummaryCache.summary(for: hash))
            ?? liveDashboardSummary()
            ?? ""

        guard remainingCalories > 0,
              !candidates.isEmpty,
              DashboardSummaryCache.canGenerateSummary(minimumAge: Self.dashboardInsightRefreshInterval),
              let payloadJSON = dashboardAIPayloadJSON(candidates: candidates),
              let content = try? await PiAgentRuntimeBackend.shared.dashboardFoodInsights(payloadJSON: payloadJSON),
              let insight = DashboardAIInsightResponse.parse(content)
        else { return }

        guard !Task.isCancelled, hash == dashboardInsightHash else { return }

        if !insight.summary.trimmed.isEmpty {
            if let safeSummary = safeDashboardSummary(insight.summary.trimmed) {
                dashboardSummary = safeSummary
                DashboardSummaryCache.store(summary: safeSummary, for: hash)
            } else {
                DashboardSummaryCache.removeSummary(for: hash)
                dashboardSummary = liveDashboardSummary() ?? ""
            }
        }
        if !insight.suggestionIDs.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            let ranked = insight.suggestionIDs.compactMap { byID[$0] }
            if !ranked.isEmpty {
                dashboardSuggestions = balancedDashboardSuggestions(from: ranked + candidates)
            }
        }
    }

    private func safeDashboardSummary(_ summary: String?) -> String? {
        guard let summary = summary?.trimmed.nilIfBlank else { return nil }
        let lower = summary.lowercased()
        guard lower.contains("calorie"),
              lower.contains("left") || lower.contains("over")
        else {
            return summary
        }

        let expected = Int(abs(remainingCalories).rounded())
        let numbers = lower.matches(of: /\d[\d,]*/).compactMap { match -> Int? in
            Int(String(match.output).replacingOccurrences(of: ",", with: ""))
        }
        guard !numbers.isEmpty else { return summary }
        return numbers.contains(expected) ? summary : nil
    }

    private func liveDashboardSummary() -> String? {
        let remaining = remainingCalories.rounded()
        let goal = store.goal.calories.rounded()
        guard goal > 0 else { return nil }

        if remaining > 0 {
            return "\(remaining.cleanString) calories left today."
        }
        if remaining < 0 {
            return "\((-remaining).cleanString) calories over today."
        }
        return "You are exactly at your calorie goal today."
    }

    private func dashboardAIPayloadJSON(candidates: [DashboardFoodSuggestion]) -> String? {
        let payload = DashboardAIInsightPayload(
            date: Self.dashboardDateFormatter.string(from: store.selectedDate),
            totals: store.todayTotals,
            goal: store.goal,
            logs: store.todayLogs.map {
                DashboardAILogItem(name: $0.name, meal: $0.mealType.rawValue, calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat)
            },
            week: store.recentDaySummaries
                .sorted { $0.key < $1.key }
                .suffix(7)
                .map { DashboardAIWeekDay(date: $0.key, calories: $0.value.totals.calories, protein: $0.value.totals.protein, carbs: $0.value.totals.carbs, fat: $0.value.totals.fat, logCount: $0.value.logCount) },
            candidates: candidates.map {
                DashboardAISuggestionCandidate(id: $0.id, name: $0.name, meal: $0.mealType.rawValue, detail: $0.detail, calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat)
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func localDashboardSuggestionCandidates() -> [DashboardFoodSuggestion] {
        guard remainingCalories > 0 else { return [] }

        var seen = Set<String>()
        var results: [DashboardFoodSuggestion] = []
        let preferredMeal = CalorieMealType.currentDefault
        let loggedFoodKeys = Set(store.todayLogs.map { Self.normalizedSuggestionKey($0.name) })
        let loggedMeals = Set(store.todayLogs.map(\.mealType))

        for item in store.recentFoodMemories {
            guard !loggedFoodKeys.contains(Self.normalizedSuggestionKey(item.displayName)),
                  shouldSuggestMeal(preferredMeal, loggedMeals: loggedMeals),
                  shouldSuggestCalories(item.calories)
            else { continue }
            let key = "\(preferredMeal.rawValue):\(Self.normalizedSuggestionKey(item.displayName))"
            guard seen.insert(key).inserted else { continue }
            results.append(DashboardFoodSuggestion(
                id: "canonical-\(item.id)-\(preferredMeal.rawValue)",
                sourceID: item.id,
                source: .canonical,
                name: item.title,
                detail: item.detail,
                mealType: preferredMeal,
                servingQuantity: item.defaultServingQty ?? 1,
                servingUnit: item.defaultServingUnit ?? "serving",
                servingWeight: item.defaultServingWeight,
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat
            ))
        }

        for food in StandardFoodDatabase.foods {
            let hintedMeals = food.mealHints
                .compactMap(CalorieMealType.init(rawValue:))
                .filter { $0 != .other }
            let meals = hintedMeals.isEmpty ? [preferredMeal] : hintedMeals
            for meal in meals {
                guard !loggedFoodKeys.contains(Self.normalizedSuggestionKey(food.name)),
                      shouldSuggestMeal(meal, loggedMeals: loggedMeals),
                      shouldSuggestCalories(food.calories)
                else { continue }
                let key = "\(meal.rawValue):\(Self.normalizedSuggestionKey(food.name))"
                guard seen.insert(key).inserted else { continue }
                results.append(DashboardFoodSuggestion(
                    id: "standard-\(food.id)-\(meal.rawValue)",
                    sourceID: food.id,
                    source: .standard,
                    name: food.name,
                    detail: food.detail,
                    mealType: meal,
                    servingQuantity: food.servingQuantity,
                    servingUnit: food.servingUnit,
                    servingWeight: food.servingWeight,
                    calories: food.calories,
                    protein: food.protein,
                    carbs: food.carbs,
                    fat: food.fat
                ))
            }
        }

        return results
    }

    private func balancedDashboardSuggestions(from candidates: [DashboardFoodSuggestion]) -> [DashboardFoodSuggestion] {
        guard remainingCalories > 0 else { return [] }

        var seen = Set<String>()
        var counts: [CalorieMealType: Int] = [:]
        var result: [DashboardFoodSuggestion] = []
        let maxPerMeal = remainingCalories < 250 ? 1 : 2
        let maxTotal: Int
        if remainingCalories < 150 {
            maxTotal = 1
        } else if remainingCalories < 450 {
            maxTotal = 2
        } else {
            maxTotal = 3
        }

        for suggestion in candidates
            .filter({ shouldSuggestCalories($0.calories) })
            .sorted(by: dashboardSuggestionSort)
        {
            let key = "\(suggestion.mealType.rawValue):\(Self.normalizedSuggestionKey(suggestion.name))"
            guard seen.insert(key).inserted else { continue }
            guard (counts[suggestion.mealType, default: 0]) < maxPerMeal else { continue }
            result.append(suggestion)
            counts[suggestion.mealType, default: 0] += 1
            if result.count >= maxTotal { break }
        }

        return result
    }

    private func shouldSuggestMeal(_ meal: CalorieMealType, loggedMeals: Set<CalorieMealType>) -> Bool {
        guard !loggedMeals.contains(meal) else { return false }
        if meal == .other { return false }
        if meal == .drink { return remainingCalories <= 250 || CalorieMealType.currentDefault == .snack }
        if meal == .snack { return remainingCalories <= 500 || CalorieMealType.currentDefault == .snack }
        return meal == CalorieMealType.currentDefault || remainingCalories >= 450
    }

    private func shouldSuggestCalories(_ calories: Double) -> Bool {
        guard remainingCalories > 0, calories > 0 else { return false }
        if remainingCalories < 120 {
            return calories <= remainingCalories
        }
        return calories <= remainingCalories + min(80, remainingCalories * 0.18)
    }

    private func dashboardSuggestionSort(_ lhs: DashboardFoodSuggestion, _ rhs: DashboardFoodSuggestion) -> Bool {
        let left = dashboardSuggestionScore(lhs)
        let right = dashboardSuggestionScore(rhs)
        if abs(left - right) > 0.001 {
            return left < right
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func dashboardSuggestionScore(_ suggestion: DashboardFoodSuggestion) -> Double {
        let target = dashboardSuggestionCalorieTarget(for: suggestion.mealType)
        let calorieFit = abs(suggestion.calories - target) / max(target, 1)
        let mealPenalty = suggestion.mealType == CalorieMealType.currentDefault ? 0.0 : 0.28
        let proteinBonus = min(suggestion.protein / 35, 1) * 0.12
        let sourcePenalty = suggestion.source == .canonical ? 0.0 : 0.08
        return calorieFit + mealPenalty + sourcePenalty - proteinBonus
    }

    private func dashboardSuggestionCalorieTarget(for meal: CalorieMealType) -> Double {
        let remaining = max(remainingCalories, 1)
        switch meal {
        case .breakfast, .lunch, .dinner:
            return min(max(remaining * 0.65, 180), 700)
        case .snack, .preWorkout, .postWorkout:
            return min(max(remaining * 0.45, 90), 320)
        case .drink:
            return min(max(remaining * 0.25, 40), 180)
        case .other:
            return min(max(remaining * 0.45, 120), 350)
        }
    }

    private static func normalizedSuggestionKey(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func logDashboardSuggestion(_ suggestion: DashboardFoodSuggestion) async {
        AppHaptics.medium()
        switch suggestion.source {
        case .canonical:
            await store.logCanonicalFood(
                suggestion.sourceID,
                mealType: suggestion.mealType,
                servingQty: suggestion.servingQuantity,
                servingUnit: suggestion.servingUnit,
                servingWeight: suggestion.servingWeight,
                calories: suggestion.calories,
                protein: suggestion.protein,
                carbs: suggestion.carbs,
                fat: suggestion.fat,
                notes: nil
            )
        case .standard:
            await store.logFood(
                name: suggestion.name,
                calories: suggestion.calories,
                protein: suggestion.protein,
                carbs: suggestion.carbs,
                fat: suggestion.fat,
                fiber: nil,
                sugars: nil,
                sodium: nil,
                potassium: nil,
                notes: "",
                sourceTitle: "Standard food",
                mealType: suggestion.mealType,
                photoData: nil,
                saveToLibrary: true,
                servingQty: suggestion.servingQuantity,
                servingUnit: suggestion.servingUnit,
                servingWeight: suggestion.servingWeight
            )
        }
    }

    private static let dashboardDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let dashboardInsightRefreshInterval: TimeInterval = 60 * 60

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(tint)
            .background(cardBackground(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func statPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DashboardTone.textSecondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func macroCard(title: String, value: Double, goal: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DashboardTone.textSecondary)
            Text("\(value.formatted(.number.precision(.fractionLength(0))))g")
                .font(.title3.weight(.bold))
                .foregroundStyle(DashboardTone.textPrimary)
            Text("/ \(goal.formatted(.number.precision(.fractionLength(0))))g")
                .font(.caption)
                .foregroundStyle(DashboardTone.textSecondary)
            ProgressView(value: min(value / max(goal, 1), 1.2), total: 1)
                .tint(tint)
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 20))
    }

    private func sectionHeader(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(DashboardTone.textPrimary)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DashboardTone.textSecondary)
            }
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DashboardTone.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(DashboardTone.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add food")
        }
    }
}

struct CalorieLibraryScreen: View {
    @Environment(DrawerController.self) private var drawerController
    @StateObject private var store = CalorieTrackerStore.shared
    @State private var activeSheet: LibrarySheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                favoriteSection
                recentFoodsSection
                librarySection
                templateSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .scrollDisabled(drawerController.progress > 0.001)
        .onChange(of: drawerController.progress) { _, progress in
            if progress > 0.001 {
                activeSheet = nil
            }
        }
        .onChange(of: drawerController.isOpen) { _, isOpen in
            if isOpen {
                activeSheet = nil
            }
        }
        .background(calorieBackground)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .stableBottomToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerMenuButton()
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                LibraryToolbarButton(systemName: "magnifyingglass", label: "Search library") {
                    guard canOpenLibrarySheet else { return }
                    AppHaptics.light()
                    activeSheet = .search
                }
                LibraryToolbarButton(systemName: "fork.knife", label: "Add food") {
                    guard canOpenLibrarySheet else { return }
                    AppHaptics.medium()
                    activeSheet = .food
                }
                LibraryToolbarButton(systemName: "book.closed", label: "Add recipe") {
                    guard canOpenLibrarySheet else { return }
                    AppHaptics.medium()
                    activeSheet = .recipe
                }
                LibraryToolbarButton(systemName: "square.stack.3d.up", label: "Add meal template") {
                    guard canOpenLibrarySheet else { return }
                    AppHaptics.medium()
                    activeSheet = .template
                }
            }
        }
        .task {
            await store.refresh()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .food:
                LibraryFoodEditorSheet(store: store, initialKind: "food")
            case .recipe:
                LibraryFoodEditorSheet(store: store, initialKind: "recipe")
            case .template:
                MealTemplateEditorSheet(store: store)
            case .libraryItem(let item):
                LibraryFoodEditorSheet(store: store, initialKind: item.kind, item: item)
            case .mealTemplate(let template):
                MealTemplateEditorSheet(store: store, template: template)
            case .recentFoods:
                FoodMemoryListScreen(store: store)
            case .recentFood(let item):
                CanonicalFoodEditorSheet(store: store, item: item)
            case .search:
                LibrarySearchScreen(store: store)
            }
        }
    }

    private var libraryHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(DashboardTone.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(DashboardTone.divider, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(DashboardTone.textPrimary)
                    Text("Reusable foods, recipes, and meal templates")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DashboardTone.textSecondary)
                }
            }

            HStack(spacing: 18) {
                libraryStat("Foods", "\(store.libraryItems.filter { $0.kind == "food" }.count)", DashboardTone.textPrimary)
                libraryStat("Recipes", "\(store.libraryItems.filter { $0.kind == "recipe" }.count)", DashboardTone.textPrimary)
                libraryStat("Favorites", "\(store.libraryItems.filter(\.isFavorite).count)", DashboardTone.textPrimary)
            }
            .padding(.top, 2)
        }
    }

    private var libraryActions: some View {
        HStack(spacing: 10) {
            libraryActionButton(title: "Food or Recipe", icon: "plus.circle.fill", tint: DashboardTone.accent) {
                activeSheet = .food
            }

            libraryActionButton(title: "Template", icon: "square.stack.3d.up.fill", tint: DashboardTone.accent) {
                activeSheet = .template
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            librarySectionTitle("Foods & Recipes", count: store.libraryItems.count)
            if store.libraryItems.isEmpty {
                emptyState("Save reusable foods and recipes here.", icon: "books.vertical")
            } else {
                ForEach(store.libraryItems) { item in
                    LibraryItemRow(item: item, store: store) {
                        guard canOpenLibrarySheet else { return }
                        AppHaptics.light()
                        activeSheet = .libraryItem(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentFoodsSection: some View {
        if !store.recentFoodMemories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    librarySectionTitle("Recent Foods", count: store.recentFoodMemories.count)
                    Spacer()
                    Button {
                        guard canOpenLibrarySheet else { return }
                        activeSheet = .recentFoods
                    } label: {
                        Text("Show All")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DashboardTone.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(store.recentFoodMemories.prefix(10)) { item in
                    FoodMemoryRow(item: item, onOpen: {
                        guard canOpenLibrarySheet else { return }
                        activeSheet = .recentFood(item)
                    }) {
                        Task { await store.logCanonicalFood(item.id, mealType: .currentDefault) }
                    }
                }
            }
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            librarySectionTitle("Meal Templates", count: store.mealTemplates.count)
            if store.mealTemplates.isEmpty {
                emptyState("Templates are fast repeated meals.", icon: "square.stack.3d.up")
            } else {
                ForEach(store.mealTemplates) { template in
                    MealTemplateRow(template: template, store: store) {
                        guard canOpenLibrarySheet else { return }
                        AppHaptics.light()
                        activeSheet = .mealTemplate(template)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoriteSection: some View {
        let favorites = store.libraryItems.filter(\.isFavorite)
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                librarySectionTitle("Favorites", count: favorites.count)
                ForEach(favorites) { item in
                    LibraryItemRow(item: item, store: store) {
                        guard canOpenLibrarySheet else { return }
                        AppHaptics.light()
                        activeSheet = .libraryItem(item)
                    }
                }
            }
        }
    }

    private func libraryActionButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var canOpenLibrarySheet: Bool {
        !drawerController.shouldSuppressContentInteractions
    }

    private func libraryStat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DashboardTone.textSecondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func librarySectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(DashboardTone.textPrimary)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(DashboardTone.textSecondary)
            Spacer()
        }
    }
}

private struct WeeklyMacroStrip: View {
    @ObservedObject var store: CalorieTrackerStore
    @State private var visibleWeekStart = Calendar.current.macrodexStartOfWeek(for: Date())

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var currentWeekStart: Date { calendar.macrodexStartOfWeek(for: today) }

    private var weekStarts: [Date] {
        (-156...0).compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: offset, to: currentWeekStart)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView(selection: $visibleWeekStart) {
                ForEach(weekStarts, id: \.self) { weekStart in
                    WeeklyMacroWeekView(
                        weekStart: weekStart,
                        selectedDate: store.selectedDate,
                        today: today,
                        goal: store.goal,
                        summary: { store.summary(for: $0) },
                        onSelectDate: { date in
                            AppHaptics.light()
                            Task { await store.selectDate(date) }
                        }
                    )
                    .tag(weekStart)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 68)
        }
        .onAppear {
            syncVisibleWeekToSelection()
        }
        .onChange(of: store.selectedDate) { _, _ in
            syncVisibleWeekToSelection()
        }
    }

    private func syncVisibleWeekToSelection() {
        let target = min(calendar.macrodexStartOfWeek(for: store.selectedDate), currentWeekStart)
        if weekStarts.contains(where: { calendar.isDate($0, inSameDayAs: target) }) {
            visibleWeekStart = target
        }
    }
}

private struct WeeklyMacroWeekView: View {
    let weekStart: Date
    let selectedDate: Date
    let today: Date
    let goal: CalorieGoal
    let summary: (Date) -> CalorieDaySummary
    let onSelectDate: (Date) -> Void

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.self) { date in
                let isFuture = date > today
                Button {
                    guard !isFuture else { return }
                    onSelectDate(date)
                } label: {
                    WeeklyMacroDayCell(
                        date: date,
                        summary: summary(date),
                        goal: goal,
                        isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                        isFuture: isFuture
                    )
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var days: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
}

private struct WeeklyMacroDayCell: View {
    let date: Date
    let summary: CalorieDaySummary
    let goal: CalorieGoal
    let isSelected: Bool
    let isFuture: Bool

    private let maxBarHeight: CGFloat = 34
    private let calorieTint = DashboardTone.accent

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                macroBar(value: summary.totals.calories, target: goal.calories, tint: calorieTint, width: 7)
                macroBar(value: summary.totals.protein, target: goal.protein, tint: DashboardTone.macroFill.opacity(0.86), width: 4)
                macroBar(value: summary.totals.carbs, target: goal.carbs, tint: DashboardTone.macroFill.opacity(0.66), width: 4)
                macroBar(value: summary.totals.fat, target: goal.fat, tint: DashboardTone.macroFill.opacity(0.48), width: 4)
            }
            .frame(height: maxBarHeight, alignment: .bottom)

            Text(date.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2.weight(isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? calorieTint : DashboardTone.textPrimary.opacity(isFuture ? 0.46 : 0.64))
                .frame(height: 15)

            Capsule()
                .fill(isSelected ? calorieTint : Color.clear)
                .frame(width: 12, height: 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .opacity(isFuture ? 0.62 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : (isFuture ? "Future day unavailable" : "Double tap to select"))
    }

    private func macroBar(value: Double, target: Double, tint: Color, width: CGFloat) -> some View {
        let progress = min(max(value / max(target, 1), 0), 1)
        let height = value > 0 ? max(4, maxBarHeight * progress) : 3
        return ZStack(alignment: .bottom) {
            Capsule()
                .fill(DashboardTone.divider.opacity(isFuture ? 0.72 : 1))
                .frame(width: width, height: maxBarHeight)
            Capsule()
                .fill(isFuture ? DashboardTone.textSecondary.opacity(0.44) : tint)
                .frame(width: width, height: height)
        }
    }

    private var accessibilityLabel: String {
        "\(date.formatted(.dateTime.weekday(.wide).month().day())), \(summary.totals.calories.cleanString) calories, protein \(summary.totals.protein.cleanString) grams, carbs \(summary.totals.carbs.cleanString) grams, fat \(summary.totals.fat.cleanString) grams"
    }
}

private struct MealLogSection: View {
    let meal: CalorieMealType
    let items: [CalorieLogItem]
    @ObservedObject var store: CalorieTrackerStore
    let onOpenMeal: () -> Void
    let onOpenItem: (CalorieLogItem) -> Void

    private var calories: Double {
        items.reduce(0) { $0 + $1.calories }
    }

    private var protein: Double {
        items.reduce(0) { $0 + $1.protein }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AppHaptics.light()
                onOpenMeal()
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: meal.systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DashboardTone.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(DashboardTone.divider, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(DashboardTone.textPrimary)
                        Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(protein.cleanString)g protein")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardTone.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(calories.formatted(.number.precision(.fractionLength(0))))
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(DashboardTone.textPrimary)
                        Text("kcal")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DashboardTone.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meal.title)
            .accessibilityValue("\(items.count) item\(items.count == 1 ? "" : "s"), \(calories.cleanString) kilocalories, \(protein.cleanString) grams protein")
            .accessibilityHint("Opens meal details")

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    CalorieLogRow(item: item, store: store) {
                        onOpenItem(item)
                    }
                    if index < items.count - 1 {
                        Divider()
                            .overlay(DashboardTone.divider)
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(DashboardTone.divider.opacity(0.56), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private enum DashboardSuggestionSource: String {
    case canonical
    case standard
}

private enum DashboardSummaryCache {
    private static let storageKey = "dashboard.aiSummaryCache.v1"
    private static let legacyStorageKey = "dashboard.aiSummaryCache.legacy.v1"

    private struct Entry: Codable {
        let summary: String
        let generatedAt: TimeInterval
    }

    private struct Payload: Codable {
        var entries: [String: Entry] = [:]
        var lastSummary: String?
        var lastGeneratedAt: TimeInterval?
    }

    static func summary(for hash: String) -> String? {
        load().entries[hash]?.summary.trimmed.nilIfBlank
    }

    static func recentSummary(minimumAge: TimeInterval, now: Date = Date()) -> String? {
        let payload = load()
        guard let generatedAt = payload.lastGeneratedAt,
              now.timeIntervalSince1970 - generatedAt < minimumAge
        else { return nil }
        return payload.lastSummary?.trimmed.nilIfBlank
    }

    static func canGenerateSummary(minimumAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let generatedAt = load().lastGeneratedAt else { return true }
        return now.timeIntervalSince1970 - generatedAt >= minimumAge
    }

    static func store(summary: String, for hash: String) {
        let trimmed = summary.trimmed
        guard !trimmed.isEmpty else { return }
        var payload = load()
        let generatedAt = Date().timeIntervalSince1970
        payload.entries[hash] = Entry(summary: trimmed, generatedAt: generatedAt)
        payload.lastSummary = trimmed
        payload.lastGeneratedAt = generatedAt
        save(payload)
    }

    static func removeSummary(for hash: String) {
        var payload = load()
        payload.entries.removeValue(forKey: hash)
        save(payload)
    }

    private static func load() -> Payload {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return payload
        }

        if let legacy = defaults.dictionary(forKey: storageKey) as? [String: String] {
            let generatedAt = Date().timeIntervalSince1970
            let entries = legacy.reduce(into: [String: Entry]()) { partial, pair in
                let trimmed = pair.value.trimmed
                guard !trimmed.isEmpty else { return }
                partial[pair.key] = Entry(summary: trimmed, generatedAt: generatedAt)
            }
            let lastSummary = entries.values.sorted { $0.generatedAt > $1.generatedAt }.first?.summary
            let payload = Payload(entries: entries, lastSummary: lastSummary, lastGeneratedAt: lastSummary == nil ? nil : generatedAt)
            defaults.set(legacy, forKey: legacyStorageKey)
            save(payload)
            return payload
        }

        return Payload()
    }

    private static func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private struct DashboardFoodSuggestion: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let source: DashboardSuggestionSource
    let name: String
    let detail: String
    let mealType: CalorieMealType
    let servingQuantity: Double
    let servingUnit: String
    let servingWeight: Double?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

private struct MealSuggestionHeader: View {
    let meal: CalorieMealType

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: meal.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DashboardTone.textSecondary)
                .frame(width: 28, height: 28)
                .background(DashboardTone.divider.opacity(0.56), in: Circle())
            Text(meal.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(DashboardTone.textPrimary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meal.title)
    }
}

private struct DashboardSuggestionsSection: View {
    let suggestions: [DashboardFoodSuggestion]
    let onQuickAdd: (DashboardFoodSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggestions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DashboardTone.textSecondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    HStack(spacing: 12) {
                        FoodIconView(foodName: suggestion.name, size: 36)
                            .opacity(0.72)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DashboardTone.textPrimary.opacity(0.74))
                                .lineLimit(1)
                            Text(suggestion.detail)
                                .font(.caption)
                                .foregroundStyle(DashboardTone.textSecondary.opacity(0.86))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            onQuickAdd(suggestion)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DashboardTone.textPrimary)
                        .background(DashboardTone.textPrimary.opacity(0.08), in: Circle())
                        .accessibilityLabel("Log \(suggestion.name)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())

                    if index < suggestions.count - 1 {
                        Divider()
                            .overlay(DashboardTone.divider)
                            .padding(.leading, 60)
                    }
                }
            }
            .background(DashboardTone.divider.opacity(0.30), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct CalorieLogRow: View {
    let item: CalorieLogItem
    @ObservedObject var store: CalorieTrackerStore
    let onOpen: () -> Void
    @State private var showDeleteConfirmation = false

    var body: some View {
        FoodSwipeActionRow(
            leading: [
                FoodSwipeAction(
                    title: item.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: item.isFavorite ? "star.slash" : "star",
                    tint: .yellow,
                    action: { Task { await store.toggleFavoriteForLogItem(item.id) } }
                ),
                FoodSwipeAction(
                    title: "Duplicate",
                    systemImage: "plus.square.on.square",
                    tint: DashboardTone.accent,
                    action: { Task { await store.duplicateLogItem(item.id) } }
                )
            ],
            trailing: [
                FoodSwipeAction(
                    title: "Delete",
                    systemImage: "trash",
                    tint: DashboardTone.danger,
                    action: { showDeleteConfirmation = true }
                )
            ],
            onTap: {
                AppHaptics.light()
                onOpen()
            },
            accessibilityLabel: item.name,
            accessibilityValue: "\(item.calories.cleanString) kilocalories, \(item.subtitle)",
            accessibilityHint: "Opens food details"
        ) {
            rowContent
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("Details", systemImage: "info.circle")
            }

            Button {
                Task { await store.duplicateLogItem(item.id) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Button {
                Task { await store.duplicateLogItem(item.id, toToday: true) }
            } label: {
                Label("Log Today", systemImage: "calendar.badge.plus")
            }

            Button {
                Task { await store.toggleFavoriteForLogItem(item.id) }
            } label: {
                Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
            }

            Menu("Move to...") {
                ForEach(CalorieMealType.allCases.filter { $0 != item.mealType }) { meal in
                    Button {
                        Task { await store.moveLogItem(item.id, to: meal) }
                    } label: {
                        Label(meal.title, systemImage: meal.systemImage)
                    }
                }
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Log", systemImage: "trash")
            }
        } preview: {
            rowContent
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 320)
                .background(DashboardTone.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DashboardTone.textPrimary.opacity(0.10), lineWidth: 1)
                )
        }
        .confirmationDialog("Delete this food log?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Food Log", role: .destructive) {
                Task { await store.softDeleteLogItem(item.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            attachmentThumb
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textPrimary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.servingDescription)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DashboardTone.textPrimary.opacity(0.72))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(DashboardTone.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.calories.formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(DashboardTone.textPrimary)
                Text("kcal")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DashboardTone.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var attachmentThumb: some View {
        if let image = store.image(for: item.id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            FoodIconView(foodName: item.name, size: 40)
        }
    }
}

private struct FoodSwipeAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

private struct FoodSwipeActionRow<Content: View>: View {
    @Environment(DrawerController.self) private var drawerController
    let leading: [FoodSwipeAction]
    let trailing: [FoodSwipeAction]
    var onTap: (() -> Void)? = nil
    var accessibilityLabel: String?
    var accessibilityValue: String?
    var accessibilityHint: String?
    @ViewBuilder let content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var isActivated = false
    @State private var dragStartOffsetX: CGFloat = 0
    @State private var rejectedUntilLift = false
    @State private var suppressTapUntil = Date.distantPast

    private let leadingActionWidth: CGFloat = 60
    private let leadingActionSpacing: CGFloat = 8
    private let leadingActionGap: CGFloat = 12
    private let trailingActionWidth: CGFloat = 74
    private let trailingActionGap: CGFloat = 12
    private let actionCornerRadius: CGFloat = 14
    private let activationDistance: CGFloat = 18
    private let actionRevealThreshold: CGFloat = 10
    private let actionMinimumVisibleWidth: CGFloat = 18
    private var leadingRevealWidth: CGFloat {
        guard !leading.isEmpty else { return 0 }
        return leadingActionWidth * CGFloat(leading.count)
            + leadingActionSpacing * CGFloat(max(leading.count - 1, 0))
            + leadingActionGap
    }
    private var trailingRevealWidth: CGFloat {
        trailing.isEmpty ? 0 : trailingActionGap + trailingActionWidth * CGFloat(trailing.count)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                actionStrip(actions: leading, side: .leading)
                    .opacity(actionRevealProgress(side: .leading))
                    .accessibilityHidden(offsetX <= 1)
                Spacer(minLength: 0)
                actionStrip(actions: trailing, side: .trailing)
                    .opacity(actionRevealProgress(side: .trailing))
                    .accessibilityHidden(offsetX >= -1)
            }
            .zIndex(2)

            contentLayer
                .zIndex(1)
        }
        .contentShape(Rectangle())
        .clipped()
        .onChange(of: drawerController.shouldSuppressContentInteractions) { _, shouldSuppress in
            if shouldSuppress {
                resetSwipeState()
            }
        }
    }

    @ViewBuilder
    private var contentLayer: some View {
        let surface = content()
            .offset(x: offsetX)
            .contentShape(Rectangle())

        if onTap == nil {
            surface
                .highPriorityGesture(rowGesture(minimumDistance: activationDistance, allowsTap: false))
        } else {
            Button {
                handleContentTap()
            } label: {
                surface
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel ?? "")
            .accessibilityValue(rowAccessibilityValue)
            .accessibilityHint(accessibilityHint ?? "")
            .highPriorityGesture(rowGesture(minimumDistance: activationDistance, allowsTap: false))
        }
    }

    private enum ActionSide {
        case leading
        case trailing
    }

    private func actionStrip(actions: [FoodSwipeAction], side: ActionSide) -> some View {
        let visibleWidth = actionVisibleWidth(side: side)
        return HStack(spacing: 0) {
            if side == .trailing, !actions.isEmpty, visibleWidth > 0 {
                Color.clear
                    .frame(width: min(trailingActionGap, visibleWidth))
            }

            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let buttonWidth = visibleButtonWidth(forActionAt: index, actionCount: actions.count, side: side)
                let contentOpacity = max(0, min(1, (buttonWidth - 24) / 20))
                if buttonWidth > 0 {
                    Button {
                        suppressContentTapBriefly(duration: 0.45)
                        action.action()
                        springBack()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 15, weight: .bold))
                            Text(action.title)
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(Color.white)
                        .opacity(contentOpacity)
                        .frame(width: buttonWidth)
                        .frame(maxHeight: .infinity)
                        .background(action.tint, in: RoundedRectangle(cornerRadius: actionCornerRadius, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: actionCornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: actionCornerRadius, style: .continuous))
                    .accessibilityIdentifier(actionAccessibilityIdentifier(action))
                    .accessibilityHidden(buttonWidth < actionMinimumVisibleWidth)
                }

                if side == .leading,
                   index < actions.count - 1,
                   leadingSpacingVisible(afterActionAt: index, actionCount: actions.count) {
                    Color.clear
                        .frame(width: leadingActionSpacing)
                }
            }

            if side == .leading, !actions.isEmpty, visibleWidth > 0 {
                Color.clear
                    .frame(width: min(leadingActionGap, visibleWidth))
            }
        }
        .frame(width: visibleWidth, alignment: side == .leading ? .leading : .trailing)
    }

    private func springBack() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            offsetX = 0
        }
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        max(-trailingRevealWidth, min(leadingRevealWidth, value))
    }

    private func rowGesture(minimumDistance: CGFloat, allowsTap: Bool) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .local)
            .onChanged { gesture in
                handleDragChanged(gesture)
            }
            .onEnded { gesture in
                handleDragEnded(gesture, allowsTap: allowsTap)
            }
    }

    private func handleDragChanged(_ gesture: DragGesture.Value) {
        guard !drawerController.shouldSuppressContentInteractions else {
            resetSwipeState()
            return
        }
        guard !rejectedUntilLift else { return }
        let dx = gesture.translation.width
        let dy = gesture.translation.height
        if !isActivated {
            if abs(dy) > 10, abs(dy) > abs(dx) * 0.9 {
                rejectedUntilLift = true
                return
            }
            let rowIsOpen = abs(offsetX) > 1
            let requiredDistance: CGFloat = rowIsOpen ? 10 : 22
            let requiredDominance: CGFloat = rowIsOpen ? 1.12 : 1.62
            guard abs(dx) > requiredDistance, abs(dx) > abs(dy) * requiredDominance else { return }
            dragStartOffsetX = offsetX
            isActivated = true
            suppressContentTapBriefly(duration: 0.55)
        }
        let rawOffset = dragStartOffsetX + dx
        if dragStartOffsetX > 1 {
            offsetX = max(0, min(leadingRevealWidth, rawOffset))
        } else if dragStartOffsetX < -1 {
            offsetX = min(0, max(-trailingRevealWidth, rawOffset))
        } else {
            offsetX = clampedOffset(rawOffset)
        }
    }

    private func handleDragEnded(_ gesture: DragGesture.Value, allowsTap: Bool) {
        let didActivate = isActivated
        let dragStartOffset = dragStartOffsetX
        defer {
            isActivated = false
            dragStartOffsetX = 0
            rejectedUntilLift = false
        }

        if didActivate {
            suppressContentTapBriefly(duration: 0.55)
            let draggedTowardCenter = (dragStartOffset > 1 && gesture.translation.width < -10)
                || (dragStartOffset < -1 && gesture.translation.width > 10)
            if abs(dragStartOffset) > 1, draggedTowardCenter {
                springBack()
                return
            }
            let predictedOffset = clampedOffset(dragStartOffset + gesture.predictedEndTranslation.width)
            let activeRevealWidth = (offsetX < 0 || dragStartOffset < 0) ? trailingRevealWidth : leadingRevealWidth
            let shouldStayOpen = abs(offsetX) > activeRevealWidth * 0.42 || abs(predictedOffset) > activeRevealWidth * 0.72
            if shouldStayOpen {
                let finalOffset = abs(predictedOffset) > abs(offsetX) ? predictedOffset : offsetX
                withAnimation(.easeOut(duration: 0.18)) {
                    offsetX = finalOffset > 0 ? leadingRevealWidth : -trailingRevealWidth
                }
            } else {
                springBack()
            }
            return
        }

        guard allowsTap else { return }
        let distance = hypot(gesture.translation.width, gesture.translation.height)
        guard distance < 8 else { return }
        handleContentTap()
    }

    private func handleContentTap() {
        guard let onTap else { return }
        guard !drawerController.shouldSuppressContentInteractions else { return }
        guard Date() >= suppressTapUntil else { return }
        if abs(offsetX) > 1 {
            suppressContentTapBriefly(duration: 0.35)
            springBack()
            return
        }
        onTap()
    }

    private func suppressContentTapBriefly(duration: TimeInterval) {
        suppressTapUntil = max(suppressTapUntil, Date().addingTimeInterval(duration))
    }

    private var rowAccessibilityValue: String {
        var parts: [String] = []
        if let accessibilityValue, !accessibilityValue.isEmpty {
            parts.append(accessibilityValue)
        }
        if let visibleActionsDescription {
            parts.append("Swipe actions visible: \(visibleActionsDescription)")
        }
        return parts.joined(separator: ", ")
    }

    private var visibleActionsDescription: String? {
        let visibleActions: [FoodSwipeAction]
        if offsetX > 1 {
            visibleActions = leading
        } else if offsetX < -1 {
            visibleActions = trailing
        } else {
            return nil
        }
        guard !visibleActions.isEmpty else { return nil }
        return visibleActions.map(\.title).joined(separator: ", ")
    }

    private func revealWidth(side: ActionSide) -> CGFloat {
        switch side {
        case .leading:
            return leading.isEmpty ? 0 : leadingRevealWidth
        case .trailing:
            return trailingRevealWidth
        }
    }

    private func actionWidth(side: ActionSide, actionCount: Int) -> CGFloat {
        switch side {
        case .leading:
            return leadingActionWidth
        case .trailing:
            return trailingActionWidth
        }
    }

    private func visibleButtonWidth(forActionAt index: Int, actionCount: Int, side: ActionSide) -> CGFloat {
        let visibleWidth = actionVisibleWidth(side: side)
        guard visibleWidth > 0 else { return 0 }

        switch side {
        case .trailing:
            let afterGap = max(0, visibleWidth - trailingActionGap)
            return min(trailingActionWidth, afterGap)

        case .leading:
            let trailingGapWidth = min(leadingActionGap, visibleWidth)
            var remaining = max(0, visibleWidth - trailingGapWidth)
            let reversedIndex = actionCount - 1 - index
            for revealIndex in 0..<actionCount {
                if revealIndex > 0 {
                    remaining = max(0, remaining - leadingActionSpacing)
                }
                let width = min(leadingActionWidth, remaining)
                if revealIndex == reversedIndex {
                    return width
                }
                remaining = max(0, remaining - leadingActionWidth)
            }
            return 0
        }
    }

    private func leadingSpacingVisible(afterActionAt index: Int, actionCount: Int) -> Bool {
        guard index < actionCount - 1 else { return false }
        let visibleWidth = actionVisibleWidth(side: .leading)
        let trailingGapWidth = min(leadingActionGap, visibleWidth)
        let innerActionWidth = max(0, visibleWidth - trailingGapWidth)
        let actionsToTheRight = actionCount - 1 - index
        let threshold = CGFloat(actionsToTheRight) * leadingActionWidth
        return innerActionWidth > threshold
    }

    private func actionRevealProgress(side: ActionSide) -> CGFloat {
        let width = revealWidth(side: side)
        guard width > 0 else { return 0 }
        let dragDistance = actionDragDistance(side: side)
        guard dragDistance > actionRevealThreshold else { return 0 }
        let effectiveWidth = max(width - actionRevealThreshold, 1)
        return max(0, min(1, (dragDistance - actionRevealThreshold) / effectiveWidth))
    }

    private func actionVisibleWidth(side: ActionSide) -> CGFloat {
        let width = revealWidth(side: side)
        let progress = actionRevealProgress(side: side)
        guard progress > 0 else { return 0 }
        let gap = actionGap(side: side)
        let minimumVisibleWidth = gap + actionMinimumVisibleWidth
        let dragDistance = actionDragDistance(side: side)
        guard dragDistance >= minimumVisibleWidth else { return 0 }
        let easedWidth = minimumVisibleWidth + (width - minimumVisibleWidth) * progress
        return min(width, dragDistance, easedWidth)
    }

    private func actionDragDistance(side: ActionSide) -> CGFloat {
        switch side {
        case .leading:
            return max(0, offsetX)
        case .trailing:
            return max(0, -offsetX)
        }
    }

    private func actionGap(side: ActionSide) -> CGFloat {
        switch side {
        case .leading:
            return leadingActionGap
        case .trailing:
            return trailingActionGap
        }
    }

    private func actionClipAlignment(side: ActionSide) -> Alignment {
        switch side {
        case .leading:
            return .trailing
        case .trailing:
            return .leading
        }
    }

    private func actionAccessibilityIdentifier(_ action: FoodSwipeAction) -> String {
        let slug = action.title
            .lowercased()
            .replacingOccurrences(of: " ", with: ".")
        return "food.swipe.\(slug)"
    }

    private func resetSwipeState() {
        isActivated = false
        dragStartOffsetX = 0
        rejectedUntilLift = false
        suppressContentTapBriefly(duration: 0.25)
        if abs(offsetX) > 0.5 {
            springBack()
        } else {
            offsetX = 0
        }
    }
}

private struct CalorieLogItemDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let item: CalorieLogItem

    @State private var name = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var servingQuantity = "1"
    @State private var servingUnit = "serving"
    @State private var servingWeight = ""
    @State private var notes = ""
    @State private var mealType: CalorieMealType = .other
    @State private var showDeleteConfirmation = false
    @State private var recipeComponents: [RecipeComponentItem] = []

    private var activeItem: CalorieLogItem {
        store.todayLogs.first(where: { $0.id == item.id }) ?? item
    }

    private var activeLibraryItem: CalorieLibraryItem? {
        guard let libraryItemId = activeItem.libraryItemId else { return nil }
        return store.libraryItems.first(where: { $0.id == libraryItemId })
    }

    private var activeRecipe: CalorieLibraryItem? {
        guard activeLibraryItem?.kind == "recipe" else { return nil }
        return activeLibraryItem
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    detailHeader
                }

                Section("Food") {
                    TextField("Name", text: $name)
                    Picker("Meal", selection: $mealType) {
                        ForEach(CalorieMealType.allCases) { meal in
                            Label(meal.title, systemImage: meal.systemImage).tag(meal)
                        }
                    }
                }

                Section("Serving") {
                    servingEditorRow
                    if servingUnitSupportsWeight {
                        detailNumberRow("Weight", unit: "g", text: $servingWeight)
                    }
                }

                Section("Nutrition") {
                    detailNumberRow("Calories", unit: "kcal", text: $calories)
                    detailNumberRow("Protein", unit: "g", text: $protein)
                    detailNumberRow("Carbs", unit: "g", text: $carbs)
                    detailNumberRow("Fat", unit: "g", text: $fat)
                }

                if let activeRecipe {
                    recipeDetailsSection(activeRecipe)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...8)
                }

                Section("Actions") {
                    Button {
                        Task {
                            AppHaptics.medium()
                            await store.duplicateLogItem(item.id)
                            dismiss()
                        }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Button {
                        Task {
                            AppHaptics.medium()
                            await store.duplicateLogItem(item.id, toToday: true)
                            dismiss()
                        }
                    } label: {
                        Label("Log Today", systemImage: "calendar.badge.plus")
                    }
                }

                Section("Move") {
                    ForEach(CalorieMealType.allCases.filter { $0 != mealType }) { meal in
                        Button {
                            Task {
                                AppHaptics.light()
                                await store.moveLogItem(item.id, to: meal)
                                dismiss()
                            }
                        } label: {
                            Label(meal.title, systemImage: meal.systemImage)
                        }
                    }
                }

                Section {
                    Button("Delete Food Log", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(DashboardTone.textPrimary)
            .navigationTitle("Food Details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: populate)
            .task(id: activeItem.libraryItemId) {
                await loadRecipeDetailsIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            AppHaptics.light()
                            await store.toggleFavoriteForLogItem(item.id)
                        }
                    } label: {
                        Image(systemName: activeItem.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(activeItem.isFavorite ? DashboardTone.accent : DashboardTone.textPrimary)
                    }
                    .accessibilityLabel(activeItem.isFavorite ? "Remove favorite" : "Favorite")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            AppHaptics.medium()
                            await store.updateLogItem(
                                item.id,
                                name: name,
                                calories: calories.doubleValue,
                                protein: protein.doubleValue,
                                carbs: carbs.doubleValue,
                                fat: fat.doubleValue,
                                servingCount: servingQuantity.optionalDouble,
                                unit: servingUnit,
                                weight: servingWeight.optionalDouble,
                                notes: notes,
                                mealType: mealType
                            )
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Save")
                    .disabled(name.trimmed.isEmpty || calories.doubleValue <= 0)
                }
            }
            .confirmationDialog("Delete this food log?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        AppHaptics.medium()
                        await store.softDeleteLogItem(item.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 14) {
            if let image = store.image(for: activeItem.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                FoodIconView(foodName: name.isEmpty ? activeItem.name : name, size: 52)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? activeItem.name : name)
                    .font(.headline.weight(.semibold))
                Text("\(servingQuantity.trimmed.nilIfBlank ?? activeItem.servingDescription) \(servingUnit.trimmed.nilIfBlank ?? "serving") · \(calories.isEmpty ? activeItem.calories.cleanString : calories) kcal · \(mealType.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func recipeDetailsSection(_ recipe: CalorieLibraryItem) -> some View {
        Section("Recipe") {
            HStack(spacing: 12) {
                FoodIconView(foodName: recipe.name, fallbackSystemName: "list.bullet.clipboard", size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name)
                        .font(.subheadline.weight(.semibold))
                    Text(recipe.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if recipeComponents.isEmpty {
                Text("No ingredients saved for this recipe.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recipeComponents) { component in
                    HStack(spacing: 12) {
                        FoodIconView(foodName: component.componentName, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.componentName)
                                .font(.subheadline.weight(.semibold))
                            Text(component.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(component.calories.formatted(.number.precision(.fractionLength(0))))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func populate() {
        let source = activeItem
        name = source.name
        calories = source.calories.cleanString
        protein = source.protein.cleanString
        carbs = source.carbs.cleanString
        fat = source.fat.cleanString
        servingUnit = source.unit?.trimmed.nilIfBlank ?? activeLibraryItem?.defaultServingUnit ?? "serving"
        if source.unit == nil, let defaultServingQty = activeLibraryItem?.defaultServingQty {
            servingQuantity = defaultServingQty.cleanString
        } else {
            servingQuantity = (source.servingCount ?? activeLibraryItem?.defaultServingQty ?? 1).cleanString
        }
        if let weight = source.weight ?? activeLibraryItem?.defaultServingWeight {
            servingWeight = weight.cleanString
        } else {
            servingWeight = ""
        }
        notes = source.notes ?? ""
        mealType = source.mealType
    }

    private func loadRecipeDetailsIfNeeded() async {
        guard let recipeId = activeRecipe?.id else {
            recipeComponents = []
            return
        }
        recipeComponents = await store.loadRecipeComponents(recipeId: recipeId)
    }

    private func detailNumberRow(_ label: String, unit: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 96)
            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    private var servingEditorRow: some View {
        HStack(spacing: 8) {
            Text("Amount")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 68, alignment: .leading)
            Spacer(minLength: 4)
            Button {
                adjustServing(by: -servingStep)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(servingQuantity.doubleValue <= servingStep)
            .accessibilityLabel("Decrease serving")

            TextField("1", text: $servingQuantity)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 50)
                .onChange(of: servingQuantity) { _, _ in
                    recalculateNutritionFromServing()
                }

            TextField("Unit", text: $servingUnit)
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.leading)
                .frame(width: 72)
                .onChange(of: servingUnit) { _, _ in
                    recalculateNutritionFromServing()
                }

            Button {
                adjustServing(by: servingStep)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Increase serving")
        }
    }

    private var servingUnitSupportsWeight: Bool {
        let unit = servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["g", "gram", "grams"].contains(unit)
    }

    private var servingStep: Double {
        let unit = servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains(unit) {
            return 25
        }
        return 1
    }

    private func adjustServing(by delta: Double) {
        let current = servingQuantity.doubleValue > 0 ? servingQuantity.doubleValue : 0
        let next = max(servingStep == 1 ? 1 : servingStep, current + delta)
        servingQuantity = next.cleanString
        if ["g", "gram", "grams"].contains(servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            servingWeight = next.cleanString
        }
        recalculateNutritionFromServing()
    }

    private func recalculateNutritionFromServing() {
        let quantity = max(servingQuantity.doubleValue, 0)
        guard quantity > 0 else { return }
        let perUnit = nutritionPerServingUnit()
        calories = (perUnit.calories * quantity).cleanString
        protein = (perUnit.protein * quantity).cleanString
        carbs = (perUnit.carbs * quantity).cleanString
        fat = (perUnit.fat * quantity).cleanString
    }

    private func nutritionPerServingUnit() -> CalorieTotals {
        if let activeLibraryItem {
            let divisor = max(activeLibraryItem.defaultServingQty ?? 1, 0.0001)
            return CalorieTotals(
                calories: activeLibraryItem.calories / divisor,
                protein: activeLibraryItem.protein / divisor,
                carbs: activeLibraryItem.carbs / divisor,
                fat: activeLibraryItem.fat / divisor
            )
        }
        let divisor = max(activeItem.servingCount ?? 1, 0.0001)
        return CalorieTotals(
            calories: activeItem.calories / divisor,
            protein: activeItem.protein / divisor,
            carbs: activeItem.carbs / divisor,
            fat: activeItem.fat / divisor
        )
    }
}

private struct MealLogDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let meal: CalorieMealType
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteLogItem: CalorieLogItem?

    private var items: [CalorieLogItem] {
        store.logs(for: meal)
    }

    private var totals: CalorieTotals {
        items.reduce(into: CalorieTotals()) { partial, item in
            partial.calories += item.calories
            partial.protein += item.protein
            partial.carbs += item.carbs
            partial.fat += item.fat
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: meal.systemImage)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(DashboardTone.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(DashboardTone.divider, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meal.title)
                                .font(.headline.weight(.semibold))
                            Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(totals.calories.cleanString) kcal")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                    }
                    mealMacroRow
                }

                Section("Items") {
                    if items.isEmpty {
                        Text("No food logged in this meal.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                FoodIconView(foodName: item.name, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(item.calories.cleanString)")
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                            }
                            .contextMenu {
                                Button {
                                    Task { await store.duplicateLogItem(item.id) }
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    Task { await store.toggleFavoriteForLogItem(item.id) }
                                } label: {
                                    Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
                                }
                                Button {
                                    Task { await store.duplicateLogItem(item.id, toToday: true) }
                                } label: {
                                    Label("Log Today", systemImage: "calendar.badge.plus")
                                }
                                Button(role: .destructive) {
                                    pendingDeleteLogItem = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task { await store.toggleFavoriteForLogItem(item.id) }
                                } label: {
                                    Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
                                }
                                .tint(.yellow)

                                Button {
                                    Task { await store.duplicateLogItem(item.id) }
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                .tint(DashboardTone.accent)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteLogItem = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("Actions") {
                    Button {
                        Task {
                            AppHaptics.medium()
                            await store.duplicateMeal(meal)
                            dismiss()
                        }
                    } label: {
                        Label("Duplicate Meal", systemImage: "plus.square.on.square")
                    }

                    Button {
                        Task {
                            AppHaptics.medium()
                            await store.duplicateMeal(meal, toToday: true)
                            dismiss()
                        }
                    } label: {
                        Label("Log Today", systemImage: "calendar.badge.plus")
                    }
                }

                Section("Move Meal") {
                    ForEach(CalorieMealType.allCases.filter { $0 != meal }) { target in
                        Button {
                            Task {
                                AppHaptics.light()
                                await store.moveMeal(meal, to: target)
                                dismiss()
                            }
                        } label: {
                            Label(target.title, systemImage: target.systemImage)
                        }
                    }
                }

                Section {
                    Button("Delete Meal", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(DashboardTone.textPrimary)
            .navigationTitle(meal.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Meal", role: .destructive) {
                    Task {
                        AppHaptics.medium()
                        await store.deleteMeal(meal)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete this food log?",
                isPresented: Binding(
                    get: { pendingDeleteLogItem != nil },
                    set: { if !$0 { pendingDeleteLogItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Food Log", role: .destructive) {
                    guard let item = pendingDeleteLogItem else { return }
                    Task {
                        await store.softDeleteLogItem(item.id)
                        pendingDeleteLogItem = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteLogItem = nil
                }
            }
        }
    }

    private var mealMacroRow: some View {
        HStack(spacing: 16) {
            mealMacro("Protein", totals.protein, "g")
            mealMacro("Carbs", totals.carbs, "g")
            mealMacro("Fat", totals.fat, "g")
        }
        .padding(.top, 4)
    }

    private func mealMacro(_ label: String, _ value: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value.cleanString)\(unit)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryItemRow: View {
    let item: CalorieLibraryItem
    @ObservedObject var store: CalorieTrackerStore
    let onOpen: () -> Void
    @State private var showDeleteConfirmation = false

    var body: some View {
        FoodSwipeActionRow(
            leading: [
                FoodSwipeAction(
                    title: item.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: item.isFavorite ? "star.slash" : "star",
                    tint: .yellow,
                    action: { Task { await store.toggleFavorite(item.id) } }
                ),
                FoodSwipeAction(
                    title: "Log",
                    systemImage: "plus.circle",
                    tint: DashboardTone.accent,
                    action: { Task { await store.logLibraryItem(item.id, mealType: .currentDefault) } }
                )
            ],
            trailing: [
                FoodSwipeAction(
                    title: "Delete",
                    systemImage: "trash",
                    tint: DashboardTone.danger,
                    action: { showDeleteConfirmation = true }
                )
            ]
        ) {
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        FoodIconView(foodName: item.name, fallbackSystemName: item.kind == "recipe" ? "list.bullet.clipboard" : "takeoutbag.and.cup.and.straw", size: 42)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DashboardTone.textPrimary)
                                .lineLimit(1)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(DashboardTone.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(item.name) details")

                HStack(spacing: 12) {
                    Button {
                        Task { await store.toggleFavorite(item.id) }
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(item.isFavorite ? DashboardTone.accent : DashboardTone.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isFavorite ? "Remove \(item.name) from favorites" : "Add \(item.name) to favorites")

                    Button {
                        Task { await store.logLibraryItem(item.id, mealType: .currentDefault) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(DashboardTone.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(item.name) today")
                }
            }
            .padding(14)
            .background(cardBackground(cornerRadius: 20))
        }
        .contextMenu {
            Button(action: onOpen) {
                Label("View Details", systemImage: "info.circle")
            }

            Button {
                Task { await store.logLibraryItem(item.id, mealType: .currentDefault) }
            } label: {
                Label("Log Today", systemImage: "plus.circle")
            }

            Menu("Log to...") {
                ForEach(CalorieMealType.allCases) { meal in
                    Button {
                        Task { await store.logLibraryItem(item.id, mealType: meal) }
                    } label: {
                        Label(meal.title, systemImage: meal.systemImage)
                    }
                }
            }

            Button {
                Task { await store.toggleFavorite(item.id) }
            } label: {
                Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this library item?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(item.kind == "recipe" ? "Delete Recipe" : "Delete Food", role: .destructive) {
                Task { await store.softDeleteLibraryItem(item.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct FoodMemoryRow: View {
    let item: CanonicalFoodItem
    let onOpen: () -> Void
    let onLog: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    FoodIconView(foodName: item.displayName, size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(DashboardTone.textPrimary)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(DashboardTone.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button(action: onLog) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DashboardTone.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log \(item.displayName)")
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 20))
    }
}

private struct FoodMemoryListScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore

    @State private var query = ""
    @State private var items: [CanonicalFoodItem] = []
    @State private var isLoading = false
    @State private var canLoadMore = true
    @State private var editingFood: CanonicalFoodItem?

    private let pageSize = 50

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        FoodIconView(foodName: item.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DashboardTone.textPrimary)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(DashboardTone.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task { await store.logCanonicalFood(item.id, mealType: .currentDefault) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(DashboardTone.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingFood = item
                    }
                    .padding(.vertical, 4)
                    .onAppear {
                        guard item.id == items.last?.id else { return }
                        Task { await loadMoreIfNeeded() }
                    }
                }

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                } else if items.isEmpty {
                    Text("No foods found")
                        .foregroundStyle(DashboardTone.textSecondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("All Foods")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(DashboardTone.textPrimary)
                }
            }
            .task {
                await reload()
            }
            .onChange(of: query) { _, _ in
                Task { await reload() }
            }
            .sheet(item: $editingFood) { item in
                CanonicalFoodEditorSheet(store: store, item: item)
            }
        }
        .tint(DashboardTone.textPrimary)
    }

    private func reload() async {
        isLoading = true
        canLoadMore = true
        let loaded = await store.loadCanonicalFoods(query: query, limit: pageSize, offset: 0)
        items = loaded
        canLoadMore = loaded.count == pageSize
        isLoading = false
    }

    private func loadMoreIfNeeded() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        let loaded = await store.loadCanonicalFoods(query: query, limit: pageSize, offset: items.count)
        items.append(contentsOf: loaded)
        canLoadMore = loaded.count == pageSize
        isLoading = false
    }
}

private enum LibrarySearchMode {
    case library
    case quickAdd
}

private struct LibrarySearchScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    var mode: LibrarySearchMode = .library

    @State private var query = ""
    @State private var foodMemoryResults: [CanonicalFoodItem] = []
    @State private var isSearchingMemory = false
    @State private var aiFoodResults: [ComposerFoodSearchResult] = []
    @State private var isSearchingAI = false
    @State private var aiSearchCompleted = false
    @State private var lastAIQuery = ""
    @State private var activeAIQuery: String?
    @State private var aiResultCache: [String: [ComposerFoodSearchResult]] = [:]
    @State private var editor: LibrarySearchEditor?
    @State private var showManualQuickAdd = false

    private var libraryResults: [CalorieLibraryItem] {
        store.libraryItems.filter { Self.matches(query, values: [$0.name, $0.brand, $0.kind, $0.sourceTitle, $0.sourceURL] + $0.aliases) }
    }

    private var templateResults: [MealTemplate] {
        store.mealTemplates.filter { template in
            let linkedNames = template.libraryItemIDs.compactMap { id in store.libraryItems.first(where: { $0.id == id })?.name }
            return Self.matches(query, values: [template.name] + linkedNames)
        }
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var quickAddFavorites: [CalorieLibraryItem] {
        store.libraryItems
            .filter(\.isFavorite)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var standardResults: [ComposerFoodSearchResult] {
        StandardFoodDatabase.matches(query: query, limit: 12).map { food, score in
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
                confidence: LibrarySearchScreen.confidence(from: score)
            )
        }
    }

    private var hasAnySearchResults: Bool {
        !libraryResults.isEmpty || !templateResults.isEmpty || !foodMemoryResults.isEmpty || !standardResults.isEmpty || !aiFoodResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if !hasQuery, mode == .quickAdd {
                    if !store.recentFoodMemories.isEmpty {
                        Section("Recently Logged") {
                            ForEach(store.recentFoodMemories.prefix(5)) { item in
                                quickAddCanonicalRow(item)
                            }
                        }
                    }

                    if !quickAddFavorites.isEmpty {
                        Section("Favorites") {
                            ForEach(quickAddFavorites) { item in
                                quickAddLibraryRow(item)
                            }
                        }
                    }
                } else if hasQuery {
                    if !libraryResults.isEmpty {
                        Section("Foods & Recipes") {
                            ForEach(libraryResults) { item in
                                if mode == .quickAdd {
                                    quickAddLibraryRow(item)
                                } else {
                                    Button {
                                        editor = .libraryItem(item)
                                    } label: {
                                        libraryResultRow(item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !templateResults.isEmpty, mode == .library {
                        Section("Meal Templates") {
                            ForEach(templateResults) { template in
                                Button {
                                    editor = .mealTemplate(template)
                                } label: {
                                    templateResultRow(template)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !foodMemoryResults.isEmpty {
                        Section("Food Memory") {
                            ForEach(foodMemoryResults) { item in
                                if mode == .quickAdd {
                                    quickAddCanonicalRow(item)
                                } else {
                                    Button {
                                        editor = .recentFood(item)
                                    } label: {
                                        foodMemoryResultRow(item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !standardResults.isEmpty {
                        Section("Foundation Foods") {
                            ForEach(standardResults) { item in
                                quickAddFoodSuggestionRow(item)
                            }
                        }
                    }

                    if !aiFoodResults.isEmpty {
                        Section("Web Suggestions") {
                            ForEach(aiFoodResults) { item in
                                quickAddFoodSuggestionRow(item)
                            }
                        }
                    }

                    if isSearchingMemory || isSearchingAI {
                        HStack {
                            Spacer()
                            Label("Searching...", systemImage: "magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(DashboardTone.textSecondary)
                            Spacer()
                        }
                    } else if !hasAnySearchResults {
                        Text(aiSearchCompleted ? "No food matches" : "Search foods")
                            .foregroundStyle(DashboardTone.textSecondary)
                    }
                } else {
                    Text(mode == .quickAdd ? "Search foods to quick add them." : "Search foods, recipes, templates, and recent food memory.")
                        .foregroundStyle(DashboardTone.textSecondary)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: mode == .quickAdd ? "Search foods" : "Search library")
            .navigationTitle(mode == .quickAdd ? "Food Search" : "Search Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(DashboardTone.textPrimary)
                }
                if mode == .quickAdd {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Quick Add") {
                            showManualQuickAdd = true
                        }
                        .foregroundStyle(DashboardTone.textPrimary)
                    }
                }
            }
            .task(id: query) {
                await reloadFoodMemory()
            }
            .sheet(item: $editor) { editor in
                switch editor {
                case .libraryItem(let item):
                    LibraryFoodEditorSheet(store: store, initialKind: item.kind, item: item)
                case .mealTemplate(let template):
                    MealTemplateEditorSheet(store: store, template: template)
                case .recentFood(let item):
                    CanonicalFoodEditorSheet(store: store, item: item)
                }
            }
            .sheet(isPresented: $showManualQuickAdd) {
                CalorieLogFoodSheet(store: store)
            }
        }
        .tint(DashboardTone.textPrimary)
    }

    private func libraryResultRow(_ item: CalorieLibraryItem) -> some View {
        HStack(spacing: 12) {
            FoodIconView(foodName: item.name, fallbackSystemName: item.kind == "recipe" ? "list.bullet.clipboard" : "takeoutbag.and.cup.and.straw", size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textPrimary)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(DashboardTone.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func templateResultRow(_ template: MealTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DashboardTone.textPrimary)
                .frame(width: 36, height: 36)
                .background(DashboardTone.divider, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textPrimary)
                Text("\(template.itemCount) item\(template.itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(DashboardTone.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func foodMemoryResultRow(_ item: CanonicalFoodItem) -> some View {
        HStack(spacing: 12) {
            FoodIconView(foodName: item.displayName, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textPrimary)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(DashboardTone.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func quickAddLibraryRow(_ item: CalorieLibraryItem) -> some View {
        HStack(spacing: 12) {
            Button {
                editor = .libraryItem(item)
            } label: {
                libraryResultRow(item)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                Task {
                    await store.logLibraryItem(item.id, mealType: .currentDefault)
                    dismiss()
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DashboardTone.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick add \(item.name)")
        }
    }

    private func quickAddCanonicalRow(_ item: CanonicalFoodItem) -> some View {
        HStack(spacing: 12) {
            Button {
                editor = .recentFood(item)
            } label: {
                foodMemoryResultRow(item)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                Task {
                    await store.logCanonicalFood(item.id, mealType: .currentDefault)
                    dismiss()
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DashboardTone.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick add \(item.displayName)")
        }
    }

    private func quickAddFoodSuggestionRow(_ item: ComposerFoodSearchResult) -> some View {
        HStack(spacing: 12) {
            FoodIconView(foodName: item.title, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textPrimary)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(DashboardTone.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let calories = item.calories {
                Button {
                    Task {
                        await store.logFood(
                            name: item.insertText,
                            calories: calories,
                            protein: item.protein,
                            carbs: item.carbs,
                            fat: item.fat,
                            fiber: nil,
                            sugars: nil,
                            sodium: nil,
                            potassium: nil,
                            notes: item.notes ?? "",
                            sourceTitle: item.source ?? "Food search",
                            sourceURL: item.sourceURL ?? "",
                            mealType: .currentDefault,
                            photoData: nil,
                            saveToLibrary: true,
                            servingQty: item.servingQuantity ?? 1,
                            servingUnit: item.servingUnit ?? "serving",
                            servingWeight: item.servingWeight
                        )
                        dismiss()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(DashboardTone.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quick add \(item.title)")
            } else {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DashboardTone.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reloadFoodMemory() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            foodMemoryResults = []
            isSearchingMemory = false
            aiFoodResults = []
            isSearchingAI = false
            aiSearchCompleted = false
            lastAIQuery = ""
            activeAIQuery = nil
            return
        }
        isSearchingMemory = true
        let loaded = await store.loadCanonicalFoods(query: trimmed, limit: 20, offset: 0)
        foodMemoryResults = loaded
        isSearchingMemory = false
        await reloadAIResultsIfNeeded(for: trimmed)
    }

    @MainActor
    private func reloadAIResultsIfNeeded(for query: String) async {
        if let cached = aiResultCache[query] {
            aiFoodResults = cached
            aiSearchCompleted = true
            isSearchingAI = false
            return
        }

        if isSearchingAI, activeAIQuery == query {
            return
        }

        aiFoodResults = []
        aiSearchCompleted = false
        guard query.count >= 2,
              libraryResults.isEmpty,
              templateResults.isEmpty,
              foodMemoryResults.isEmpty,
              standardResults.isEmpty
        else {
            isSearchingAI = false
            return
        }

        isSearchingAI = true
        lastAIQuery = query
        activeAIQuery = query
        let ranked = await aiFoodSearchResults(query: query)
        guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        activeAIQuery = nil
        if ranked.isEmpty, !aiFoodResults.isEmpty {
            isSearchingAI = false
            aiSearchCompleted = true
            return
        }
        aiResultCache[query] = ranked
        aiFoodResults = ranked
        isSearchingAI = false
        aiSearchCompleted = true
    }

    private func aiFoodSearchResults(query: String) async -> [ComposerFoodSearchResult] {
        await FoodSearchAIResolver.results(
            query: query,
            candidates: [],
            timeoutSeconds: 10
        )
    }

    private static func confidence(from score: Int) -> Double {
        if score >= 9_500 { return 0.98 }
        if score >= 7_500 { return 0.94 }
        if score >= 5_500 { return 0.88 }
        return min(max(0.54 + Double(score) / 10_000, 0.56), 0.84)
    }

    private static func matches(_ query: String, values: [String?]) -> Bool {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        let haystack = values
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

private enum LibrarySearchEditor: Identifiable {
    case libraryItem(CalorieLibraryItem)
    case mealTemplate(MealTemplate)
    case recentFood(CanonicalFoodItem)

    var id: String {
        switch self {
        case .libraryItem(let item):
            return "library-\(item.id)"
        case .mealTemplate(let template):
            return "template-\(template.id)"
        case .recentFood(let item):
            return "memory-\(item.id)"
        }
    }
}

private struct MealTemplateRow: View {
    let template: MealTemplate
    @ObservedObject var store: CalorieTrackerStore
    let onOpen: () -> Void
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DashboardTone.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(DashboardTone.divider, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(DashboardTone.textPrimary)
                            .lineLimit(1)
                        Text("\(template.itemCount) item\(template.itemCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(DashboardTone.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(template.name) details")

            Button {
                Task { await store.logMealTemplate(template.id, mealType: .currentDefault) }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DashboardTone.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log \(template.name) today")
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 20))
        .contextMenu {
            Button(action: onOpen) {
                Label("View Details", systemImage: "info.circle")
            }

            Button {
                Task { await store.logMealTemplate(template.id, mealType: .currentDefault) }
            } label: {
                Label("Log Today", systemImage: "plus.circle")
            }

            ForEach(CalorieMealType.allCases) { meal in
                Button {
                    Task { await store.logMealTemplate(template.id, mealType: meal) }
                } label: {
                    Label("Log to \(meal.title)", systemImage: meal.systemImage)
                }
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Template", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this meal template?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                Task { await store.softDeleteMealTemplate(template.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct CalorieLogFoodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let title: String
    @State private var name = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""
    @State private var sugars = ""
    @State private var sodium = ""
    @State private var potassium = ""
    @State private var servingQty = "1"
    @State private var servingUnit = "serving"
    @State private var servingWeight = ""
    @State private var notes = ""
    @State private var source = ""
    @State private var mealType: CalorieMealType = .currentDefault
    @State private var saveToLibrary = false
    @State private var selectedLibraryID = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?

    init(
        store: CalorieTrackerStore,
        scannedLabel: NutritionLabelScanResult? = nil,
        photoData: Data? = nil,
        title: String = "Log Food"
    ) {
        self.store = store
        self.title = title
        _name = State(initialValue: scannedLabel?.name ?? "")
        _calories = State(initialValue: scannedLabel?.calories?.cleanString ?? "")
        _protein = State(initialValue: scannedLabel?.protein?.cleanString ?? "")
        _carbs = State(initialValue: scannedLabel?.carbs?.cleanString ?? "")
        _fat = State(initialValue: scannedLabel?.fat?.cleanString ?? "")
        _fiber = State(initialValue: scannedLabel?.fiber?.cleanString ?? "")
        _sugars = State(initialValue: scannedLabel?.sugars?.cleanString ?? "")
        _sodium = State(initialValue: scannedLabel?.sodium?.cleanString ?? "")
        _potassium = State(initialValue: scannedLabel?.potassium?.cleanString ?? "")
        _servingQty = State(initialValue: scannedLabel?.servingQuantity?.cleanString ?? "1")
        _servingUnit = State(initialValue: scannedLabel?.servingUnit ?? "serving")
        _servingWeight = State(initialValue: scannedLabel?.servingWeight?.cleanString ?? "")
        _notes = State(initialValue: scannedLabel?.notes ?? "")
        _source = State(initialValue: scannedLabel?.sourceTitle ?? "Nutrition label scan")
        _photoData = State(initialValue: photoData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    Picker("Meal", selection: $mealType) {
                        ForEach(CalorieMealType.allCases) { meal in
                            Label(meal.title, systemImage: meal.systemImage).tag(meal)
                        }
                    }
                    Picker("From library", selection: $selectedLibraryID) {
                        Text("None").tag("")
                        ForEach(store.libraryItems) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .onChange(of: selectedLibraryID) { _, id in
                        guard let item = store.libraryItems.first(where: { $0.id == id }) else { return }
                        name = item.name
                        calories = item.calories.cleanString
                        protein = item.protein.cleanString
                        carbs = item.carbs.cleanString
                        fat = item.fat.cleanString
                        servingQty = item.defaultServingQty?.cleanString ?? "1"
                        servingUnit = item.defaultServingUnit ?? "serving"
                        servingWeight = item.defaultServingWeight?.cleanString ?? ""
                    }
                    HStack(spacing: 12) {
                        FoodIconView(foodName: name, size: 36)
                        TextField("Name", text: $name)
                    }
                    numericField("Serving", text: $servingQty)
                    TextField("Serving unit", text: $servingUnit)
                    numericField("Serving weight (g)", text: $servingWeight)
                    numericField("Calories", text: $calories)
                    Toggle("Save to library", isOn: $saveToLibrary)
                }

                Section("Macros") {
                    numericField("Protein (g)", text: $protein)
                    numericField("Carbs (g)", text: $carbs)
                    numericField("Fat (g)", text: $fat)
                }

                Section("Optional") {
                    numericField("Fiber (g)", text: $fiber)
                    numericField("Sugars (g)", text: $sugars)
                    numericField("Sodium (mg)", text: $sodium)
                    numericField("Potassium (mg)", text: $potassium)
                    TextField("Source", text: $source)
                    TextField("Notes", text: $notes, axis: .vertical)
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(photoData == nil ? "Attach Photo" : "Photo Attached", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        AppHaptics.medium()
                        Task {
                            await store.logFood(
                                name: name,
                                calories: calories.doubleValue,
                                protein: protein.optionalDouble,
                                carbs: carbs.optionalDouble,
                                fat: fat.optionalDouble,
                                fiber: fiber.optionalDouble,
                                sugars: sugars.optionalDouble,
                                sodium: sodium.optionalDouble,
                                potassium: potassium.optionalDouble,
                                notes: notes,
                                sourceTitle: source,
                                mealType: mealType,
                                photoData: photoData,
                                saveToLibrary: saveToLibrary,
                                servingQty: servingQty.optionalDouble ?? 1,
                                servingUnit: servingUnit,
                                servingWeight: servingWeight.optionalDouble
                            )
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || calories.doubleValue <= 0)
                }
            }
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                photoData = try? await selectedPhoto.loadTransferable(type: Data.self)
            }
        }
    }
}

private struct LibraryFoodEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let item: CalorieLibraryItem?
    @State private var kind = "food"
    @State private var name = ""
    @State private var brand = ""
    @State private var servingQty = "1"
    @State private var servingUnit = "serving"
    @State private var servingWeight = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var aliases = ""
    @State private var notes = ""
    @State private var source = ""
    @State private var sourceURL = ""
    @State private var showDeleteConfirmation = false
    @State private var recipeComponents: [RecipeComponentItem] = []
    @State private var editingRecipeComponent: RecipeComponentItem?

    init(store: CalorieTrackerStore, initialKind: String = "food", item: CalorieLibraryItem? = nil) {
        self.store = store
        self.item = item
        _kind = State(initialValue: item?.kind ?? initialKind)
        _name = State(initialValue: item?.name ?? "")
        _brand = State(initialValue: item?.brand ?? "")
        _servingQty = State(initialValue: item?.defaultServingQty?.cleanString ?? "1")
        _servingUnit = State(initialValue: item?.defaultServingUnit ?? "serving")
        _servingWeight = State(initialValue: item?.defaultServingWeight?.cleanString ?? "")
        _calories = State(initialValue: item?.calories.cleanString ?? "")
        _protein = State(initialValue: item?.protein.cleanString ?? "")
        _carbs = State(initialValue: item?.carbs.cleanString ?? "")
        _fat = State(initialValue: item?.fat.cleanString ?? "")
        _aliases = State(initialValue: item?.aliases.joined(separator: ", ") ?? "")
        _notes = State(initialValue: item?.notes ?? "")
        _source = State(initialValue: item?.sourceTitle ?? "")
        _sourceURL = State(initialValue: item?.sourceURL ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 14) {
                            FoodIconView(foodName: name.isEmpty ? item.name : name, fallbackSystemName: kind == "recipe" ? "list.bullet.clipboard" : "takeoutbag.and.cup.and.straw", size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name.isEmpty ? item.name : name)
                                    .font(.headline.weight(.semibold))
                                Text("\(calories.isEmpty ? item.calories.cleanString : calories) kcal")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Library Item") {
                    Picker("Type", selection: $kind) {
                        Text("Food").tag("food")
                        Text("Recipe").tag("recipe")
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $name)
                    TextField("Brand", text: $brand)
                    TextField("Aliases, comma separated", text: $aliases)
                }
                Section("Serving") {
                    numericField("Default quantity", text: $servingQty)
                    TextField("Unit", text: $servingUnit)
                    numericField("Weight (g)", text: $servingWeight)
                }
                Section("Nutrition") {
                    numericField("Calories", text: $calories)
                    numericField("Protein (g)", text: $protein)
                    numericField("Carbs (g)", text: $carbs)
                    numericField("Fat (g)", text: $fat)
                    TextField("Source", text: $source)
                    TextField("Source URL", text: $sourceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if kind == "recipe" {
                    Section {
                        if recipeComponents.isEmpty {
                            Text("No ingredients yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(recipeComponents) { component in
                                Button {
                                    editingRecipeComponent = component
                                } label: {
                                    HStack(spacing: 12) {
                                        FoodIconView(foodName: component.componentName, size: 34)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(component.componentName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(component.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                recipeComponents.remove(atOffsets: offsets)
                                updateRecipeMacroFields()
                            }
                        }

                        Button {
                            addRecipeComponent()
                        } label: {
                            Label("Add Ingredient", systemImage: "plus.circle")
                        }
                        .disabled(availableRecipeFoods.isEmpty)
                    } header: {
                        Text("Ingredients")
                    } footer: {
                        Text("Recipe calories and macros are calculated from these ingredients.")
                    }
                }

                if let item {
                    Section("Actions") {
                        Button {
                            Task {
                                AppHaptics.medium()
                                await store.logLibraryItem(item.id, mealType: .currentDefault)
                                dismiss()
                            }
                        } label: {
                            Label("Log Today", systemImage: "calendar.badge.plus")
                        }

                        ForEach(CalorieMealType.allCases) { meal in
                            Button {
                                Task {
                                    AppHaptics.light()
                                    await store.logLibraryItem(item.id, mealType: meal)
                                    dismiss()
                                }
                            } label: {
                                Label("Log to \(meal.title)", systemImage: meal.systemImage)
                            }
                        }

                        Button {
                            Task {
                                AppHaptics.medium()
                                await store.duplicateLibraryItem(item.id)
                                dismiss()
                            }
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }

                        Button {
                            Task {
                                AppHaptics.light()
                                await store.toggleFavorite(item.id)
                                dismiss()
                            }
                        } label: {
                            Label(item.isFavorite ? "Remove Favorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
                        }
                    }

                    Section {
                        Button(item.kind == "recipe" ? "Delete Recipe" : "Delete Food", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(DashboardTone.textPrimary)
            .navigationTitle(editorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(item == nil ? "Cancel" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if let item {
                                await store.updateLibraryItem(
                                    item.id,
                                    kind: kind,
                                    name: name,
                                    brand: brand,
                                    servingQty: servingQty.optionalDouble,
                                    servingUnit: servingUnit,
                                    servingWeight: servingWeight.optionalDouble,
                                    calories: calories.doubleValue,
                                    protein: protein.optionalDouble,
                                    carbs: carbs.optionalDouble,
                                    fat: fat.optionalDouble,
                                    aliases: aliases,
                                    notes: notes,
                                    sourceTitle: source,
                                    sourceURL: sourceURL
                                )
                                if kind == "recipe" {
                                    await store.saveRecipeComponents(recipeId: item.id, components: recipeComponents)
                                }
                            } else {
                                let savedId = await store.saveLibraryItem(
                                    kind: kind,
                                    name: name,
                                    brand: brand,
                                    servingQty: servingQty.optionalDouble,
                                    servingUnit: servingUnit,
                                    servingWeight: servingWeight.optionalDouble,
                                    calories: calories.doubleValue,
                                    protein: protein.optionalDouble,
                                    carbs: carbs.optionalDouble,
                                    fat: fat.optionalDouble,
                                    aliases: aliases,
                                    notes: notes,
                                    sourceTitle: source,
                                    sourceURL: sourceURL
                                )
                                if kind == "recipe", let savedId {
                                    await store.saveRecipeComponents(recipeId: savedId, components: recipeComponents)
                                }
                            }
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind != "recipe" && calories.doubleValue <= 0))
                }
            }
            .confirmationDialog("Delete this library item?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let item else { return }
                    Task {
                        AppHaptics.medium()
                        await store.softDeleteLibraryItem(item.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $editingRecipeComponent) { component in
                RecipeComponentEditorSheet(
                    component: component,
                    foods: availableRecipeFoods,
                    onSave: { updated in
                        upsertRecipeComponent(updated)
                    },
                    onDelete: {
                        recipeComponents.removeAll { $0.id == component.id }
                        updateRecipeMacroFields()
                    }
                )
            }
            .task(id: item?.id) {
                guard let item, item.kind == "recipe" else { return }
                recipeComponents = await store.loadRecipeComponents(recipeId: item.id)
                updateRecipeMacroFields()
            }
        }
    }

    private var editorTitle: String {
        if item == nil {
            return kind == "recipe" ? "Save Recipe" : "Save Food"
        }
        return kind == "recipe" ? "Recipe Details" : "Food Details"
    }

    private var availableRecipeFoods: [CalorieLibraryItem] {
        store.libraryItems
            .filter { $0.kind != "recipe" && $0.id != item?.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addRecipeComponent() {
        guard let food = availableRecipeFoods.first else { return }
        let component = RecipeComponentItem(
            id: UUID().uuidString,
            recipeId: item?.id ?? "",
            componentItemId: food.id,
            componentName: food.name,
            quantity: 1,
            unit: food.defaultServingUnit ?? "serving",
            weight: food.defaultServingWeight,
            calories: food.calories,
            protein: food.protein,
            carbs: food.carbs,
            fat: food.fat,
            sortOrder: recipeComponents.count,
            notes: nil
        )
        editingRecipeComponent = component
    }

    private func upsertRecipeComponent(_ component: RecipeComponentItem) {
        if let index = recipeComponents.firstIndex(where: { $0.id == component.id }) {
            recipeComponents[index] = component
        } else {
            recipeComponents.append(component)
        }
        recipeComponents = recipeComponents.enumerated().map { index, component in
            var updated = component
            updated.sortOrder = index
            return updated
        }
        updateRecipeMacroFields()
    }

    private func updateRecipeMacroFields() {
        guard kind == "recipe", !recipeComponents.isEmpty else { return }
        calories = recipeComponents.reduce(0) { $0 + $1.calories }.cleanString
        protein = recipeComponents.reduce(0) { $0 + $1.protein }.cleanString
        carbs = recipeComponents.reduce(0) { $0 + $1.carbs }.cleanString
        fat = recipeComponents.reduce(0) { $0 + $1.fat }.cleanString
    }
}

private struct CanonicalFoodEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let item: CanonicalFoodItem

    @State private var name: String
    @State private var brand: String
    @State private var servingQty: String
    @State private var servingUnit: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String

    init(store: CalorieTrackerStore, item: CanonicalFoodItem) {
        self.store = store
        self.item = item
        _name = State(initialValue: item.displayName)
        _brand = State(initialValue: item.brand ?? "")
        _servingQty = State(initialValue: item.defaultServingQty?.cleanString ?? "1")
        _servingUnit = State(initialValue: item.defaultServingUnit ?? "serving")
        _calories = State(initialValue: item.calories.cleanString)
        _protein = State(initialValue: item.protein.cleanString)
        _carbs = State(initialValue: item.carbs.cleanString)
        _fat = State(initialValue: item.fat.cleanString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("Name", text: $name)
                    TextField("Brand", text: $brand)
                }
                Section("Serving") {
                    numericField("Default quantity", text: $servingQty)
                    TextField("Unit", text: $servingUnit)
                }
                Section("Nutrition") {
                    numericField("Calories", text: $calories)
                    numericField("Protein (g)", text: $protein)
                    numericField("Carbs (g)", text: $carbs)
                    numericField("Fat (g)", text: $fat)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Food Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.updateCanonicalFood(
                                item.id,
                                displayName: name,
                                brand: brand,
                                servingQty: servingQty.optionalDouble,
                                servingUnit: servingUnit,
                                calories: calories.doubleValue,
                                protein: protein.optionalDouble,
                                carbs: carbs.optionalDouble,
                                fat: fat.optionalDouble
                            )
                            dismiss()
                        }
                    }
                    .disabled(name.trimmed.isEmpty || calories.doubleValue <= 0)
                }
            }
        }
    }
}

private struct RecipeComponentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var component: RecipeComponentItem
    let foods: [CalorieLibraryItem]
    let onSave: (RecipeComponentItem) -> Void
    let onDelete: () -> Void

    @State private var selectedFoodId: String
    @State private var quantity: String
    @State private var unit: String
    @State private var weight: String
    @State private var notes: String
    @State private var showDeleteConfirmation = false

    init(
        component: RecipeComponentItem,
        foods: [CalorieLibraryItem],
        onSave: @escaping (RecipeComponentItem) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _component = State(initialValue: component)
        self.foods = foods
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedFoodId = State(initialValue: component.componentItemId ?? foods.first?.id ?? "")
        _quantity = State(initialValue: component.quantity.cleanString)
        _unit = State(initialValue: component.unit)
        _weight = State(initialValue: component.weight?.cleanString ?? "")
        _notes = State(initialValue: component.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food Item") {
                    Picker("Food", selection: $selectedFoodId) {
                        ForEach(foods) { food in
                            Text(food.name).tag(food.id)
                        }
                    }
                    .onChange(of: selectedFoodId) { _, _ in
                        applySelectedFoodDefaults()
                    }
                }

                Section("Serving") {
                    numericField("Quantity", text: $quantity)
                    TextField("Unit", text: $unit)
                    numericField("Weight (g)", text: $weight)
                }

                Section("Macros") {
                    macroPreview("Calories", value: calculated.calories, unit: "kcal")
                    macroPreview("Protein", value: calculated.protein, unit: "g")
                    macroPreview("Carbs", value: calculated.carbs, unit: "g")
                    macroPreview("Fat", value: calculated.fat, unit: "g")
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                Section {
                    Button("Delete Ingredient", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if selectedFoodId.isEmpty {
                    selectedFoodId = foods.first?.id ?? ""
                    applySelectedFoodDefaults()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(updatedComponent)
                        dismiss()
                    }
                    .disabled(selectedFood == nil || quantity.doubleValue <= 0)
                }
            }
            .confirmationDialog("Delete this ingredient?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Ingredient", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var selectedFood: CalorieLibraryItem? {
        foods.first { $0.id == selectedFoodId }
    }

    private var calculated: CalorieTotals {
        guard let selectedFood else { return CalorieTotals() }
        let multiplier = max(quantity.doubleValue, 0)
        return CalorieTotals(
            calories: selectedFood.calories * multiplier,
            protein: selectedFood.protein * multiplier,
            carbs: selectedFood.carbs * multiplier,
            fat: selectedFood.fat * multiplier
        )
    }

    private var updatedComponent: RecipeComponentItem {
        var updated = component
        updated.componentItemId = selectedFood?.id
        updated.componentName = selectedFood?.name ?? component.componentName
        updated.quantity = max(quantity.doubleValue, 0)
        updated.unit = unit.trimmed.nilIfBlank ?? selectedFood?.defaultServingUnit ?? "serving"
        updated.weight = weight.optionalDouble ?? selectedFood?.defaultServingWeight.map { $0 * max(quantity.doubleValue, 0) }
        updated.calories = calculated.calories
        updated.protein = calculated.protein
        updated.carbs = calculated.carbs
        updated.fat = calculated.fat
        updated.notes = notes.nilIfBlank
        return updated
    }

    private func applySelectedFoodDefaults() {
        guard let selectedFood else { return }
        if unit.trimmed.isEmpty || unit == component.unit {
            unit = selectedFood.defaultServingUnit ?? "serving"
        }
        if weight.trimmed.isEmpty, let defaultWeight = selectedFood.defaultServingWeight {
            weight = (defaultWeight * max(quantity.doubleValue, 1)).cleanString
        }
    }

    private func macroPreview(_ label: String, value: Double, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value.cleanString) \(unit)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct MealTemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    let template: MealTemplate?
    @State private var name = ""
    @State private var selectedIDs = Set<String>()
    @State private var showDeleteConfirmation = false

    init(store: CalorieTrackerStore, template: MealTemplate? = nil) {
        self.store = store
        self.template = template
        _name = State(initialValue: template?.name ?? "")
        _selectedIDs = State(initialValue: Set(template?.libraryItemIDs ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Name", text: $name)
                }
                Section("Foods") {
                    ForEach(store.libraryItems) { item in
                        Button {
                            if selectedIDs.contains(item.id) {
                                selectedIDs.remove(item.id)
                            } else {
                                selectedIDs.insert(item.id)
                            }
                        } label: {
                            HStack {
                                Text(item.name)
                                Spacer()
                                if selectedIDs.contains(item.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                if let template {
                    Section("Actions") {
                        Button {
                            Task {
                                AppHaptics.medium()
                                await store.logMealTemplate(template.id, mealType: .currentDefault)
                                dismiss()
                            }
                        } label: {
                            Label("Log Today", systemImage: "calendar.badge.plus")
                        }

                        ForEach(CalorieMealType.allCases) { meal in
                            Button {
                                Task {
                                    AppHaptics.light()
                                    await store.logMealTemplate(template.id, mealType: meal)
                                    dismiss()
                                }
                            } label: {
                                Label("Log to \(meal.title)", systemImage: meal.systemImage)
                            }
                        }

                        Button {
                            Task {
                                AppHaptics.medium()
                                await store.duplicateMealTemplate(template.id)
                                dismiss()
                            }
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }

                    Section {
                        Button("Delete Template", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(DashboardTone.textPrimary)
            .navigationTitle(template == nil ? "Meal Template" : "Template Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(template == nil ? "Cancel" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if let template {
                                await store.updateMealTemplate(template.id, name: name, libraryItemIDs: Array(selectedIDs))
                            } else {
                                await store.saveMealTemplate(name: name, libraryItemIDs: Array(selectedIDs))
                            }
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedIDs.isEmpty)
                }
            }
            .confirmationDialog("Delete this meal template?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let template else { return }
                    Task {
                        AppHaptics.medium()
                        await store.softDeleteMealTemplate(template.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct CalorieGoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var scope: GoalScope = .allTime
    @State private var isBalancingTargets = false
    @FocusState private var focusedField: GoalField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope", selection: $scope) {
                        ForEach(GoalScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Targets") {
                    goalNumberRow("Calories", unit: "kcal", text: $calories, field: .calories)
                    goalNumberRow("Protein", unit: "g", text: $protein, field: .protein)
                    goalNumberRow("Carbs", unit: "g", text: $carbs, field: .carbs)
                    goalNumberRow("Fat", unit: "g", text: $fat, field: .fat)
                }
                Section("Macro Calories") {
                    HStack {
                        Text("4/4/9 total")
                        Spacer()
                        Text("\(macroCalories.formatted(.number.precision(.fractionLength(0)))) kcal")
                            .font(.headline.weight(.semibold))
                            .monospacedDigit()
                    }
                    macroBreakdownRow("Protein", calories: protein.doubleValue * 4)
                    macroBreakdownRow("Carbs", calories: carbs.doubleValue * 4)
                    macroBreakdownRow("Fat", calories: fat.doubleValue * 9)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                calories = store.goal.calories.cleanString
                protein = store.goal.protein.cleanString
                carbs = store.goal.carbs.cleanString
                fat = store.goal.fat.cleanString
                updateMacrosFromCalories()
            }
            .onChange(of: calories) { _, _ in
                guard focusedField == .calories else { return }
                updateMacrosFromCalories()
            }
            .onChange(of: protein) { _, _ in
                guard focusedField == .protein else { return }
                updateCaloriesFromMacros()
            }
            .onChange(of: carbs) { _, _ in
                guard focusedField == .carbs else { return }
                updateCaloriesFromMacros()
            }
            .onChange(of: fat) { _, _ in
                guard focusedField == .fat else { return }
                updateCaloriesFromMacros()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.saveGoals(
                                calories: macroCalories > 0 ? macroCalories : calories.doubleValue,
                                protein: protein.doubleValue,
                                carbs: carbs.doubleValue,
                                fat: fat.doubleValue,
                                overrideToday: scope == .todayOnly
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var macroCalories: Double {
        protein.doubleValue * 4 + carbs.doubleValue * 4 + fat.doubleValue * 9
    }

    private func goalNumberRow(_ label: String, unit: String, text: Binding<String>, field: GoalField) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 96)
                .focused($focusedField, equals: field)
            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    private func macroBreakdownRow(_ label: String, calories: Double) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(DashboardTone.textSecondary)
                .frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text("\(calories.formatted(.number.precision(.fractionLength(0)))) kcal")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func updateMacrosFromCalories() {
        guard !isBalancingTargets, !calories.trimmed.isEmpty, calories.doubleValue > 0 else { return }
        isBalancingTargets = true
        let target = calories.doubleValue
        protein = (target * 0.30 / 4).cleanString
        carbs = (target * 0.40 / 4).cleanString
        fat = (target * 0.30 / 9).cleanString
        isBalancingTargets = false
    }

    private func updateCaloriesFromMacros() {
        guard !isBalancingTargets else { return }
        guard !protein.trimmed.isEmpty || !carbs.trimmed.isEmpty || !fat.trimmed.isEmpty else { return }
        isBalancingTargets = true
        calories = macroCalories.rounded().cleanString
        isBalancingTargets = false
    }
}

private struct DailyNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    @State private var note = ""
    @State private var mood = ""
    @State private var hunger = ""
    @State private var training = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Context") {
                    TextField("Mood", text: $mood)
                    TextField("Hunger", text: $hunger)
                    TextField("Training", text: $training)
                }
                if store.dailyNote != nil {
                    Section {
                        Button("Delete Daily Note", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Daily Note")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                note = store.dailyNote?.note ?? ""
                mood = store.dailyNote?.mood ?? ""
                hunger = store.dailyNote?.hunger ?? ""
                training = store.dailyNote?.training ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
	                ToolbarItem(placement: .confirmationAction) {
	                    Button("Save") {
	                        Task {
	                            if hasAnyContent {
	                                await store.saveDailyNote(note: note, mood: mood, hunger: hunger, training: training)
	                                dismiss()
	                            } else if store.dailyNote != nil {
	                                showDeleteConfirmation = true
	                            } else {
	                                dismiss()
	                            }
	                        }
	                    }
	                }
	            }
	            .confirmationDialog("Delete daily note?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
	                Button("Delete Daily Note", role: .destructive) {
	                    Task {
	                        await store.deleteDailyNote()
	                        dismiss()
	                    }
	                }
	                Button("Cancel", role: .cancel) {}
	            }
	        }
	    }

    private var hasAnyContent: Bool {
        [note, mood, hunger, training].contains { !$0.trimmed.isEmpty }
    }
}

private struct DashboardDateSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CalorieTrackerStore
    @State private var date = Date()
    @State private var summary = CalorieDaySummary()
    @State private var isLoadingSummary = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    Button("Today") {
                        AppHaptics.light()
                        date = Date()
                    }
                }
                Section("Selected Day") {
                    CalorieDaySummaryPreview(summary: summary, isLoading: isLoadingSummary)
                }
            }
            .navigationTitle("Choose Day")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                date = min(store.selectedDate, Date())
                Task { await loadSummary() }
            }
            .onChange(of: date) { _, _ in
                Task { await loadSummary() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        AppHaptics.medium()
                        Task {
                            await store.selectDate(date)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func loadSummary() async {
        isLoadingSummary = true
        summary = await store.summaryForDate(date)
        isLoadingSummary = false
    }
}

private struct CalorieDaySummaryPreview: View {
    let summary: CalorieDaySummary
    let isLoading: Bool

    private var calorieProgress: CGFloat {
        CGFloat(min(max(summary.totals.calories / max(summary.goal.calories, 1), 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.totals.calories.formatted(.number.precision(.fractionLength(0))))
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                Text("/ \(summary.goal.calories.formatted(.number.precision(.fractionLength(0)))) kcal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Text("\(summary.logCount) item\(summary.logCount == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DashboardTone.divider)
                    Capsule()
                        .fill(DashboardTone.accent)
                        .frame(width: proxy.size.width * calorieProgress)
                }
            }
            .frame(height: 5)

            HStack(spacing: 12) {
                summaryMacro("Protein", value: summary.totals.protein, goal: summary.goal.protein)
                summaryMacro("Carbs", value: summary.totals.carbs, goal: summary.goal.carbs)
                summaryMacro("Fat", value: summary.totals.fat, goal: summary.goal.fat)
            }
        }
        .padding(.vertical, 4)
    }

    private func summaryMacro(_ title: String, value: Double, goal: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value.cleanString)g")
                .font(.headline.weight(.bold))
                .monospacedDigit()
            Text("/ \(goal.cleanString)g")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DashboardTone.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum DashboardSheet: String, Identifiable {
    case logFood
    case searchFood
    case goals
    case dailyNote
    case dateSwitcher
    var id: String { rawValue }
}

private struct MealLogSelection: Identifiable {
    let meal: CalorieMealType
    var id: String { meal.rawValue }
}

private enum LibrarySheet: Identifiable {
    case food
    case recipe
    case template
    case libraryItem(CalorieLibraryItem)
    case mealTemplate(MealTemplate)
    case recentFoods
    case recentFood(CanonicalFoodItem)
    case search

    var id: String {
        switch self {
        case .food:
            return "food"
        case .recipe:
            return "recipe"
        case .template:
            return "template"
        case .libraryItem(let item):
            return "libraryItem-\(item.id)"
        case .mealTemplate(let template):
            return "mealTemplate-\(template.id)"
        case .recentFoods:
            return "recentFoods"
        case .recentFood(let item):
            return "recentFood-\(item.id)"
        case .search:
            return "search"
        }
    }
}

private enum GoalScope: String, CaseIterable, Identifiable {
    case allTime
    case todayOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: return "All-time"
        case .todayOnly: return "Today only"
        }
    }
}

private enum GoalField: Hashable {
    case calories
    case protein
    case carbs
    case fat
}

private struct LibraryToolbarButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .modifier(GlassCircleModifier())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct DashboardSectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(DashboardTone.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DashboardTone.textSecondary)
            }
        }
    }
}

private struct AnimatedCalorieNumberText: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = max(newValue, 0) }
    }

    var body: some View {
        Text(value.formatted(.number.precision(.fractionLength(0))))
            .font(.system(size: 58, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.62)
            .lineLimit(1)
            .foregroundStyle(DashboardTone.textPrimary)
    }
}

private struct SlantedCalorieProgressBar: View {
    let progress: CGFloat
    let isOver: Bool

    private let blockCount = 18
    private let blockSpacing: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let rawProgress = max(progress, 0)
            let clampedProgress = min(rawProgress, 1)
            let blockWidth = max(
                8,
                (proxy.size.width - CGFloat(blockCount - 1) * blockSpacing) / CGFloat(blockCount)
            )
            let filledBlocks = clampedProgress * CGFloat(blockCount)
            let dangerTail = isOver ? overfillTail(for: rawProgress, minimum: 0.12, maximum: 0.30) : 0
            let transitionWidth = min(0.035, dangerTail * 0.25)

            HStack(alignment: .bottom, spacing: blockSpacing) {
                ForEach(0..<blockCount, id: \.self) { index in
                    let fill = min(max(filledBlocks - CGFloat(index), 0), 1)
                    let blockStart = CGFloat(index) / CGFloat(blockCount)
                    let blockEnd = CGFloat(index + 1) / CGFloat(blockCount)
                    SlantedProgressBlock(
                        fill: fill,
                        isOver: isOver,
                        dangerTail: dangerTail,
                        transitionWidth: transitionWidth,
                        blockStart: blockStart,
                        blockEnd: blockEnd
                    )
                    .frame(width: blockWidth, height: blockHeight(for: index))
                    .animation(
                        DashboardMetricsAnimation.calorieBlockReveal(index: index, count: blockCount),
                        value: fill
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func blockHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(index) / CGFloat(max(blockCount - 1, 1))
        return 15 + normalized * 4
    }
}

private struct SlantedProgressBlock: View {
    let fill: CGFloat
    let isOver: Bool
    let dangerTail: CGFloat
    let transitionWidth: CGFloat
    let blockStart: CGFloat
    let blockEnd: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let slant = min(proxy.size.width * 0.45, 7)
            let shape = SlantedBlockShape(slant: slant)
            let fillStops = isOver
                ? localizedOverfillStops(
                    base: DashboardTone.accent,
                    dangerTail: dangerTail,
                    transitionWidth: transitionWidth,
                    rangeStart: blockStart,
                    rangeEnd: blockEnd
                )
                : solidGradientStops(DashboardTone.accent)

            ZStack(alignment: .leading) {
                shape
                    .fill(DashboardTone.divider)

                Rectangle()
                    .fill(LinearGradient(stops: fillStops, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(fill, 0), 1))
                    .mask(alignment: .leading) {
                        shape
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
            }
        }
    }
}

private struct SlantedBlockShape: Shape {
    let slant: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: min(slant, rect.width), y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: max(rect.maxX - slant, rect.minX), y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MacroProgressLine: View {
    let title: String
    let value: Double
    let goal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DashboardTone.textPrimary)
                Spacer()
                Text("\(value.cleanString)g / \(goal.cleanString)g")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(DashboardTone.textSecondary)
            }

            OverfillCapsuleProgressBar(
                value: value,
                goal: goal,
                fill: DashboardTone.macroFill,
                height: 5
            )
            .animation(DashboardMetricsAnimation.reveal, value: value)
            .animation(DashboardMetricsAnimation.reveal, value: goal)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value.cleanString) grams of \(goal.cleanString) grams")
    }
}

private struct OverfillCapsuleProgressBar: View {
    let value: Double
    let goal: Double
    let fill: Color
    let height: CGFloat

    private var ratio: CGFloat {
        CGFloat(max(value / max(goal, 1), 0))
    }

    var body: some View {
        GeometryReader { proxy in
            let rawProgress = ratio
            let clampedProgress = min(rawProgress, 1)
            let dangerTail = rawProgress > 1 ? overfillTail(for: rawProgress, minimum: 0.10, maximum: 0.26) : 0
            let transitionWidth = min(0.03, dangerTail * 0.25)
            let fillWidth = proxy.size.width * clampedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DashboardTone.divider)

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: rawProgress > 1
                                ? overfillGradientStops(
                                    base: fill,
                                    dangerTail: dangerTail,
                                    transitionWidth: transitionWidth
                                )
                                : solidGradientStops(fill),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private func overfillTail(for ratio: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    guard ratio > 1 else { return 0 }
    return min(max(minimum + (ratio - 1) * 0.6, minimum), maximum)
}

private func solidGradientStops(_ color: Color) -> [Gradient.Stop] {
    [
        .init(color: color, location: 0),
        .init(color: color, location: 1)
    ]
}

private func overfillGradientStops(base: Color, dangerTail: CGFloat, transitionWidth: CGFloat) -> [Gradient.Stop] {
    let tail = min(max(dangerTail, 0), 1)
    guard tail > 0 else {
        return solidGradientStops(base)
    }
    let dangerStart = max(0, 1 - tail)
    let transitionStart = max(0, dangerStart - max(transitionWidth, 0))
    return [
        .init(color: base, location: 0),
        .init(color: base, location: transitionStart),
        .init(color: DashboardTone.danger, location: dangerStart),
        .init(color: DashboardTone.danger, location: 1)
    ]
}

private func localizedOverfillStops(
    base: Color,
    dangerTail: CGFloat,
    transitionWidth: CGFloat,
    rangeStart: CGFloat,
    rangeEnd: CGFloat
) -> [Gradient.Stop] {
    let span = max(rangeEnd - rangeStart, 0.0001)
    let tail = min(max(dangerTail, 0), 1)
    guard tail > 0 else {
        return solidGradientStops(base)
    }
    let dangerStart = max(0, 1 - tail)
    let transitionStart = max(0, dangerStart - max(transitionWidth, 0))
    let localTransitionStart = min(max((transitionStart - rangeStart) / span, 0), 1)
    let localDangerStart = min(max((dangerStart - rangeStart) / span, 0), 1)

    return [
        .init(color: base, location: 0),
        .init(color: base, location: localTransitionStart),
        .init(color: DashboardTone.danger, location: localDangerStart),
        .init(color: DashboardTone.danger, location: 1)
    ]
}

private func numericField(_ title: String, text: Binding<String>) -> some View {
    TextField(title, text: text)
        .keyboardType(.decimalPad)
}

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(DashboardTone.textPrimary)
}

private func emptyState(_ text: String, icon: String) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(DashboardTone.textSecondary.opacity(0.74))
        Text(text)
            .font(.subheadline)
            .foregroundStyle(DashboardTone.textSecondary)
        Spacer()
    }
    .padding(16)
    .background(cardBackground(cornerRadius: 20))
}

private func cardBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(DashboardTone.elevated)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(DashboardTone.textPrimary.opacity(0.10), lineWidth: 1)
        )
}

private var calorieBackground: some View {
    DashboardTone.bg.ignoresSafeArea()
}

private var heroBackground: some View {
    RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(DashboardTone.divider)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(DashboardTone.textPrimary.opacity(0.10), lineWidth: 1)
        )
}

struct FoodIconView: View {
    let foodName: String
    var fallbackSystemName = "fork.knife"
    var size: CGFloat = 42

    private var isDefaultIcon: Bool {
        matchedImage == nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(12, size * 0.28), style: .continuous)
                .fill(DashboardTone.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: max(12, size * 0.28), style: .continuous)
                        .stroke(DashboardTone.textPrimary.opacity(0.10), lineWidth: 1)
                )

            if let image = matchedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(DashboardTone.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var matchedImage: UIImage? {
        guard let file = FoodIconMatcher.icon(for: foodName) else {
            return FoodIconAssetLoader.image(named: "DefaultFood.png")
        }
        return FoodIconAssetLoader.image(named: file)
            ?? FoodIconAssetLoader.image(named: "DefaultFood.png")
    }
}

private enum FoodIconAssetLoader {
    private static var cache: [String: UIImage] = [:]

    static func image(named file: String) -> UIImage? {
        if let cached = cache[file] {
            return cached
        }

        let base = file
            .replacingOccurrences(of: ".svg", with: "")
            .replacingOccurrences(of: ".png", with: "")
        let ext = (file as NSString).pathExtension.isEmpty ? "png" : (file as NSString).pathExtension
        let candidates = [
            file,
            "\(base).png",
            base
        ]

        for candidate in candidates {
            if let image = UIImage(named: candidate) {
                cache[file] = image
                return image
            }
        }

        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "FoodIcons"),
           let image = UIImage(contentsOfFile: url.path) {
            cache[file] = image
            return image
        }

        if ext != "png",
           let url = Bundle.main.url(forResource: base, withExtension: "png", subdirectory: "FoodIcons"),
           let image = UIImage(contentsOfFile: url.path) {
            cache[file] = image
            return image
        }

        if let url = Bundle.main.url(forResource: base, withExtension: ext),
           let image = UIImage(contentsOfFile: url.path) {
            cache[file] = image
            return image
        }

        if ext != "png",
           let url = Bundle.main.url(forResource: base, withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            cache[file] = image
            return image
        }

        return nil
    }
}

struct CalorieTotals: Equatable, Codable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
}

struct CalorieGoal: Equatable, Codable {
    var calories: Double = 2100
    var protein: Double = 140
    var carbs: Double = 220
    var fat: Double = 70
}

private struct DashboardAIInsightPayload: Encodable {
    let date: String
    let totals: CalorieTotals
    let goal: CalorieGoal
    let logs: [DashboardAILogItem]
    let week: [DashboardAIWeekDay]
    let candidates: [DashboardAISuggestionCandidate]
}

private struct DashboardAILogItem: Encodable {
    let name: String
    let meal: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

private struct DashboardAIWeekDay: Encodable {
    let date: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let logCount: Int
}

private struct DashboardAISuggestionCandidate: Encodable {
    let id: String
    let name: String
    let meal: String
    let detail: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

struct DashboardAIInsightResponse: Decodable {
    let summary: String
    let suggestionIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case summary
        case suggestionIDs
        case suggestionIds
    }

    init(summary: String, suggestionIDs: [String]) {
        self.summary = summary
        self.suggestionIDs = suggestionIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        suggestionIDs = try container.decodeIfPresent([String].self, forKey: .suggestionIDs)
            ?? container.decodeIfPresent([String].self, forKey: .suggestionIds)
            ?? []
    }

    static func parse(_ content: String) -> DashboardAIInsightResponse? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if trimmed.hasPrefix("{") {
            jsonString = trimmed
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start < end {
            jsonString = String(trimmed[start...end])
        } else {
            return nil
        }
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct CalorieLogItem: Identifiable, Equatable {
    let id: String
    let canonicalFoodId: String?
    let libraryItemId: String?
    let name: String
    let mealType: CalorieMealType
    let servingCount: Double?
    let unit: String?
    let weight: Double?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let notes: String?
    let loggedAtMs: Int64
    let photoPath: String?
    let isFavorite: Bool

    var subtitle: String {
        let macros = "P \(protein.cleanString)g · C \(carbs.cleanString)g · F \(fat.cleanString)g"
        if let notes, !notes.isEmpty {
            return "\(macros) · \(notes)"
        }
        return macros
    }

    var servingDescription: String {
        let quantity = servingCount ?? 1
        let rawUnit = unit?.trimmed.nilIfBlank ?? "serving"
        let lowerUnit = rawUnit.lowercased()
        let displayUnit: String
        if ["g", "gram", "grams", "ml", "milliliter", "milliliters"].contains(lowerUnit),
           let weight,
           abs(weight - quantity) > 0.01,
           quantity > 0,
           quantity < 10 {
            displayUnit = "serving"
        } else {
            displayUnit = rawUnit
        }
        if displayUnit.lowercased() == "serving", quantity == 1 {
            return "1 serving"
        }
        return "\(quantity.cleanString) \(displayUnit)"
    }
}

struct CalorieLibraryItem: Identifiable, Equatable {
    let id: String
    let canonicalFoodId: String?
    let kind: String
    let name: String
    let brand: String?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let defaultServingQty: Double?
    let defaultServingUnit: String?
    let defaultServingWeight: Double?
    let notes: String?
    let sourceTitle: String?
    let sourceURL: String?
    let aliases: [String]
    let isFavorite: Bool

    var detail: String {
        let type = kind == "recipe" ? "Recipe" : "Food"
        let serving = defaultServingUnit.flatMap { unit in
            defaultServingQty.map { "\($0.cleanString) \(unit)" }
        } ?? "serving"
        return "\(type) · \(calories.cleanString) kcal · \(serving)"
    }
}

struct RecipeComponentItem: Identifiable, Equatable {
    let id: String
    var recipeId: String
    var componentItemId: String?
    var componentName: String
    var quantity: Double
    var unit: String
    var weight: Double?
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var sortOrder: Int
    var notes: String?

    var detail: String {
        "\(quantity.cleanString) \(unit) · \(calories.cleanString) kcal · P \(protein.cleanString)g · C \(carbs.cleanString)g · F \(fat.cleanString)g"
    }
}

struct CanonicalFoodItem: Identifiable, Equatable {
    let id: String
    let canonicalName: String
    let displayName: String
    let brand: String?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let defaultServingQty: Double?
    let defaultServingUnit: String?
    let defaultServingWeight: Double?
    let lastUsedAtMs: Int64?

    var title: String {
        brand.map { "\($0) \(displayName)" } ?? displayName
    }

    var detail: String {
        let serving = defaultServingUnit.flatMap { unit in
            defaultServingQty.map { "\($0.cleanString) \(unit)" }
        } ?? "serving"
        return "\(calories.cleanString) kcal · P \(protein.cleanString)g · \(serving)"
    }
}

struct MealTemplate: Identifiable, Equatable {
    let id: String
    let name: String
    let itemCount: Int
    let libraryItemIDs: [String]
}

enum CalorieMealType: String, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snack
    case drink
    case preWorkout = "pre_workout"
    case postWorkout = "post_workout"
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snack: return "Snack"
        case .drink: return "Drinks"
        case .preWorkout: return "Pre-workout"
        case .postWorkout: return "Post-workout"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "takeoutbag.and.cup.and.straw.fill"
        case .drink: return "cup.and.saucer.fill"
        case .preWorkout: return "bolt.fill"
        case .postWorkout: return "checkmark.circle.fill"
        case .other: return "fork.knife"
        }
    }

    var tint: Color {
        DashboardTone.textSecondary
    }

    static var currentDefault: CalorieMealType {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snack
        }
    }

    init(databaseValue: String?) {
        let normalized = databaseValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "preworkout", "pre_workout":
            self = .preWorkout
        case "postworkout", "post_workout":
            self = .postWorkout
        default:
            self = normalized.flatMap(Self.init(rawValue:)) ?? .other
        }
    }
}

struct DailyNote: Equatable {
    let note: String
    let mood: String?
    let hunger: String?
    let training: String?
}

struct CalorieDaySummary: Equatable {
    var totals = CalorieTotals()
    var goal = CalorieGoal()
    var logCount = 0
}

private struct CalorieLogItemCopy {
    let libraryItemId: String?
    let servingCount: Double?
    let unit: String?
    let weight: Double?
    let name: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let notes: String?
    let sourceId: String?
    let mealType: CalorieMealType
    let nutrients: [FoodLogNutrientCopy]
    let attachments: [PhotoAttachmentCopy]
}

private struct FoodLogNutrientCopy {
    let key: String
    let amount: Double
}

private struct PhotoAttachmentCopy {
    let relativePath: String
    let mimeType: String
    let byteSize: Int64
}

@MainActor
final class CalorieTrackerStore: ObservableObject {
    static let shared = CalorieTrackerStore()

    @Published var todayTotals = CalorieTotals()
    @Published var goal = CalorieGoal()
    @Published var todayLogs: [CalorieLogItem] = []
    @Published var libraryItems: [CalorieLibraryItem] = []
    @Published var recentFoodMemories: [CanonicalFoodItem] = []
    @Published var mealTemplates: [MealTemplate] = []
    @Published var dailyNote: DailyNote?
    @Published var recentDaySummaries: [String: CalorieDaySummary] = [:]
    @Published var errorMessage: String?
    @Published var selectedDate = Calendar.current.startOfDay(for: Date())
    @Published var dashboardRefreshGeneration = 0

    private(set) var hasClaimedInitialDashboardMetricsReveal = false
    private var db: OpaquePointer?
    private let calendar = Calendar.current
    private var isRefreshing = false
    private var lastQueuedHealthKitSyncKey: String?
    private var lastQueuedHealthKitSyncAt: Date?

    private init() {}

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func claimInitialDashboardMetricsReveal() -> Bool {
        guard !hasClaimedInitialDashboardMetricsReveal else { return false }
        hasClaimedInitialDashboardMetricsReveal = true
        return true
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            dashboardRefreshGeneration += 1
        }

        do {
            try openIfNeeded()
            try migrate()
            try loadDashboard()
            try loadRecentDaySummaries()
            try loadLibrary()
            try loadRecentFoodMemories()
            try loadTemplates()
            try loadDailyNote()
            errorMessage = nil
            queueHealthKitSyncIfNeeded(for: todayKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDate(_ date: Date) async {
        selectedDate = calendar.startOfDay(for: date)
        await refresh()
    }

    func logFood(
        name: String,
        calories: Double,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        fiber: Double?,
        sugars: Double?,
        sodium: Double?,
        potassium: Double?,
        notes: String,
        sourceTitle: String,
        sourceURL: String = "",
        mealType: CalorieMealType,
        photoData: Data?,
        saveToLibrary: Bool,
        servingQty: Double = 1,
        servingUnit: String = "serving",
        servingWeight: Double? = nil
    ) async {
        do {
            try openIfNeeded()
            let sourceId = try insertSourceIfNeeded(title: sourceTitle, url: sourceURL)
            let canonicalFoodId = try upsertCanonicalFood(
                name: name,
                brand: nil,
                servingQty: servingQty,
                servingUnit: servingUnit,
                servingWeight: servingWeight,
                calories: calories,
                protein: protein ?? 0,
                carbs: carbs ?? 0,
                fat: fat ?? 0,
                sourceId: sourceId,
                markUsed: true
            )
            let entryId = try upsertMealEntry(mealType)
            let itemId = UUID().uuidString
            try execute(
                """
                INSERT INTO food_log_items (
                    id, entry_id, canonical_food_id, log_date, logged_at_ms, name, serving_count, unit,
                    weight_g, calories_kcal, protein_g, carbs_g, fat_g, notes, source_id, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [itemId, entryId, canonicalFoodId, todayKey, nowMs, name.trimmed, servingQty, servingUnit.trimmed.nilIfBlank ?? "serving", servingWeight, calories, protein ?? 0, carbs ?? 0, fat ?? 0, notes.nilIfBlank, sourceId, nowMs, nowMs]
            )
            try insertOptionalNutrient(logItemId: itemId, key: "fiber_g", amount: fiber)
            try insertOptionalNutrient(logItemId: itemId, key: "sugars_g", amount: sugars)
            try insertOptionalNutrient(logItemId: itemId, key: "sodium_mg", amount: sodium)
            try insertOptionalNutrient(logItemId: itemId, key: "potassium_mg", amount: potassium)
            if let photoData {
                try saveAttachment(data: photoData, entityType: "log_item", entityId: itemId)
            }
            if saveToLibrary {
                try insertLibraryItem(
                    kind: "food",
                    name: name,
                    brand: nil,
                    servingQty: servingQty,
                    servingUnit: servingUnit,
                    servingWeight: servingWeight,
                    calories: calories,
                    protein: protein,
                    carbs: carbs,
                    fat: fat,
                    aliases: "",
                    notes: notes,
                    sourceId: sourceId,
                    canonicalFoodId: canonicalFoodId
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveLibraryItem(
        kind: String,
        name: String,
        brand: String,
        servingQty: Double?,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        aliases: String,
        notes: String,
        sourceTitle: String,
        sourceURL: String = ""
    ) async -> String? {
        do {
            try openIfNeeded()
            let sourceId = try insertSourceIfNeeded(title: sourceTitle, url: sourceURL)
            let id = try insertLibraryItem(
                kind: kind,
                name: name,
                brand: brand.nilIfBlank,
                servingQty: servingQty,
                servingUnit: servingUnit,
                servingWeight: servingWeight,
                calories: calories,
                protein: protein,
                carbs: carbs,
                fat: fat,
                aliases: aliases,
                notes: notes,
                sourceId: sourceId,
                canonicalFoodId: nil
            )
            await refresh()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateLibraryItem(
        _ id: String,
        kind: String,
        name: String,
        brand: String,
        servingQty: Double?,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        aliases: String,
        notes: String,
        sourceTitle: String,
        sourceURL: String = ""
    ) async {
        do {
            try openIfNeeded()
            let normalizedUnit = servingUnit.trimmed.nilIfBlank ?? "serving"
            let sourceId = try insertSourceIfNeeded(title: sourceTitle, url: sourceURL)
            let canonicalFoodId = try upsertCanonicalFood(
                name: name,
                brand: brand.nilIfBlank,
                servingQty: servingQty,
                servingUnit: normalizedUnit,
                servingWeight: servingWeight,
                calories: calories,
                protein: protein ?? 0,
                carbs: carbs ?? 0,
                fat: fat ?? 0,
                sourceId: sourceId,
                markUsed: false
            )
            try execute(
                """
                UPDATE food_library_items
                SET kind = ?, name = ?, brand = ?, default_serving_qty = ?, default_serving_unit = ?,
                    default_serving_weight_g = ?, calories_kcal = ?, protein_g = ?, carbs_g = ?,
                    fat_g = ?, notes = ?, source_id = ?, canonical_food_id = ?, updated_at_ms = ?
                WHERE id = ? AND deleted_at_ms IS NULL
                """,
                [
                    kind,
                    name.trimmed,
                    brand.nilIfBlank,
                    servingQty,
                    normalizedUnit,
                    servingWeight,
                    calories,
                    protein ?? 0,
                    carbs ?? 0,
                    fat ?? 0,
                    notes.nilIfBlank,
                    sourceId,
                    canonicalFoodId,
                    nowMs,
                    id
                ]
            )
            try upsertDefaultServingUnit(libraryItemId: id, quantity: servingQty ?? 1, unit: normalizedUnit, gramWeight: servingWeight)
            try replaceAliases(libraryItemId: id, aliases: aliases)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadRecipeComponents(recipeId: String) async -> [RecipeComponentItem] {
        do {
            try openIfNeeded()
            return try fetchRecipeComponents(recipeId: recipeId)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func saveRecipeComponents(recipeId: String, components: [RecipeComponentItem]) async {
        do {
            try openIfNeeded()
            try replaceRecipeComponents(recipeId: recipeId, components: components)
            try updateRecipeTotalsFromComponents(recipeId: recipeId)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateCanonicalFood(
        _ id: String,
        displayName: String,
        brand: String,
        servingQty: Double?,
        servingUnit: String,
        calories: Double,
        protein: Double?,
        carbs: Double?,
        fat: Double?
    ) async {
        do {
            try openIfNeeded()
            let name = displayName.trimmed
            let normalizedName = Self.normalizedFoodKey(name)
            let normalizedBrand = Self.normalizedFoodKey(brand)
            try execute(
                """
                UPDATE canonical_food_items
                SET canonical_name = ?, normalized_name = ?, normalized_brand = ?, display_name = ?,
                    brand = ?, default_serving_qty = ?, default_serving_unit = ?,
                    calories_kcal = ?, protein_g = ?, carbs_g = ?, fat_g = ?, updated_at_ms = ?
                WHERE id = ? AND deleted_at_ms IS NULL
                """,
                [
                    name,
                    normalizedName,
                    normalizedBrand,
                    name,
                    brand.nilIfBlank,
                    servingQty,
                    servingUnit.trimmed.nilIfBlank ?? "serving",
                    calories,
                    protein ?? 0,
                    carbs ?? 0,
                    fat ?? 0,
                    nowMs,
                    id
                ]
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateLibraryItem(_ id: String) async {
        do {
            try openIfNeeded()
            guard let item = try fetchLibraryItem(id: id) else { return }
            let sourceId = try insertSourceIfNeeded(title: item.sourceTitle ?? "", url: item.sourceURL ?? "")
            try insertLibraryItem(
                kind: item.kind,
                name: "\(item.name) Copy",
                brand: item.brand,
                servingQty: item.defaultServingQty,
                servingUnit: item.defaultServingUnit ?? "serving",
                servingWeight: item.defaultServingWeight,
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat,
                aliases: item.aliases.joined(separator: ", "),
                notes: item.notes ?? "",
                sourceId: sourceId,
                canonicalFoodId: item.canonicalFoodId
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveMealTemplate(name: String, libraryItemIDs: [String]) async {
        do {
            try openIfNeeded()
            let templateId = UUID().uuidString
            try execute(
                "INSERT INTO meal_templates (id, name, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?)",
                [templateId, name.trimmed, nowMs, nowMs]
            )
            for (index, itemId) in libraryItemIDs.enumerated() {
                try execute(
                    """
                    INSERT INTO meal_template_items (
                        id, template_id, library_item_id, quantity, sort_order, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [UUID().uuidString, templateId, itemId, 1.0, index, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateMealTemplate(_ id: String, name: String, libraryItemIDs: [String]) async {
        do {
            try openIfNeeded()
            try execute(
                "UPDATE meal_templates SET name = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                [name.trimmed, nowMs, id]
            )
            try execute(
                "UPDATE meal_template_items SET deleted_at_ms = ?, updated_at_ms = ? WHERE template_id = ? AND deleted_at_ms IS NULL",
                [nowMs, nowMs, id]
            )
            for (index, itemId) in libraryItemIDs.enumerated() {
                try execute(
                    """
                    INSERT INTO meal_template_items (
                        id, template_id, library_item_id, quantity, sort_order, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [UUID().uuidString, id, itemId, 1.0, index, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateMealTemplate(_ id: String) async {
        do {
            try openIfNeeded()
            guard let name = try scalarString(
                "SELECT name FROM meal_templates WHERE id = ? AND deleted_at_ms IS NULL LIMIT 1",
                [id]
            ) else { return }
            let itemIDs = try mealTemplateItemIDs(id)
            let templateId = UUID().uuidString
            try execute(
                "INSERT INTO meal_templates (id, name, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?)",
                [templateId, "\(name) Copy", nowMs, nowMs]
            )
            for (index, itemId) in itemIDs.enumerated() {
                try execute(
                    """
                    INSERT INTO meal_template_items (
                        id, template_id, library_item_id, quantity, sort_order, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [UUID().uuidString, templateId, itemId, 1.0, index, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logLibraryItem(_ id: String, mealType: CalorieMealType) async {
        do {
            try openIfNeeded()
            guard let item = try fetchLibraryItem(id: id) else { return }
            try logLibraryItem(
                item,
                mealType: mealType,
                servingQty: item.defaultServingQty ?? 1.0,
                servingUnit: item.defaultServingUnit ?? "serving",
                servingWeight: item.defaultServingWeight,
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat,
                notes: nil
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logLibraryItem(
        _ id: String,
        mealType: CalorieMealType,
        servingQty: Double,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        notes: String?
    ) async {
        do {
            try openIfNeeded()
            guard let item = try fetchLibraryItem(id: id) else { return }
            try logLibraryItem(
                item,
                mealType: mealType,
                servingQty: servingQty,
                servingUnit: servingUnit,
                servingWeight: servingWeight,
                calories: calories,
                protein: protein,
                carbs: carbs,
                fat: fat,
                notes: notes
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func logLibraryItem(
        _ item: CalorieLibraryItem,
        mealType: CalorieMealType,
        servingQty: Double,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        notes: String?
    ) throws {
            let canonicalFoodId = try item.canonicalFoodId ?? upsertCanonicalFood(
                name: item.name,
                brand: item.brand,
                servingQty: item.defaultServingQty,
                servingUnit: item.defaultServingUnit ?? "serving",
                servingWeight: item.defaultServingWeight,
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat,
                sourceId: nil,
                markUsed: true
            )
            if item.canonicalFoodId == nil {
                try execute(
                    "UPDATE food_library_items SET canonical_food_id = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                    [canonicalFoodId, nowMs, item.id]
                )
            } else {
                try markCanonicalFoodUsed(canonicalFoodId)
            }
            let entryId = try upsertMealEntry(mealType)
            try execute(
                """
                INSERT INTO food_log_items (
                    id, entry_id, canonical_food_id, library_item_id, log_date, logged_at_ms, name, serving_count,
                    unit, weight_g, calories_kcal, protein_g, carbs_g, fat_g, notes, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [UUID().uuidString, entryId, canonicalFoodId, item.id, todayKey, nowMs, item.name, servingQty, servingUnit.trimmed.nilIfBlank ?? "serving", servingWeight, calories, protein, carbs, fat, notes?.nilIfBlank, nowMs, nowMs]
            )
    }

    func logMealTemplate(_ id: String, mealType: CalorieMealType) async {
        do {
            try openIfNeeded()
            let entryId = try upsertMealEntry(mealType)
            let rows = try query(
                """
                SELECT fli.id, fli.canonical_food_id, fli.name, fli.brand, fli.calories_kcal,
                       COALESCE(fli.protein_g, 0), COALESCE(fli.carbs_g, 0), COALESCE(fli.fat_g, 0),
                       fli.default_serving_qty, fli.default_serving_unit, fli.default_serving_weight_g
                FROM meal_template_items mti
                JOIN food_library_items fli ON fli.id = mti.library_item_id
                WHERE mti.template_id = ? AND mti.deleted_at_ms IS NULL AND fli.deleted_at_ms IS NULL
                ORDER BY mti.sort_order
                """,
                [id]
            ) { statement in
                (
                    id: sqliteText(statement, 0),
                    canonicalFoodId: sqliteOptionalText(statement, 1),
                    name: sqliteText(statement, 2),
                    brand: sqliteOptionalText(statement, 3),
                    calories: sqliteDouble(statement, 4),
                    protein: sqliteDouble(statement, 5),
                    carbs: sqliteDouble(statement, 6),
                    fat: sqliteDouble(statement, 7),
                    servingQty: sqliteOptionalDouble(statement, 8),
                    servingUnit: sqliteOptionalText(statement, 9),
                    servingWeight: sqliteOptionalDouble(statement, 10)
                )
            }
            for row in rows {
                let canonicalFoodId = try row.canonicalFoodId ?? upsertCanonicalFood(
                    name: row.name,
                    brand: row.brand,
                    servingQty: row.servingQty,
                    servingUnit: row.servingUnit ?? "serving",
                    servingWeight: row.servingWeight,
                    calories: row.calories,
                    protein: row.protein,
                    carbs: row.carbs,
                    fat: row.fat,
                    sourceId: nil,
                    markUsed: true
                )
                if row.canonicalFoodId == nil {
                    try execute(
                        "UPDATE food_library_items SET canonical_food_id = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                        [canonicalFoodId, nowMs, row.id]
                    )
                } else {
                    try markCanonicalFoodUsed(canonicalFoodId)
                }
                try execute(
                    """
                    INSERT INTO food_log_items (
                        id, entry_id, canonical_food_id, library_item_id, log_date, logged_at_ms, name, serving_count,
                        unit, weight_g, calories_kcal, protein_g, carbs_g, fat_g, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [UUID().uuidString, entryId, canonicalFoodId, row.id, todayKey, nowMs, row.name, row.servingQty ?? 1.0, row.servingUnit ?? "serving", row.servingWeight, row.calories, row.protein, row.carbs, row.fat, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(_ libraryItemId: String) async {
        do {
            try openIfNeeded()
            let existing = try scalarString(
                "SELECT id FROM favorite_foods WHERE library_item_id = ? AND deleted_at_ms IS NULL LIMIT 1",
                [libraryItemId]
            )
            if let existing {
                try execute("UPDATE favorite_foods SET deleted_at_ms = ?, updated_at_ms = ? WHERE id = ?", [nowMs, nowMs, existing])
            } else {
                try execute(
                    "INSERT INTO favorite_foods (id, library_item_id, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?)",
                    [UUID().uuidString, libraryItemId, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavoriteForLogItem(_ logItemId: String) async {
        do {
            try openIfNeeded()
            guard let copy = try fetchLogItemCopy(id: logItemId) else { return }
            let libraryItemId: String
            let canonicalFoodId: String
            if let existingId = copy.libraryItemId {
                libraryItemId = existingId
                let existingCanonicalFoodId = try scalarString(
                    "SELECT canonical_food_id FROM food_library_items WHERE id = ? AND deleted_at_ms IS NULL LIMIT 1",
                    [existingId]
                )
                if let existingCanonicalFoodId {
                    canonicalFoodId = existingCanonicalFoodId
                } else {
                    canonicalFoodId = try upsertCanonicalFood(
                        name: copy.name,
                        brand: nil,
                        servingQty: copy.servingCount,
                        servingUnit: "serving",
                        servingWeight: nil,
                        calories: copy.calories,
                        protein: copy.protein,
                        carbs: copy.carbs,
                        fat: copy.fat,
                        sourceId: copy.sourceId,
                        markUsed: false
                    )
                    try execute(
                        "UPDATE food_library_items SET canonical_food_id = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                        [canonicalFoodId, nowMs, existingId]
                    )
                    try execute(
                        "UPDATE food_log_items SET canonical_food_id = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                        [canonicalFoodId, nowMs, logItemId]
                    )
                }
            } else {
                libraryItemId = try insertLibraryItem(
                    kind: "food",
                    name: copy.name,
                    brand: nil,
                    servingQty: copy.servingCount,
                    servingUnit: "serving",
                    servingWeight: nil,
                    calories: copy.calories,
                    protein: copy.protein,
                    carbs: copy.carbs,
                    fat: copy.fat,
                    aliases: "",
                    notes: copy.notes ?? "",
                    sourceId: copy.sourceId,
                    canonicalFoodId: nil
                )
                canonicalFoodId = try scalarString(
                    "SELECT canonical_food_id FROM food_library_items WHERE id = ? AND deleted_at_ms IS NULL LIMIT 1",
                    [libraryItemId]
                ) ?? upsertCanonicalFood(
                    name: copy.name,
                    brand: nil,
                    servingQty: copy.servingCount,
                    servingUnit: "serving",
                    servingWeight: nil,
                    calories: copy.calories,
                    protein: copy.protein,
                    carbs: copy.carbs,
                    fat: copy.fat,
                    sourceId: copy.sourceId,
                    markUsed: false
                )
                try execute(
                    "UPDATE food_log_items SET library_item_id = ?, canonical_food_id = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                    [libraryItemId, canonicalFoodId, nowMs, logItemId]
                )
            }

            let existingFavorite = try scalarString(
                "SELECT id FROM favorite_foods WHERE library_item_id = ? AND deleted_at_ms IS NULL LIMIT 1",
                [libraryItemId]
            )
            if let existingFavorite {
                try execute("UPDATE favorite_foods SET deleted_at_ms = ?, updated_at_ms = ? WHERE id = ?", [nowMs, nowMs, existingFavorite])
            } else {
                try execute(
                    "INSERT INTO favorite_foods (id, library_item_id, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?)",
                    [UUID().uuidString, libraryItemId, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func softDeleteLibraryItem(_ id: String) async {
        await softDelete(table: "food_library_items", id: id)
    }

    func softDeleteLogItem(_ id: String) async {
        await softDelete(table: "food_log_items", id: id)
    }

    func softDeleteMealTemplate(_ id: String) async {
        await softDelete(table: "meal_templates", id: id)
    }

    func updateLogItem(
        _ id: String,
        name: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        servingCount: Double?,
        unit: String,
        weight: Double?,
        notes: String,
        mealType: CalorieMealType
    ) async {
        do {
            try openIfNeeded()
            let entryId = try upsertMealEntry(mealType)
            try execute(
                """
                UPDATE food_log_items
                SET entry_id = ?, name = ?, calories_kcal = ?, protein_g = ?, carbs_g = ?, fat_g = ?,
                    serving_count = ?, unit = ?, weight_g = ?, notes = ?, updated_at_ms = ?
                WHERE id = ? AND deleted_at_ms IS NULL
                """,
                [entryId, name.trimmed, calories, protein, carbs, fat, servingCount, unit.trimmed.nilIfBlank ?? "serving", weight, notes.nilIfBlank, nowMs, id]
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateLogItem(_ id: String, toToday: Bool = false) async {
        do {
            try openIfNeeded()
            guard let copy = try fetchLogItemCopy(id: id) else { return }
            let targetDate = toToday ? calendar.startOfDay(for: Date()) : selectedDate
            let targetDateKey = Self.dateFormatter.string(from: targetDate)
            try insertLogItemCopy(copy, dateKey: targetDateKey, mealType: copy.mealType)
            if toToday {
                selectedDate = targetDate
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateMeal(_ mealType: CalorieMealType, toToday: Bool = false) async {
        do {
            try openIfNeeded()
            let ids = try logItemIds(for: mealType)
            let targetDate = toToday ? calendar.startOfDay(for: Date()) : selectedDate
            let targetDateKey = Self.dateFormatter.string(from: targetDate)
            for id in ids {
                guard let copy = try fetchLogItemCopy(id: id) else { continue }
                try insertLogItemCopy(copy, dateKey: targetDateKey, mealType: mealType)
            }
            if toToday {
                selectedDate = targetDate
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveMeal(_ sourceMeal: CalorieMealType, to targetMeal: CalorieMealType) async {
        guard sourceMeal != targetMeal else { return }
        do {
            try openIfNeeded()
            let entryIds = try mealEntryIds(for: sourceMeal)
            guard !entryIds.isEmpty else { return }
            let targetEntryId = try upsertMealEntry(targetMeal)
            let placeholders = entryIds.map { _ in "?" }.joined(separator: ", ")
            var values: [Any?] = [targetEntryId, nowMs]
            entryIds.forEach { values.append($0) }
            values.append(todayKey)
            try execute(
                """
                UPDATE food_log_items
                SET entry_id = ?, updated_at_ms = ?
                WHERE entry_id IN (\(placeholders)) AND log_date = ? AND deleted_at_ms IS NULL
                """,
                values
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteMeal(_ mealType: CalorieMealType) async {
        do {
            try openIfNeeded()
            let entryIds = try mealEntryIds(for: mealType)
            guard !entryIds.isEmpty else { return }
            let placeholders = entryIds.map { _ in "?" }.joined(separator: ", ")
            var values: [Any?] = [nowMs, nowMs]
            entryIds.forEach { values.append($0) }
            values.append(todayKey)
            try execute(
                """
                UPDATE food_log_items
                SET deleted_at_ms = ?, updated_at_ms = ?
                WHERE entry_id IN (\(placeholders)) AND log_date = ? AND deleted_at_ms IS NULL
                """,
                values
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveGoals(calories: Double, protein: Double, carbs: Double, fat: Double, overrideToday: Bool) async {
        do {
            try openIfNeeded()
            if overrideToday {
                let overrideId = try upsertDailyOverride()
                try upsertGoalTargets(ownerTable: "daily_goal_override_targets", ownerColumn: "override_id", ownerId: overrideId, calories: calories, protein: protein, carbs: carbs, fat: fat)
            } else {
                let profileId = try activeGoalProfileId()
                try upsertGoalTargets(ownerTable: "goal_profile_targets", ownerColumn: "profile_id", ownerId: profileId, calories: calories, protein: protein, carbs: carbs, fat: fat)
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDailyNote(note: String, mood: String, hunger: String, training: String) async {
        do {
            try openIfNeeded()
            if let id = try scalarString("SELECT id FROM daily_notes WHERE note_date = ? AND deleted_at_ms IS NULL LIMIT 1", [todayKey]) {
                try execute(
                    """
                    UPDATE daily_notes
                    SET note = ?, mood = ?, hunger = ?, training = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                    [note, mood.nilIfBlank, hunger.nilIfBlank, training.nilIfBlank, nowMs, id]
                )
            } else {
                try execute(
                    """
                    INSERT INTO daily_notes (
                        id, note_date, note, mood, hunger, training, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [UUID().uuidString, todayKey, note, mood.nilIfBlank, hunger.nilIfBlank, training.nilIfBlank, nowMs, nowMs]
                )
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteDailyNote() async {
        do {
            try openIfNeeded()
            try execute(
                "UPDATE daily_notes SET deleted_at_ms = ?, updated_at_ms = ? WHERE note_date = ? AND deleted_at_ms IS NULL",
                [nowMs, nowMs, todayKey]
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func image(for logItemId: String) -> UIImage? {
        guard let item = todayLogs.first(where: { $0.id == logItemId }),
              let photoPath = item.photoPath else { return nil }
        return UIImage(contentsOfFile: attachmentsDirectory.appendingPathComponent(photoPath).path)
    }

    func logs(for mealType: CalorieMealType) -> [CalorieLogItem] {
        todayLogs.filter { $0.mealType == mealType }
    }

    func summary(for date: Date) -> CalorieDaySummary {
        let key = Self.dateFormatter.string(from: calendar.startOfDay(for: date))
        if key == todayKey {
            return CalorieDaySummary(totals: todayTotals, goal: goal, logCount: todayLogs.count)
        }
        return recentDaySummaries[key] ?? CalorieDaySummary(totals: .init(), goal: goal, logCount: 0)
    }

    func summaryForDate(_ date: Date) async -> CalorieDaySummary {
        do {
            try openIfNeeded()
            try migrate()
            let key = Self.dateFormatter.string(from: calendar.startOfDay(for: date))
            return try loadDaySummary(dateKey: key)
        } catch {
            errorMessage = error.localizedDescription
            return CalorieDaySummary(totals: .init(), goal: goal, logCount: 0)
        }
    }

    func moveLogItem(_ id: String, to mealType: CalorieMealType) async {
        do {
            try openIfNeeded()
            let entryId = try upsertMealEntry(mealType)
            try execute(
                "UPDATE food_log_items SET entry_id = ?, updated_at_ms = ? WHERE id = ? AND deleted_at_ms IS NULL",
                [entryId, nowMs, id]
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logCanonicalFood(_ id: String, mealType: CalorieMealType) async {
        do {
            try openIfNeeded()
            guard let item = try fetchCanonicalFood(id: id) else { return }
            try logCanonicalFood(
                item,
                mealType: mealType,
                servingQty: item.defaultServingQty ?? 1,
                servingUnit: item.defaultServingUnit ?? "serving",
                servingWeight: item.defaultServingWeight,
                calories: item.calories,
                protein: item.protein,
                carbs: item.carbs,
                fat: item.fat,
                notes: nil
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logCanonicalFood(
        _ id: String,
        mealType: CalorieMealType,
        servingQty: Double,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        notes: String?
    ) async {
        do {
            try openIfNeeded()
            guard let item = try fetchCanonicalFood(id: id) else { return }
            try logCanonicalFood(
                item,
                mealType: mealType,
                servingQty: servingQty,
                servingUnit: servingUnit,
                servingWeight: servingWeight,
                calories: calories,
                protein: protein,
                carbs: carbs,
                fat: fat,
                notes: notes
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func logCanonicalFood(
        _ item: CanonicalFoodItem,
        mealType: CalorieMealType,
        servingQty: Double,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        notes: String?
    ) throws {
            try markCanonicalFoodUsed(item.id)
            let entryId = try upsertMealEntry(mealType)
            try execute(
                """
                INSERT INTO food_log_items (
                    id, entry_id, canonical_food_id, log_date, logged_at_ms, name, serving_count,
                    unit, weight_g, calories_kcal, protein_g, carbs_g, fat_g, notes, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [UUID().uuidString, entryId, item.id, todayKey, nowMs, item.displayName, servingQty, servingUnit.trimmed.nilIfBlank ?? "serving", servingWeight, calories, protein, carbs, fat, notes?.nilIfBlank, nowMs, nowMs]
            )
    }

    func loadCanonicalFoods(query: String, limit: Int, offset: Int) async -> [CanonicalFoodItem] {
        do {
            try openIfNeeded()
            try migrate()
            return try fetchCanonicalFoods(queryText: query, limit: limit, offset: offset, recentOnly: false)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private func softDelete(table: String, id: String) async {
        do {
            try openIfNeeded()
            try execute("UPDATE \(table) SET deleted_at_ms = ?, updated_at_ms = ? WHERE id = ?", [nowMs, nowMs, id])
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDashboard() throws {
        let totals = try query(
            """
            SELECT
                COALESCE(SUM(calories_kcal), 0),
                COALESCE(SUM(COALESCE(protein_g, 0)), 0),
                COALESCE(SUM(COALESCE(carbs_g, 0)), 0),
                COALESCE(SUM(COALESCE(fat_g, 0)), 0)
            FROM food_log_items
            WHERE log_date = ? AND deleted_at_ms IS NULL
            """,
            [todayKey]
        ) { statement in
            CalorieTotals(
                calories: sqliteDouble(statement, 0),
                protein: sqliteDouble(statement, 1),
                carbs: sqliteDouble(statement, 2),
                fat: sqliteDouble(statement, 3)
            )
        }.first ?? CalorieTotals()

        let logs = try query(
            """
            SELECT fli.id, fli.canonical_food_id, fli.library_item_id, fli.name, fle.meal_type,
                   fli.serving_count, fli.unit, fli.weight_g,
                   fli.calories_kcal, COALESCE(fli.protein_g, 0),
                   COALESCE(fli.carbs_g, 0), COALESCE(fli.fat_g, 0), fli.notes, fli.logged_at_ms,
                   pa.file_relative_path, CASE WHEN ff.id IS NULL THEN 0 ELSE 1 END
            FROM food_log_items fli
            LEFT JOIN food_log_entries fle ON fle.id = fli.entry_id
                AND fle.deleted_at_ms IS NULL
            LEFT JOIN favorite_foods ff ON ff.library_item_id = fli.library_item_id
                AND ff.deleted_at_ms IS NULL
            LEFT JOIN photo_attachments pa ON pa.entity_id = fli.id
                AND pa.entity_type = 'log_item'
                AND pa.deleted_at_ms IS NULL
            WHERE fli.log_date = ? AND fli.deleted_at_ms IS NULL
            ORDER BY fli.logged_at_ms ASC
            """,
            [todayKey]
        ) { statement in
            CalorieLogItem(
                id: sqliteText(statement, 0),
                canonicalFoodId: sqliteOptionalText(statement, 1),
                libraryItemId: sqliteOptionalText(statement, 2),
                name: sqliteText(statement, 3),
                mealType: CalorieMealType(databaseValue: sqliteOptionalText(statement, 4)),
                servingCount: sqliteOptionalDouble(statement, 5),
                unit: sqliteOptionalText(statement, 6),
                weight: sqliteOptionalDouble(statement, 7),
                calories: sqliteDouble(statement, 8),
                protein: sqliteDouble(statement, 9),
                carbs: sqliteDouble(statement, 10),
                fat: sqliteDouble(statement, 11),
                notes: sqliteOptionalText(statement, 12),
                loggedAtMs: sqliteInt64(statement, 13),
                photoPath: sqliteOptionalText(statement, 14),
                isFavorite: sqliteInt(statement, 15) == 1
            )
        }

        todayTotals = totals
        todayLogs = logs
        goal = try loadGoal()
    }

    private func loadLibrary() throws {
        libraryItems = try query(
            """
            SELECT fli.id, fli.canonical_food_id, fli.kind, fli.name, fli.brand, fli.calories_kcal,
                   COALESCE(fli.protein_g, 0), COALESCE(fli.carbs_g, 0), COALESCE(fli.fat_g, 0),
                   fli.default_serving_qty, fli.default_serving_unit, fli.default_serving_weight_g,
                   fli.notes, ns.title, ns.url, COALESCE(fa.aliases, ''),
                   CASE WHEN ff.id IS NULL THEN 0 ELSE 1 END
            FROM food_library_items fli
            LEFT JOIN favorite_foods ff ON ff.library_item_id = fli.id AND ff.deleted_at_ms IS NULL
            LEFT JOIN nutrition_sources ns ON ns.id = fli.source_id AND ns.deleted_at_ms IS NULL
            LEFT JOIN (
                SELECT library_item_id, GROUP_CONCAT(alias, ', ') AS aliases
                FROM food_aliases
                WHERE deleted_at_ms IS NULL
                GROUP BY library_item_id
            ) fa ON fa.library_item_id = fli.id
            WHERE fli.deleted_at_ms IS NULL
            ORDER BY fli.name COLLATE NOCASE
            """,
            []
        ) { statement in
            CalorieLibraryItem(
                id: sqliteText(statement, 0),
                canonicalFoodId: sqliteOptionalText(statement, 1),
                kind: sqliteText(statement, 2),
                name: sqliteText(statement, 3),
                brand: sqliteOptionalText(statement, 4),
                calories: sqliteDouble(statement, 5),
                protein: sqliteDouble(statement, 6),
                carbs: sqliteDouble(statement, 7),
                fat: sqliteDouble(statement, 8),
                defaultServingQty: sqliteOptionalDouble(statement, 9),
                defaultServingUnit: sqliteOptionalText(statement, 10),
                defaultServingWeight: sqliteOptionalDouble(statement, 11),
                notes: sqliteOptionalText(statement, 12),
                sourceTitle: sqliteOptionalText(statement, 13),
                sourceURL: sqliteOptionalText(statement, 14),
                aliases: sqliteText(statement, 15).split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty },
                isFavorite: sqliteInt(statement, 16) == 1
            )
        }
    }

    private func loadRecentFoodMemories() throws {
        recentFoodMemories = try fetchCanonicalFoods(queryText: "", limit: 10, offset: 0, recentOnly: true)
    }

    private func loadTemplates() throws {
        mealTemplates = try query(
            """
            SELECT mt.id, mt.name, COUNT(mti.id), COALESCE(GROUP_CONCAT(mti.library_item_id, ','), '')
            FROM meal_templates mt
            LEFT JOIN meal_template_items mti ON mti.template_id = mt.id AND mti.deleted_at_ms IS NULL
            WHERE mt.deleted_at_ms IS NULL
            GROUP BY mt.id, mt.name
            ORDER BY mt.name COLLATE NOCASE
            """,
            []
        ) { statement in
            MealTemplate(
                id: sqliteText(statement, 0),
                name: sqliteText(statement, 1),
                itemCount: sqliteInt(statement, 2),
                libraryItemIDs: sqliteText(statement, 3).split(separator: ",").map(String.init)
            )
        }
    }

    private func loadDailyNote() throws {
        dailyNote = try query(
            "SELECT note, mood, hunger, training FROM daily_notes WHERE note_date = ? AND deleted_at_ms IS NULL LIMIT 1",
            [todayKey]
        ) { statement in
            DailyNote(
                note: sqliteText(statement, 0),
                mood: sqliteOptionalText(statement, 1),
                hunger: sqliteOptionalText(statement, 2),
                training: sqliteOptionalText(statement, 3)
            )
        }.first
    }

    private func loadRecentDaySummaries() throws {
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -371, to: today) ?? today
        let startKey = Self.dateFormatter.string(from: startDate)
        let endKey = Self.dateFormatter.string(from: today)
        let rows = try query(
            """
            SELECT log_date,
                   COALESCE(SUM(calories_kcal), 0),
                   COALESCE(SUM(COALESCE(protein_g, 0)), 0),
                   COALESCE(SUM(COALESCE(carbs_g, 0)), 0),
                   COALESCE(SUM(COALESCE(fat_g, 0)), 0),
                   COUNT(id)
            FROM food_log_items
            WHERE log_date BETWEEN ? AND ? AND deleted_at_ms IS NULL
            GROUP BY log_date
            """,
            [startKey, endKey]
        ) { statement in
            (
                key: sqliteText(statement, 0),
                summary: CalorieDaySummary(
                    totals: CalorieTotals(
                        calories: sqliteDouble(statement, 1),
                        protein: sqliteDouble(statement, 2),
                        carbs: sqliteDouble(statement, 3),
                        fat: sqliteDouble(statement, 4)
                    ),
                    goal: goal,
                    logCount: sqliteInt(statement, 5)
                )
            )
        }

        recentDaySummaries = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.summary) })
    }

    private func loadDaySummary(dateKey: String) throws -> CalorieDaySummary {
        let totals = try query(
            """
            SELECT
                COALESCE(SUM(calories_kcal), 0),
                COALESCE(SUM(COALESCE(protein_g, 0)), 0),
                COALESCE(SUM(COALESCE(carbs_g, 0)), 0),
                COALESCE(SUM(COALESCE(fat_g, 0)), 0),
                COUNT(id)
            FROM food_log_items
            WHERE log_date = ? AND deleted_at_ms IS NULL
            """,
            [dateKey]
        ) { statement in
            CalorieDaySummary(
                totals: CalorieTotals(
                    calories: sqliteDouble(statement, 0),
                    protein: sqliteDouble(statement, 1),
                    carbs: sqliteDouble(statement, 2),
                    fat: sqliteDouble(statement, 3)
                ),
                goal: CalorieGoal(),
                logCount: sqliteInt(statement, 4)
            )
        }.first ?? CalorieDaySummary()

        return CalorieDaySummary(
            totals: totals.totals,
            goal: try loadGoal(forDateKey: dateKey),
            logCount: totals.logCount
        )
    }

    private func loadGoal() throws -> CalorieGoal {
        try loadGoal(forDateKey: todayKey)
    }

    private func loadGoal(forDateKey dateKey: String) throws -> CalorieGoal {
        if let overrideId = try scalarString("SELECT id FROM daily_goal_overrides WHERE goal_date = ? AND deleted_at_ms IS NULL LIMIT 1", [dateKey]) {
            let overrideGoal = try loadGoalTargets(table: "daily_goal_override_targets", ownerColumn: "override_id", ownerId: overrideId)
            if overrideGoal.calories > 0 { return overrideGoal }
        }
        let profileId = try activeGoalProfileId()
        return try loadGoalTargets(table: "goal_profile_targets", ownerColumn: "profile_id", ownerId: profileId)
    }

    private func loadGoalTargets(table: String, ownerColumn: String, ownerId: String) throws -> CalorieGoal {
        let rows = try query(
            "SELECT nutrient_key, target_amount FROM \(table) WHERE \(ownerColumn) = ?",
            [ownerId]
        ) { statement in
            (sqliteText(statement, 0), sqliteDouble(statement, 1))
        }
        var next = CalorieGoal()
        for (key, value) in rows {
            switch key {
            case "calories_kcal": next.calories = value
            case "protein_g": next.protein = value
            case "carbs_g": next.carbs = value
            case "fat_g": next.fat = value
            default: break
            }
        }
        return next
    }

    @discardableResult
    private func insertLibraryItem(
        kind: String,
        name: String,
        brand: String?,
        servingQty: Double?,
        servingUnit: String,
        servingWeight: Double?,
        calories: Double,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        aliases: String,
        notes: String,
        sourceId: String?,
        canonicalFoodId providedCanonicalFoodId: String?
    ) throws -> String {
        let id = UUID().uuidString
        let canonicalFoodId = try providedCanonicalFoodId ?? upsertCanonicalFood(
            name: name,
            brand: brand,
            servingQty: servingQty,
            servingUnit: servingUnit,
            servingWeight: servingWeight,
            calories: calories,
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0,
            sourceId: sourceId,
            markUsed: false
        )
        try execute(
            """
            INSERT INTO food_library_items (
                id, canonical_food_id, kind, name, brand, default_serving_qty, default_serving_unit, default_serving_weight_g,
                calories_kcal, protein_g, carbs_g, fat_g, notes, source_id, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [id, canonicalFoodId, kind, name.trimmed, brand, servingQty, servingUnit.trimmed.nilIfBlank ?? "serving", servingWeight, calories, protein ?? 0, carbs ?? 0, fat ?? 0, notes.nilIfBlank, sourceId, nowMs, nowMs]
        )
        try execute(
            """
            INSERT INTO serving_units (
                id, library_item_id, label, quantity, unit, gram_weight, is_default, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            """,
            [UUID().uuidString, id, servingUnit.trimmed.nilIfBlank ?? "serving", servingQty ?? 1, servingUnit.trimmed.nilIfBlank ?? "serving", servingWeight, nowMs, nowMs]
        )
        let aliasValues = aliases
            .split(separator: ",")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
        for alias in aliasValues {
            try execute(
                "INSERT INTO food_aliases (id, library_item_id, alias, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)",
                [UUID().uuidString, id, alias, nowMs, nowMs]
            )
        }
        return id
    }

    private func upsertDefaultServingUnit(libraryItemId: String, quantity: Double, unit: String, gramWeight: Double?) throws {
        if let servingId = try scalarString(
            "SELECT id FROM serving_units WHERE library_item_id = ? AND is_default = 1 AND deleted_at_ms IS NULL LIMIT 1",
            [libraryItemId]
        ) {
            try execute(
                """
                UPDATE serving_units
                SET label = ?, quantity = ?, unit = ?, gram_weight = ?, updated_at_ms = ?
                WHERE id = ?
                """,
                [unit, quantity, unit, gramWeight, nowMs, servingId]
            )
        } else {
            try execute(
                """
                INSERT INTO serving_units (
                    id, library_item_id, label, quantity, unit, gram_weight, is_default, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                [UUID().uuidString, libraryItemId, unit, quantity, unit, gramWeight, nowMs, nowMs]
            )
        }
    }

    private func replaceAliases(libraryItemId: String, aliases: String) throws {
        try execute(
            "UPDATE food_aliases SET deleted_at_ms = ?, updated_at_ms = ? WHERE library_item_id = ? AND deleted_at_ms IS NULL",
            [nowMs, nowMs, libraryItemId]
        )
        let aliasValues = aliases
            .split(separator: ",")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
        for alias in aliasValues {
            try execute(
                "INSERT INTO food_aliases (id, library_item_id, alias, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)",
                [UUID().uuidString, libraryItemId, alias, nowMs, nowMs]
            )
        }
    }

    private func mealTemplateItemIDs(_ templateId: String) throws -> [String] {
        try query(
            """
            SELECT library_item_id
            FROM meal_template_items
            WHERE template_id = ? AND deleted_at_ms IS NULL AND library_item_id IS NOT NULL
            ORDER BY sort_order ASC
            """,
            [templateId]
        ) { statement in
            sqliteText(statement, 0)
        }
    }

    private func fetchLibraryItem(id: String) throws -> CalorieLibraryItem? {
        try query(
            """
            SELECT fli.id, fli.canonical_food_id, fli.kind, fli.name, fli.brand, fli.calories_kcal,
                   COALESCE(fli.protein_g, 0), COALESCE(fli.carbs_g, 0), COALESCE(fli.fat_g, 0),
                   fli.default_serving_qty, fli.default_serving_unit, fli.default_serving_weight_g,
                   fli.notes, ns.title, ns.url, COALESCE(fa.aliases, ''),
                   CASE WHEN ff.id IS NULL THEN 0 ELSE 1 END
            FROM food_library_items fli
            LEFT JOIN favorite_foods ff ON ff.library_item_id = fli.id AND ff.deleted_at_ms IS NULL
            LEFT JOIN nutrition_sources ns ON ns.id = fli.source_id AND ns.deleted_at_ms IS NULL
            LEFT JOIN (
                SELECT library_item_id, GROUP_CONCAT(alias, ', ') AS aliases
                FROM food_aliases
                WHERE deleted_at_ms IS NULL
                GROUP BY library_item_id
            ) fa ON fa.library_item_id = fli.id
            WHERE fli.id = ? AND fli.deleted_at_ms IS NULL
            LIMIT 1
            """,
            [id]
        ) { statement in
            CalorieLibraryItem(
                id: sqliteText(statement, 0),
                canonicalFoodId: sqliteOptionalText(statement, 1),
                kind: sqliteText(statement, 2),
                name: sqliteText(statement, 3),
                brand: sqliteOptionalText(statement, 4),
                calories: sqliteDouble(statement, 5),
                protein: sqliteDouble(statement, 6),
                carbs: sqliteDouble(statement, 7),
                fat: sqliteDouble(statement, 8),
                defaultServingQty: sqliteOptionalDouble(statement, 9),
                defaultServingUnit: sqliteOptionalText(statement, 10),
                defaultServingWeight: sqliteOptionalDouble(statement, 11),
                notes: sqliteOptionalText(statement, 12),
                sourceTitle: sqliteOptionalText(statement, 13),
                sourceURL: sqliteOptionalText(statement, 14),
                aliases: sqliteText(statement, 15).split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty },
                isFavorite: sqliteInt(statement, 16) == 1
            )
        }.first
    }

    private func fetchRecipeComponents(recipeId: String) throws -> [RecipeComponentItem] {
        try query(
            """
            SELECT rc.id, rc.recipe_id, rc.component_item_id,
                   COALESCE(NULLIF(trim(rc.component_name), ''), fli.name), rc.quantity, rc.unit, rc.weight_g,
                   COALESCE(rc.calories_kcal, fli.calories_kcal * rc.quantity, 0),
                   COALESCE(rc.protein_g, COALESCE(fli.protein_g, 0) * rc.quantity, 0),
                   COALESCE(rc.carbs_g, COALESCE(fli.carbs_g, 0) * rc.quantity, 0),
                   COALESCE(rc.fat_g, COALESCE(fli.fat_g, 0) * rc.quantity, 0),
                   rc.sort_order, rc.notes
            FROM recipe_components rc
            LEFT JOIN food_library_items fli ON fli.id = rc.component_item_id AND fli.deleted_at_ms IS NULL
            WHERE rc.recipe_id = ? AND rc.deleted_at_ms IS NULL
            ORDER BY rc.sort_order ASC, rc.created_at_ms ASC
            """,
            [recipeId]
        ) { statement in
            RecipeComponentItem(
                id: sqliteText(statement, 0),
                recipeId: sqliteText(statement, 1),
                componentItemId: sqliteOptionalText(statement, 2),
                componentName: sqliteText(statement, 3),
                quantity: sqliteDouble(statement, 4),
                unit: sqliteText(statement, 5),
                weight: sqliteOptionalDouble(statement, 6),
                calories: sqliteDouble(statement, 7),
                protein: sqliteDouble(statement, 8),
                carbs: sqliteDouble(statement, 9),
                fat: sqliteDouble(statement, 10),
                sortOrder: sqliteInt(statement, 11),
                notes: sqliteOptionalText(statement, 12)
            )
        }
    }

    private func replaceRecipeComponents(recipeId: String, components: [RecipeComponentItem]) throws {
        try execute(
            "UPDATE recipe_components SET deleted_at_ms = ?, updated_at_ms = ? WHERE recipe_id = ? AND deleted_at_ms IS NULL",
            [nowMs, nowMs, recipeId]
        )
        for (index, component) in components.enumerated() {
            let sourceItem: CalorieLibraryItem?
            if let componentItemId = component.componentItemId {
                sourceItem = try fetchLibraryItem(id: componentItemId)
            } else {
                sourceItem = nil
            }
            let quantity = max(component.quantity, 0)
            let unit = component.unit.trimmed.nilIfBlank ?? sourceItem?.defaultServingUnit ?? "serving"
            let name = sourceItem?.name ?? component.componentName.trimmed
            let calories = sourceItem.map { $0.calories * quantity } ?? component.calories
            let protein = sourceItem.map { $0.protein * quantity } ?? component.protein
            let carbs = sourceItem.map { $0.carbs * quantity } ?? component.carbs
            let fat = sourceItem.map { $0.fat * quantity } ?? component.fat
            try execute(
                """
                INSERT INTO recipe_components (
                    id, recipe_id, component_item_id, component_name, quantity, unit, weight_g,
                    calories_kcal, protein_g, carbs_g, fat_g, sort_order, notes, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    UUID().uuidString,
                    recipeId,
                    component.componentItemId,
                    name,
                    quantity,
                    unit,
                    component.weight ?? sourceItem?.defaultServingWeight.map { $0 * quantity },
                    calories,
                    protein,
                    carbs,
                    fat,
                    index,
                    component.notes?.nilIfBlank,
                    nowMs,
                    nowMs
                ]
            )
        }
    }

    private func updateRecipeTotalsFromComponents(recipeId: String) throws {
        let totals = try query(
            """
            SELECT COALESCE(SUM(calories_kcal), 0), COALESCE(SUM(COALESCE(protein_g, 0)), 0),
                   COALESCE(SUM(COALESCE(carbs_g, 0)), 0), COALESCE(SUM(COALESCE(fat_g, 0)), 0)
            FROM recipe_components
            WHERE recipe_id = ? AND deleted_at_ms IS NULL
            """,
            [recipeId]
        ) { statement in
            CalorieTotals(
                calories: sqliteDouble(statement, 0),
                protein: sqliteDouble(statement, 1),
                carbs: sqliteDouble(statement, 2),
                fat: sqliteDouble(statement, 3)
            )
        }.first ?? CalorieTotals()
        try execute(
            """
            UPDATE food_library_items
            SET calories_kcal = ?, protein_g = ?, carbs_g = ?, fat_g = ?, updated_at_ms = ?
            WHERE id = ? AND kind = 'recipe' AND deleted_at_ms IS NULL
            """,
            [totals.calories, totals.protein, totals.carbs, totals.fat, nowMs, recipeId]
        )
    }

    private func fetchLogItemCopy(id: String) throws -> CalorieLogItemCopy? {
        let base = try query(
            """
            SELECT fli.library_item_id, fli.serving_count, fli.unit, fli.weight_g, fli.name, fli.calories_kcal,
                   COALESCE(fli.protein_g, 0), COALESCE(fli.carbs_g, 0), COALESCE(fli.fat_g, 0),
                   fli.notes, fli.source_id, fle.meal_type
            FROM food_log_items fli
            LEFT JOIN food_log_entries fle ON fle.id = fli.entry_id AND fle.deleted_at_ms IS NULL
            WHERE fli.id = ? AND fli.deleted_at_ms IS NULL
            LIMIT 1
            """,
            [id]
        ) { statement in
            (
                libraryItemId: sqliteOptionalText(statement, 0),
                servingCount: sqliteOptionalDouble(statement, 1),
                unit: sqliteOptionalText(statement, 2),
                weight: sqliteOptionalDouble(statement, 3),
                name: sqliteText(statement, 4),
                calories: sqliteDouble(statement, 5),
                protein: sqliteDouble(statement, 6),
                carbs: sqliteDouble(statement, 7),
                fat: sqliteDouble(statement, 8),
                notes: sqliteOptionalText(statement, 9),
                sourceId: sqliteOptionalText(statement, 10),
                mealType: CalorieMealType(databaseValue: sqliteOptionalText(statement, 11))
            )
        }.first

        guard let base else { return nil }

        let nutrients = try query(
            "SELECT nutrient_key, amount FROM food_log_item_nutrients WHERE log_item_id = ?",
            [id]
        ) { statement in
            FoodLogNutrientCopy(
                key: sqliteText(statement, 0),
                amount: sqliteDouble(statement, 1)
            )
        }

        let attachments = try query(
            """
            SELECT file_relative_path, mime_type, byte_size
            FROM photo_attachments
            WHERE entity_type = 'log_item' AND entity_id = ? AND deleted_at_ms IS NULL
            """,
            [id]
        ) { statement in
            PhotoAttachmentCopy(
                relativePath: sqliteText(statement, 0),
                mimeType: sqliteOptionalText(statement, 1) ?? "image/jpeg",
                byteSize: sqliteInt64(statement, 2)
            )
        }

        return CalorieLogItemCopy(
            libraryItemId: base.libraryItemId,
            servingCount: base.servingCount,
            unit: base.unit,
            weight: base.weight,
            name: base.name,
            calories: base.calories,
            protein: base.protein,
            carbs: base.carbs,
            fat: base.fat,
            notes: base.notes,
            sourceId: base.sourceId,
            mealType: base.mealType,
            nutrients: nutrients,
            attachments: attachments
        )
    }

    private func insertLogItemCopy(_ copy: CalorieLogItemCopy, dateKey: String, mealType: CalorieMealType) throws {
        let entryId = try upsertMealEntry(mealType, dateKey: dateKey)
        let newItemId = UUID().uuidString
        try execute(
            """
            INSERT INTO food_log_items (
                id, entry_id, library_item_id, log_date, logged_at_ms, name, serving_count, unit, weight_g,
                calories_kcal, protein_g, carbs_g, fat_g, notes, source_id, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                newItemId,
                entryId,
                copy.libraryItemId,
                dateKey,
                nowMs,
                copy.name,
                copy.servingCount,
                copy.unit,
                copy.weight,
                copy.calories,
                copy.protein,
                copy.carbs,
                copy.fat,
                copy.notes,
                copy.sourceId,
                nowMs,
                nowMs
            ]
        )

        for nutrient in copy.nutrients {
            try execute(
                """
                INSERT INTO food_log_item_nutrients (
                    log_item_id, nutrient_key, amount, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
                [newItemId, nutrient.key, nutrient.amount, nowMs, nowMs]
            )
        }

        for attachment in copy.attachments {
            try execute(
                """
                INSERT INTO photo_attachments (
                    id, entity_type, entity_id, file_relative_path, mime_type, byte_size, created_at_ms, updated_at_ms
                ) VALUES (?, 'log_item', ?, ?, ?, ?, ?, ?)
                """,
                [UUID().uuidString, newItemId, attachment.relativePath, attachment.mimeType, attachment.byteSize, nowMs, nowMs]
            )
        }
    }

    private func mealEntryIds(for mealType: CalorieMealType) throws -> [String] {
        try query(
            """
            SELECT id
            FROM food_log_entries
            WHERE log_date = ? AND meal_type = ? AND deleted_at_ms IS NULL
            """,
            [todayKey, mealType.rawValue]
        ) { statement in
            sqliteText(statement, 0)
        }
    }

    private func logItemIds(for mealType: CalorieMealType) throws -> [String] {
        try query(
            """
            SELECT fli.id
            FROM food_log_items fli
            LEFT JOIN food_log_entries fle ON fle.id = fli.entry_id AND fle.deleted_at_ms IS NULL
            WHERE fli.log_date = ? AND fle.meal_type = ? AND fli.deleted_at_ms IS NULL
            ORDER BY fli.logged_at_ms ASC
            """,
            [todayKey, mealType.rawValue]
        ) { statement in
            sqliteText(statement, 0)
        }
    }

    private func insertOptionalNutrient(logItemId: String, key: String, amount: Double?) throws {
        guard let amount, amount > 0 else { return }
        try execute(
            """
            INSERT INTO food_log_item_nutrients (
                log_item_id, nutrient_key, amount, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            """,
            [logItemId, key, amount, nowMs, nowMs]
        )
    }

    private func upsertCanonicalFood(
        name: String,
        brand: String?,
        servingQty: Double?,
        servingUnit: String?,
        servingWeight: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        sourceId: String?,
        markUsed: Bool
    ) throws -> String {
        let displayName = name.trimmed
        let normalizedName = Self.normalizedFoodKey(displayName)
        let normalizedBrand = brand.flatMap { Self.normalizedFoodKey($0).nilIfBlank } ?? ""
        let canonicalName = normalizedBrand.isEmpty ? normalizedName : "\(normalizedBrand) \(normalizedName)"
        if let existing = try scalarString(
            """
            SELECT id FROM canonical_food_items
            WHERE normalized_name = ? AND COALESCE(normalized_brand, '') = ? AND deleted_at_ms IS NULL
            LIMIT 1
            """,
            [normalizedName, normalizedBrand]
        ) {
            try execute(
                """
                UPDATE canonical_food_items
                SET display_name = ?, brand = ?, canonical_name = ?, default_serving_qty = ?,
                    default_serving_unit = ?, default_serving_weight_g = ?, calories_kcal = ?,
                    protein_g = ?, carbs_g = ?, fat_g = ?, source_id = COALESCE(?, source_id),
                    last_used_at_ms = CASE WHEN ? THEN ? ELSE last_used_at_ms END,
                    use_count = use_count + CASE WHEN ? THEN 1 ELSE 0 END,
                    updated_at_ms = ?
                WHERE id = ?
                """,
                [displayName, brand, canonicalName, servingQty, servingUnit?.trimmed.nilIfBlank ?? "serving", servingWeight, calories, protein, carbs, fat, sourceId, markUsed, nowMs, markUsed, nowMs, existing]
            )
            return existing
        }

        let id = UUID().uuidString
        try execute(
            """
            INSERT INTO canonical_food_items (
                id, canonical_name, normalized_name, normalized_brand, display_name, brand,
                default_serving_qty, default_serving_unit, default_serving_weight_g,
                calories_kcal, protein_g, carbs_g, fat_g, source_id, last_used_at_ms,
                use_count, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [id, canonicalName, normalizedName, normalizedBrand, displayName, brand, servingQty, servingUnit?.trimmed.nilIfBlank ?? "serving", servingWeight, calories, protein, carbs, fat, sourceId, markUsed ? nowMs : nil, markUsed ? 1 : 0, nowMs, nowMs]
        )
        return id
    }

    private func markCanonicalFoodUsed(_ id: String) throws {
        try execute(
            """
            UPDATE canonical_food_items
            SET last_used_at_ms = ?, use_count = use_count + 1, updated_at_ms = ?
            WHERE id = ? AND deleted_at_ms IS NULL
            """,
            [nowMs, nowMs, id]
        )
    }

    private func fetchCanonicalFood(id: String) throws -> CanonicalFoodItem? {
        try fetchCanonicalFoods(whereClause: "id = ?", values: [id], limit: 1, offset: 0).first
    }

    private func fetchCanonicalFoods(queryText: String, limit: Int, offset: Int, recentOnly: Bool) throws -> [CanonicalFoodItem] {
        let trimmed = queryText.trimmed
        if trimmed.isEmpty {
            let whereClause = recentOnly ? "last_used_at_ms IS NOT NULL" : "1 = 1"
            return try fetchCanonicalFoods(whereClause: whereClause, values: [], limit: limit, offset: offset)
        }
        let tokens = trimmed
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { "%\(Self.normalizedFoodKey(String($0)))%" }
        let predicates = tokens.map { _ in "(normalized_name LIKE ? OR normalized_brand LIKE ? OR canonical_name LIKE ?)" }
            .joined(separator: " AND ")
        let values = tokens.flatMap { [$0, $0, $0] }
        return try fetchCanonicalFoods(whereClause: predicates, values: values, limit: limit, offset: offset)
    }

    private func fetchCanonicalFoods(whereClause: String, values: [Any?], limit: Int, offset: Int) throws -> [CanonicalFoodItem] {
        try query(
            """
            SELECT id, canonical_name, display_name, brand, calories_kcal,
                   COALESCE(protein_g, 0), COALESCE(carbs_g, 0), COALESCE(fat_g, 0),
                   default_serving_qty, default_serving_unit, default_serving_weight_g, last_used_at_ms
            FROM canonical_food_items
            WHERE deleted_at_ms IS NULL AND \(whereClause)
            ORDER BY COALESCE(last_used_at_ms, updated_at_ms) DESC, use_count DESC, display_name COLLATE NOCASE
            LIMIT ? OFFSET ?
            """,
            values + [limit, offset]
        ) { statement in
            CanonicalFoodItem(
                id: sqliteText(statement, 0),
                canonicalName: sqliteText(statement, 1),
                displayName: sqliteText(statement, 2),
                brand: sqliteOptionalText(statement, 3),
                calories: sqliteDouble(statement, 4),
                protein: sqliteDouble(statement, 5),
                carbs: sqliteDouble(statement, 6),
                fat: sqliteDouble(statement, 7),
                defaultServingQty: sqliteOptionalDouble(statement, 8),
                defaultServingUnit: sqliteOptionalText(statement, 9),
                defaultServingWeight: sqliteOptionalDouble(statement, 10),
                lastUsedAtMs: sqliteOptionalInt64(statement, 11)
            )
        }
    }

    private static func normalizedFoodKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func insertSourceIfNeeded(title: String, url: String = "") throws -> String? {
        let trimmed = title.trimmed
        let trimmedURL = url.trimmed
        guard !trimmed.isEmpty || !trimmedURL.isEmpty else { return nil }
        if let existing = try scalarString(
            "SELECT id FROM nutrition_sources WHERE COALESCE(title, '') = ? AND COALESCE(url, '') = ? AND deleted_at_ms IS NULL LIMIT 1",
            [trimmed, trimmedURL]
        ) {
            return existing
        }
        let id = UUID().uuidString
        try execute(
            """
            INSERT INTO nutrition_sources (
                id, source_type, title, url, created_at_ms, updated_at_ms
            ) VALUES (?, 'other', ?, ?, ?, ?)
            """,
            [id, trimmed.nilIfBlank, trimmedURL.nilIfBlank, nowMs, nowMs]
        )
        return id
    }

    private func saveAttachment(data: Data, entityType: String, entityId: String) throws {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).jpg"
        try data.write(to: attachmentsDirectory.appendingPathComponent(filename), options: .atomic)
        try execute(
            """
            INSERT INTO photo_attachments (
                id, entity_type, entity_id, file_relative_path, mime_type, byte_size, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [UUID().uuidString, entityType, entityId, filename, "image/jpeg", data.count, nowMs, nowMs]
        )
    }

    private func upsertMealEntry(_ mealType: CalorieMealType, dateKey: String? = nil) throws -> String {
        let entryDateKey = dateKey ?? todayKey
        if let id = try scalarString(
            "SELECT id FROM food_log_entries WHERE log_date = ? AND meal_type = ? AND deleted_at_ms IS NULL LIMIT 1",
            [entryDateKey, mealType.rawValue]
        ) {
            return id
        }

        let id = UUID().uuidString
        try execute(
            """
            INSERT INTO food_log_entries (
                id, log_date, meal_type, title, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [id, entryDateKey, mealType.rawValue, mealType.title, nowMs, nowMs]
        )
        return id
    }

    private func activeGoalProfileId() throws -> String {
        if let id = try scalarString("SELECT id FROM goal_profiles WHERE is_active = 1 AND deleted_at_ms IS NULL LIMIT 1", []) {
            return id
        }
        let id = UUID().uuidString
        try execute(
            "INSERT INTO goal_profiles (id, name, is_active, created_at_ms, updated_at_ms) VALUES (?, 'Default', 1, ?, ?)",
            [id, nowMs, nowMs]
        )
        try upsertGoalTargets(ownerTable: "goal_profile_targets", ownerColumn: "profile_id", ownerId: id, calories: 2100, protein: 140, carbs: 220, fat: 70)
        return id
    }

    private func upsertDailyOverride() throws -> String {
        if let id = try scalarString("SELECT id FROM daily_goal_overrides WHERE goal_date = ? AND deleted_at_ms IS NULL LIMIT 1", [todayKey]) {
            return id
        }
        let id = UUID().uuidString
        try execute(
            "INSERT INTO daily_goal_overrides (id, goal_date, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?)",
            [id, todayKey, nowMs, nowMs]
        )
        return id
    }

    private func upsertGoalTargets(ownerTable: String, ownerColumn: String, ownerId: String, calories: Double, protein: Double, carbs: Double, fat: Double) throws {
        for (key, value) in [
            ("calories_kcal", calories),
            ("protein_g", protein),
            ("carbs_g", carbs),
            ("fat_g", fat)
        ] {
            try execute(
                """
                INSERT INTO \(ownerTable) (\(ownerColumn), nutrient_key, target_amount, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(\(ownerColumn), nutrient_key) DO UPDATE SET
                    target_amount = excluded.target_amount,
                    updated_at_ms = excluded.updated_at_ms
                """,
                [ownerId, key, value, nowMs, nowMs]
            )
        }
    }

    private var todayKey: String {
        Self.dateFormatter.string(from: selectedDate)
    }

    private var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private var databaseURL: URL {
        codexDirectory.appendingPathComponent("db.sqlite")
    }

    private var codexDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
    }

    private var attachmentsDirectory: URL {
        codexDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func openIfNeeded() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw CalorieDatabaseError.sqlite(lastError)
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;", [])
    }

    private func queueHealthKitSyncIfNeeded(for dateKey: String) {
        let now = Date()
        if lastQueuedHealthKitSyncKey == dateKey,
           let lastQueuedHealthKitSyncAt,
           now.timeIntervalSince(lastQueuedHealthKitSyncAt) < 30 {
            return
        }
        lastQueuedHealthKitSyncKey = dateKey
        lastQueuedHealthKitSyncAt = now
        codex_healthkit_sync_nutrition_day_async(dateKey)
    }

    private func migrate() throws {
        try execute(Self.schemaSQL, [])
        try addColumnIfMissing(table: "food_library_items", column: "canonical_food_id", definition: "TEXT REFERENCES canonical_food_items(id) ON DELETE SET NULL")
        try addColumnIfMissing(table: "food_log_items", column: "canonical_food_id", definition: "TEXT REFERENCES canonical_food_items(id) ON DELETE SET NULL")
        try backfillCanonicalFoodLinks()
        try execute(
            """
            INSERT INTO schema_metadata (key, value, updated_at_ms)
            VALUES ('database_path', ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms
            """,
            [databaseURL.path, nowMs]
        )
        try seedCodexWorkspaceFiles()
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let exists = try query("PRAGMA table_info(\(table))", []) { statement in
            sqliteText(statement, 1)
        }.contains(column)
        guard !exists else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)", [])
    }

    private func backfillCanonicalFoodLinks() throws {
        let libraryRows = try query(
            """
            SELECT id, name, brand, default_serving_qty, default_serving_unit, default_serving_weight_g,
                   calories_kcal, COALESCE(protein_g, 0), COALESCE(carbs_g, 0), COALESCE(fat_g, 0), source_id
            FROM food_library_items
            WHERE deleted_at_ms IS NULL AND canonical_food_id IS NULL
            """,
            []
        ) { statement in
            (
                id: sqliteText(statement, 0),
                name: sqliteText(statement, 1),
                brand: sqliteOptionalText(statement, 2),
                servingQty: sqliteOptionalDouble(statement, 3),
                servingUnit: sqliteOptionalText(statement, 4),
                servingWeight: sqliteOptionalDouble(statement, 5),
                calories: sqliteDouble(statement, 6),
                protein: sqliteDouble(statement, 7),
                carbs: sqliteDouble(statement, 8),
                fat: sqliteDouble(statement, 9),
                sourceId: sqliteOptionalText(statement, 10)
            )
        }
        for row in libraryRows {
            let canonicalFoodId = try upsertCanonicalFood(
                name: row.name,
                brand: row.brand,
                servingQty: row.servingQty,
                servingUnit: row.servingUnit ?? "serving",
                servingWeight: row.servingWeight,
                calories: row.calories,
                protein: row.protein,
                carbs: row.carbs,
                fat: row.fat,
                sourceId: row.sourceId,
                markUsed: false
            )
            try execute(
                "UPDATE food_library_items SET canonical_food_id = ?, updated_at_ms = ? WHERE id = ?",
                [canonicalFoodId, nowMs, row.id]
            )
        }

        let logRows = try query(
            """
            SELECT id, library_item_id, name, serving_count, unit, weight_g,
                   calories_kcal, COALESCE(protein_g, 0), COALESCE(carbs_g, 0), COALESCE(fat_g, 0), source_id
            FROM food_log_items
            WHERE deleted_at_ms IS NULL AND canonical_food_id IS NULL
            ORDER BY logged_at_ms ASC
            """,
            []
        ) { statement in
            (
                id: sqliteText(statement, 0),
                libraryItemId: sqliteOptionalText(statement, 1),
                name: sqliteText(statement, 2),
                servingCount: sqliteOptionalDouble(statement, 3),
                unit: sqliteOptionalText(statement, 4),
                weight: sqliteOptionalDouble(statement, 5),
                calories: sqliteDouble(statement, 6),
                protein: sqliteDouble(statement, 7),
                carbs: sqliteDouble(statement, 8),
                fat: sqliteDouble(statement, 9),
                sourceId: sqliteOptionalText(statement, 10)
            )
        }
        for row in logRows {
            let libraryCanonical: String?
            if let libraryItemId = row.libraryItemId {
                libraryCanonical = try scalarString("SELECT canonical_food_id FROM food_library_items WHERE id = ? AND deleted_at_ms IS NULL LIMIT 1", [libraryItemId])
            } else {
                libraryCanonical = nil
            }
            let canonicalFoodId = try libraryCanonical ?? upsertCanonicalFood(
                name: row.name,
                brand: nil,
                servingQty: row.servingCount,
                servingUnit: row.unit ?? "serving",
                servingWeight: row.weight,
                calories: row.calories,
                protein: row.protein,
                carbs: row.carbs,
                fat: row.fat,
                sourceId: row.sourceId,
                markUsed: true
            )
            try execute(
                "UPDATE food_log_items SET canonical_food_id = ?, updated_at_ms = ? WHERE id = ?",
                [canonicalFoodId, nowMs, row.id]
            )
        }
    }

    private func seedCodexWorkspaceFiles() throws {
        let agentsURL = codexDirectory.appendingPathComponent("AGENTS.md")
        try Self.agentsMarkdown.write(to: agentsURL, atomically: true, encoding: .utf8)
        let healthKitURL = codexDirectory.appendingPathComponent("HEALTHKIT.md")
        try Self.healthKitMarkdown.write(to: healthKitURL, atomically: true, encoding: .utf8)
    }

    private var lastError: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }

    private func execute(_ sql: String, _ values: [Any?] = []) throws {
        guard let db else { throw CalorieDatabaseError.notOpen }
        if values.isEmpty, sql.contains(";") {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                throw CalorieDatabaseError.sqlite(lastError)
            }
            return
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CalorieDatabaseError.sqlite(lastError)
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CalorieDatabaseError.sqlite(lastError)
        }
    }

    private func query<T>(_ sql: String, _ values: [Any?], map: (OpaquePointer?) throws -> T) throws -> [T] {
        guard let db else { throw CalorieDatabaseError.notOpen }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CalorieDatabaseError.sqlite(lastError)
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try map(statement))
        }
        return rows
    }

    private func scalarString(_ sql: String, _ values: [Any?]) throws -> String? {
        try query(sql, values) { statement in
            sqliteOptionalText(statement, 0)
        }.first ?? nil
    }

    private func bind(_ values: [Any?], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case nil:
                sqlite3_bind_null(statement, position)
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            case let value as Int:
                sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case let value as Bool:
                sqlite3_bind_int(statement, position, value ? 1 : 0)
            default:
                sqlite3_bind_text(statement, position, "\(value!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    private static let schemaSQL = """
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at_ms INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS schema_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at_ms INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS nutrient_definitions (
        key TEXT PRIMARY KEY, label TEXT NOT NULL, unit TEXT NOT NULL, category TEXT NOT NULL,
        is_core INTEGER NOT NULL DEFAULT 0, display_order INTEGER NOT NULL DEFAULT 0,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL
    );
    INSERT OR IGNORE INTO nutrient_definitions (key, label, unit, category, is_core, display_order, created_at_ms, updated_at_ms) VALUES
        ('calories_kcal','Calories','kcal','energy',1,10,0,0),
        ('protein_g','Protein','g','macro',1,20,0,0),
        ('carbs_g','Carbohydrates','g','macro',1,30,0,0),
        ('fat_g','Fat','g','macro',1,40,0,0),
        ('fiber_g','Fiber','g','carb_detail',0,110,0,0),
        ('sugars_g','Sugars','g','carb_detail',0,120,0,0),
        ('added_sugars_g','Added sugars','g','carb_detail',0,130,0,0),
        ('saturated_fat_g','Saturated fat','g','fat_detail',0,210,0,0),
        ('trans_fat_g','Trans fat','g','fat_detail',0,220,0,0),
        ('cholesterol_mg','Cholesterol','mg','fat_detail',0,230,0,0),
        ('sodium_mg','Sodium','mg','mineral',0,310,0,0),
        ('potassium_mg','Potassium','mg','mineral',0,320,0,0),
        ('calcium_mg','Calcium','mg','mineral',0,330,0,0),
        ('iron_mg','Iron','mg','mineral',0,340,0,0),
        ('vitamin_d_mcg','Vitamin D','mcg','vitamin',0,410,0,0),
        ('caffeine_mg','Caffeine','mg','other',0,510,0,0);
    CREATE TABLE IF NOT EXISTS nutrition_sources (
        id TEXT PRIMARY KEY, source_type TEXT NOT NULL, title TEXT, url TEXT, citation TEXT, notes TEXT,
        captured_at_ms INTEGER, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS canonical_food_items (
        id TEXT PRIMARY KEY, canonical_name TEXT NOT NULL, normalized_name TEXT NOT NULL,
        normalized_brand TEXT, display_name TEXT NOT NULL, brand TEXT,
        barcode TEXT, default_serving_qty REAL, default_serving_unit TEXT,
        default_serving_weight_g REAL, calories_kcal REAL NOT NULL,
        protein_g REAL, carbs_g REAL, fat_g REAL,
        source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
        confidence REAL NOT NULL DEFAULT 1.0, use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at_ms INTEGER, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_canonical_food_items_identity
        ON canonical_food_items(normalized_name, normalized_brand) WHERE deleted_at_ms IS NULL;
    CREATE INDEX IF NOT EXISTS idx_canonical_food_items_recent
        ON canonical_food_items(last_used_at_ms DESC, use_count DESC) WHERE deleted_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS user_preference_memory (
        id TEXT PRIMARY KEY, preference_key TEXT NOT NULL, preference_value TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'general', confidence REAL NOT NULL DEFAULT 0.5,
        evidence_count INTEGER NOT NULL DEFAULT 1, first_seen_at_ms INTEGER NOT NULL,
        last_seen_at_ms INTEGER NOT NULL, notes TEXT, created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_preference_memory_active_key
        ON user_preference_memory(preference_key, preference_value) WHERE deleted_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS food_library_items (
        id TEXT PRIMARY KEY CHECK (length(trim(id)) > 0), canonical_food_id TEXT REFERENCES canonical_food_items(id) ON DELETE SET NULL,
        kind TEXT NOT NULL, name TEXT NOT NULL, brand TEXT, barcode TEXT,
        default_serving_qty REAL, default_serving_unit TEXT, default_serving_weight_g REAL,
        calories_kcal REAL NOT NULL, protein_g REAL, carbs_g REAL, fat_g REAL, notes TEXT,
        source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
        is_archived INTEGER NOT NULL DEFAULT 0, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_food_library_items_kind_name ON food_library_items(kind, name COLLATE NOCASE);
    CREATE TABLE IF NOT EXISTS food_aliases (
        id TEXT PRIMARY KEY, library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
        alias TEXT NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_food_aliases_alias ON food_aliases(alias COLLATE NOCASE);
    CREATE TABLE IF NOT EXISTS serving_units (
        id TEXT PRIMARY KEY, library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
        label TEXT NOT NULL, quantity REAL NOT NULL DEFAULT 1, unit TEXT NOT NULL,
        gram_weight REAL, is_default INTEGER NOT NULL DEFAULT 0,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS food_library_item_nutrients (
        library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
        nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key),
        amount REAL NOT NULL, source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
        notes TEXT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER, PRIMARY KEY (library_item_id, nutrient_key)
    );
    CREATE TABLE IF NOT EXISTS recipe_components (
        id TEXT PRIMARY KEY CHECK (length(trim(id)) > 0),
        recipe_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE CHECK (length(trim(recipe_id)) > 0),
        component_item_id TEXT REFERENCES food_library_items(id) ON DELETE SET NULL CHECK (component_item_id IS NULL OR length(trim(component_item_id)) > 0), component_name TEXT NOT NULL,
        quantity REAL NOT NULL, unit TEXT NOT NULL, weight_g REAL, calories_kcal REAL,
        protein_g REAL, carbs_g REAL, fat_g REAL, sort_order INTEGER NOT NULL DEFAULT 0,
        notes TEXT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS meal_templates (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, notes TEXT,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS meal_template_items (
        id TEXT PRIMARY KEY, template_id TEXT NOT NULL REFERENCES meal_templates(id) ON DELETE CASCADE,
        library_item_id TEXT REFERENCES food_library_items(id) ON DELETE SET NULL,
        quantity REAL NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS food_log_entries (
        id TEXT PRIMARY KEY, log_date TEXT NOT NULL, meal_type TEXT, title TEXT, notes TEXT,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS food_log_items (
        id TEXT PRIMARY KEY, entry_id TEXT REFERENCES food_log_entries(id) ON DELETE CASCADE,
        parent_log_item_id TEXT REFERENCES food_log_items(id) ON DELETE CASCADE,
        canonical_food_id TEXT REFERENCES canonical_food_items(id) ON DELETE SET NULL,
        library_item_id TEXT REFERENCES food_library_items(id) ON DELETE SET NULL CHECK (library_item_id IS NULL OR length(trim(library_item_id)) > 0),
        recipe_component_id TEXT REFERENCES recipe_components(id) ON DELETE SET NULL,
        log_date TEXT NOT NULL, logged_at_ms INTEGER NOT NULL, name TEXT NOT NULL,
        quantity REAL, unit TEXT, weight_g REAL, serving_count REAL,
        calories_kcal REAL NOT NULL, protein_g REAL, carbs_g REAL, fat_g REAL,
        notes TEXT, source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_food_log_items_date_time ON food_log_items(log_date, logged_at_ms);
    CREATE TABLE IF NOT EXISTS food_log_item_nutrients (
        log_item_id TEXT NOT NULL REFERENCES food_log_items(id) ON DELETE CASCADE,
        nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key),
        amount REAL NOT NULL, source_id TEXT REFERENCES nutrition_sources(id) ON DELETE SET NULL,
        notes TEXT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER, PRIMARY KEY (log_item_id, nutrient_key)
    );
    CREATE TABLE IF NOT EXISTS favorite_foods (
        id TEXT PRIMARY KEY, library_item_id TEXT NOT NULL REFERENCES food_library_items(id) ON DELETE CASCADE,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_favorite_foods_active ON favorite_foods(library_item_id) WHERE deleted_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS daily_notes (
        id TEXT PRIMARY KEY, note_date TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
        mood TEXT, hunger TEXT, training TEXT, created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_notes_active_date ON daily_notes(note_date) WHERE deleted_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS photo_attachments (
        id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
        file_relative_path TEXT NOT NULL, mime_type TEXT, byte_size INTEGER,
        caption TEXT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_photo_attachments_entity ON photo_attachments(entity_type, entity_id) WHERE deleted_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS goal_profiles (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, starts_on TEXT, ends_on TEXT,
        is_active INTEGER NOT NULL DEFAULT 1, notes TEXT, created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE TABLE IF NOT EXISTS goal_profile_targets (
        profile_id TEXT NOT NULL REFERENCES goal_profiles(id) ON DELETE CASCADE,
        nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key),
        target_amount REAL, min_amount REAL, max_amount REAL, notes TEXT,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER, PRIMARY KEY (profile_id, nutrient_key)
    );
    CREATE TABLE IF NOT EXISTS daily_goal_overrides (
        id TEXT PRIMARY KEY, goal_date TEXT NOT NULL, notes TEXT,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_goal_overrides_active_date ON daily_goal_overrides(goal_date) WHERE deleted_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS daily_goal_override_targets (
        override_id TEXT NOT NULL REFERENCES daily_goal_overrides(id) ON DELETE CASCADE,
        nutrient_key TEXT NOT NULL REFERENCES nutrient_definitions(key),
        target_amount REAL, min_amount REAL, max_amount REAL, notes TEXT,
        created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
        deleted_at_ms INTEGER, PRIMARY KEY (override_id, nutrient_key)
    );
    CREATE VIEW IF NOT EXISTS daily_core_nutrition_totals AS
    SELECT log_date, SUM(calories_kcal) AS calories_kcal,
           SUM(COALESCE(protein_g, 0)) AS protein_g,
           SUM(COALESCE(carbs_g, 0)) AS carbs_g,
           SUM(COALESCE(fat_g, 0)) AS fat_g
    FROM food_log_items WHERE deleted_at_ms IS NULL GROUP BY log_date;
    CREATE VIEW IF NOT EXISTS daily_optional_nutrient_totals AS
    SELECT fli.log_date, flin.nutrient_key, SUM(flin.amount) AS amount
    FROM food_log_item_nutrients flin
    JOIN food_log_items fli ON fli.id = flin.log_item_id
    WHERE fli.deleted_at_ms IS NULL AND flin.deleted_at_ms IS NULL
    GROUP BY fli.log_date, flin.nutrient_key;
    """

    private static let agentsMarkdown = """
    # Macrodex Agent Workspace

    This is the on-device agent workspace for Macrodex. The app is primarily a viewer for the calorie tracker; the agent should do logging, querying, corrections, and library management by writing SQLite directly.

    HealthKit access is available through the `healthkit` dynamic tool and the native `healthkit` command. Prefer the dynamic tool when available. Read `/home/codex/HEALTHKIT.md` before querying or writing Apple Health data.
    For food macro lookups, use the `food_search` dynamic tool first. It checks local food memory (`canonical_food_items`, linked library foods, and aliases). Use web search only when local memory is missing, ambiguous, or the user explicitly asks for latest/current/online data.

    ## Database Access

    - Main database: `/home/codex/db.sqlite`
    - Local photo directory: `/home/codex/attachments/`
    - Use the native SQL bridge command, not an external sqlite binary:

    ```sh
    sql "/* macrodex: Checking recent totals */ SELECT * FROM daily_core_nutrition_totals ORDER BY log_date DESC LIMIT 7;"
    ```

    - `sql` runs SQL against `/home/codex/db.sqlite`.
    - `SELECT`, `WITH`, and `PRAGMA` return JSON rows.
    - Mutating statements return `{"ok":true,"changes":N}`.
    - Every `sql` command must start the SQL text with a short user-facing summary comment. This is mandatory for reads and writes.
    - Use `/* macrodex: Checking meals */` for one-line SQL and `-- macrodex: Updating breakfast` as the first line for multi-line SQL.
    - Do not run unlabeled SQL; Macrodex uses the label as the visible tool-call summary.
    - For multi-step data repair or bulk updates, prefer a short `jsc` script that calls `sql.query(...)` / `sql.exec(...)` instead of trying to compose fragile shell pipelines.
    - For `jsc` scripts, every `sql.query(...)`, `db.query(...)`, `sql.exec(...)`, and `db.exec(...)` SQL string must start with the same summary comment.
    - Wrap multi-statement writes in `BEGIN IMMEDIATE; ... COMMIT;`.
    - Use Unix epoch milliseconds for `*_at_ms`.
    - Use local dates as `YYYY-MM-DD`.
    - Use UUID strings for IDs.
    - Never hard-delete user data. Set `deleted_at_ms` and `updated_at_ms` instead.
    - Filter active rows with `deleted_at_ms IS NULL`.
    - Do not guess column names. If you are unsure, run `PRAGMA table_info(table_name)` before querying.
    - `canonical_food_items` is the local food memory table. Search `canonical_name`, `display_name`, and `brand` before web lookups.
    - `food_library_items` has `name`, `brand`, `canonical_food_id`, `calories_kcal`, `protein_g`, `carbs_g`, and `fat_g`; it does not have `canonical_name`, `brand_name`, or `calories_per_100g`.
    - `food_log_items` has `canonical_food_id` and `library_item_id`; prefer linking logs to canonical foods so recents and future lookups stay accurate.
    - When web search identifies a food source, save both source title and source URL in `nutrition_sources` and link the food/library row through `source_id`.
    - `user_preference_memory` stores durable user preferences. Add entries only for stable preferences the user states or repeatedly demonstrates.
    - Search reusable foods with `food_library_items.name`, `food_library_items.brand`, and `food_aliases.alias`.

    ## Shell Notes

    The on-device agent harness runs inside a lightweight iOS shell environment rooted at `/home/codex`.

    Available convenience commands for common agent flows:

    - `uuidgen` prints lowercase UUIDs
    - `date +%s%3N` prints epoch milliseconds
    - `date +%Y-%m-%d` prints the local date
    - `jsc script.js` or `jsc -e "JS"` runs JavaScriptCore with Macrodex helpers
    - `true`, `false`, `tr`, `sh`, `cat`, `ls`, `mkdir`, `rm`, `mv`, `find`, `grep`, `sed`, `sort`, `uniq`, `wc`, `head`, `tail`, `touch` are available

    JavaScriptCore is the dynamic scripting runtime for this workspace:

    ```sh
    cat > /home/codex/task.js <<'JS'
    const rows = sql.query("/* macrodex: Checking recent totals */ SELECT log_date, calories_kcal FROM daily_core_nutrition_totals ORDER BY log_date DESC LIMIT 7");
    console.log(rows);
    fs.writeText("/home/codex/last-query.json", JSON.stringify(rows, null, 2));
    JS
    jsc /home/codex/task.js
    ```

    Available JavaScript globals:

    - `console.log`, `console.warn`, `console.error`
    - `fs.readText(path)`, `fs.writeText(path, text)`, `fs.appendText(path, text)`
    - `fs.exists(path)`, `fs.mkdir(path)`, `fs.list(path)`, `fs.remove(path)`, `fs.move(from, to)`, `fs.stat(path)`
    - `sql.query(statement)` / `db.query(statement)` return JSON-like rows for `SELECT`, `WITH`, and `PRAGMA`
    - `sql.exec(statement)` / `db.exec(statement)` execute writes and return `{ok:true, changes:N}`
    - `cwd`, `argv`, `scriptArgs`, and `scriptPath`

    There is no general `python3` runtime in this environment.

    - Do not use `python3`, `pip`, virtualenvs, or Python-based helper scripts.
    - Use `jsc` for procedural scripting, JSON manipulation, and SQLite-powered migrations.
    - This is a limited iOS shell, not a full Unix userland.

    Prefer pure shell when possible:

    ```sh
    item_id=$(uuidgen)
    now_ms=$(date +%s%3N)
    log_date=$(date +%Y-%m-%d)
    ```

    ## Core Concepts

    - `food_log_items` is the primary daily log table. Every logged food must have `calories_kcal`.
    - `food_log_item_nutrients` stores optional nutrients for logged foods, such as fiber, sugars, sodium, potassium, vitamins, and minerals.
    - `food_library_items` stores reusable foods and recipes.
    - `recipe_components` stores recipe ingredient breakdowns.
    - `food_aliases` stores alternate names for library search.
    - `serving_units` stores serving options for library items.
    - `meal_templates` and `meal_template_items` store repeated meals composed from library items.
    - `favorite_foods` marks library items as favorites.
    - `daily_notes` stores daily freeform context.
    - `goal_profiles` and `goal_profile_targets` store default goals.
    - `daily_goal_overrides` and `daily_goal_override_targets` store one-day goal overrides.
    - `photo_attachments` references files stored locally under `/home/codex/attachments/`.
    - `schema_metadata` stores runtime metadata such as `database_path`.

    ## Nutrient Keys

    Core nutrients:

    - `calories_kcal` in `kcal`
    - `protein_g` in `g`
    - `carbs_g` in `g`
    - `fat_g` in `g`

    Optional nutrients currently seeded:

    - `fiber_g`, `sugars_g`, `added_sugars_g`
    - `saturated_fat_g`, `trans_fat_g`, `cholesterol_mg`
    - `sodium_mg`, `potassium_mg`, `calcium_mg`, `iron_mg`
    - `vitamin_d_mcg`, `caffeine_mg`

    Add more optional nutrients by inserting into `nutrient_definitions`, then referencing the new `key` from nutrient tables.

    ## Schema Summary

    ```sql
    schema_migrations(version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at_ms INTEGER NOT NULL);
    schema_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at_ms INTEGER NOT NULL);

    nutrient_definitions(
      key TEXT PRIMARY KEY,
      label TEXT NOT NULL,
      unit TEXT NOT NULL,
      category TEXT NOT NULL,
      is_core INTEGER NOT NULL DEFAULT 0,
      display_order INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    );

    nutrition_sources(
      id TEXT PRIMARY KEY,
      source_type TEXT NOT NULL,
      title TEXT,
      url TEXT,
      citation TEXT,
      notes TEXT,
      captured_at_ms INTEGER,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    food_library_items(
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      brand TEXT,
      barcode TEXT,
      default_serving_qty REAL,
      default_serving_unit TEXT,
      default_serving_weight_g REAL,
      calories_kcal REAL NOT NULL,
      protein_g REAL,
      carbs_g REAL,
      fat_g REAL,
      notes TEXT,
      source_id TEXT,
      is_archived INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    food_aliases(
      id TEXT PRIMARY KEY,
      library_item_id TEXT NOT NULL,
      alias TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    serving_units(
      id TEXT PRIMARY KEY,
      library_item_id TEXT NOT NULL,
      label TEXT NOT NULL,
      quantity REAL NOT NULL DEFAULT 1,
      unit TEXT NOT NULL,
      gram_weight REAL,
      is_default INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    food_library_item_nutrients(
      library_item_id TEXT NOT NULL,
      nutrient_key TEXT NOT NULL,
      amount REAL NOT NULL,
      source_id TEXT,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER,
      PRIMARY KEY (library_item_id, nutrient_key)
    );

    recipe_components(
      id TEXT PRIMARY KEY,
      recipe_id TEXT NOT NULL,
      component_item_id TEXT,
      component_name TEXT NOT NULL,
      quantity REAL NOT NULL,
      unit TEXT NOT NULL,
      weight_g REAL,
      calories_kcal REAL,
      protein_g REAL,
      carbs_g REAL,
      fat_g REAL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    meal_templates(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    meal_template_items(
      id TEXT PRIMARY KEY,
      template_id TEXT NOT NULL,
      library_item_id TEXT,
      quantity REAL NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    food_log_entries(
      id TEXT PRIMARY KEY,
      log_date TEXT NOT NULL,
      meal_type TEXT,
      title TEXT,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    food_log_items(
      id TEXT PRIMARY KEY,
      entry_id TEXT,
      parent_log_item_id TEXT,
      library_item_id TEXT,
      recipe_component_id TEXT,
      log_date TEXT NOT NULL,
      logged_at_ms INTEGER NOT NULL,
      name TEXT NOT NULL,
      quantity REAL,
      unit TEXT,
      weight_g REAL,
      serving_count REAL,
      calories_kcal REAL NOT NULL,
      protein_g REAL,
      carbs_g REAL,
      fat_g REAL,
      notes TEXT,
      source_id TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    food_log_item_nutrients(
      log_item_id TEXT NOT NULL,
      nutrient_key TEXT NOT NULL,
      amount REAL NOT NULL,
      source_id TEXT,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER,
      PRIMARY KEY (log_item_id, nutrient_key)
    );

    favorite_foods(
      id TEXT PRIMARY KEY,
      library_item_id TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    daily_notes(
      id TEXT PRIMARY KEY,
      note_date TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT '',
      mood TEXT,
      hunger TEXT,
      training TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    photo_attachments(
      id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      file_relative_path TEXT NOT NULL,
      mime_type TEXT,
      byte_size INTEGER,
      caption TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    goal_profiles(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      starts_on TEXT,
      ends_on TEXT,
      is_active INTEGER NOT NULL DEFAULT 1,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    goal_profile_targets(
      profile_id TEXT NOT NULL,
      nutrient_key TEXT NOT NULL,
      target_amount REAL,
      min_amount REAL,
      max_amount REAL,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER,
      PRIMARY KEY (profile_id, nutrient_key)
    );

    daily_goal_overrides(
      id TEXT PRIMARY KEY,
      goal_date TEXT NOT NULL,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER
    );

    daily_goal_override_targets(
      override_id TEXT NOT NULL,
      nutrient_key TEXT NOT NULL,
      target_amount REAL,
      min_amount REAL,
      max_amount REAL,
      notes TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      deleted_at_ms INTEGER,
      PRIMARY KEY (override_id, nutrient_key)
    );
    ```

    ## Views

    ```sql
    daily_core_nutrition_totals(
      log_date,
      calories_kcal,
      protein_g,
      carbs_g,
      fat_g
    );

    daily_optional_nutrient_totals(
      log_date,
      nutrient_key,
      amount
    );
    ```

    ## Common Queries

    Today's totals:

    ```sh
    sql "/* macrodex: Checking today totals */ SELECT * FROM daily_core_nutrition_totals WHERE log_date = date('now', 'localtime');"
    ```

    Today's logged foods:

    ```sh
    sql "/* macrodex: Checking food log */ SELECT id, logged_at_ms, name, calories_kcal, protein_g, carbs_g, fat_g, notes FROM food_log_items WHERE log_date = date('now', 'localtime') AND deleted_at_ms IS NULL ORDER BY logged_at_ms DESC;"
    ```

    Library search:

    ```sh
    sql "/* macrodex: Searching library */ SELECT fli.* FROM food_library_items fli LEFT JOIN food_aliases fa ON fa.library_item_id = fli.id AND fa.deleted_at_ms IS NULL WHERE fli.deleted_at_ms IS NULL AND (fli.name LIKE '%rice%' OR fa.alias LIKE '%rice%') ORDER BY fli.name COLLATE NOCASE;"
    ```

    Active goals for today:

    ```sh
    sql "/* macrodex: Checking goals */ SELECT nutrient_key, target_amount FROM goal_profile_targets WHERE profile_id = (SELECT id FROM goal_profiles WHERE is_active = 1 AND deleted_at_ms IS NULL LIMIT 1) AND deleted_at_ms IS NULL;"
    ```

    ## Logging Food

    Minimal log item:

    ```sh
    sql "/* macrodex: Logging food */
    BEGIN IMMEDIATE;
    INSERT INTO food_log_items (id, log_date, logged_at_ms, name, calories_kcal, protein_g, carbs_g, fat_g, notes, created_at_ms, updated_at_ms)
    VALUES ('UUID-HERE', '2026-04-23', 1776916800000, 'Greek yogurt', 150, 17, 9, 4, 'plain', 1776916800000, 1776916800000);
    COMMIT;"
    ```

    Log optional nutrients for that item:

    ```sh
    sql "/* macrodex: Adding nutrients */ INSERT INTO food_log_item_nutrients (log_item_id, nutrient_key, amount, created_at_ms, updated_at_ms) VALUES ('LOG-ITEM-UUID', 'sodium_mg', 65, 1776916800000, 1776916800000);"
    ```

    Soft-delete a log item:

    ```sh
    sql "/* macrodex: Deleting log */ UPDATE food_log_items SET deleted_at_ms = 1776916800000, updated_at_ms = 1776916800000 WHERE id = 'LOG-ITEM-UUID';"
    ```

    ## Saving Library Items

    Save reusable food:

    ```sh
    sql "/* macrodex: Saving library food */
    BEGIN IMMEDIATE;
    INSERT INTO food_library_items (id, kind, name, default_serving_qty, default_serving_unit, calories_kcal, protein_g, carbs_g, fat_g, created_at_ms, updated_at_ms)
    VALUES ('FOOD-UUID', 'food', 'Greek yogurt', 1, 'serving', 150, 17, 9, 4, 1776916800000, 1776916800000);
    INSERT INTO serving_units (id, library_item_id, label, quantity, unit, is_default, created_at_ms, updated_at_ms)
    VALUES ('SERVING-UUID', 'FOOD-UUID', 'serving', 1, 'serving', 1, 1776916800000, 1776916800000);
    COMMIT;"
    ```

    Add aliases:

    ```sh
    sql "/* macrodex: Adding aliases */ INSERT INTO food_aliases (id, library_item_id, alias, created_at_ms, updated_at_ms) VALUES ('ALIAS-UUID', 'FOOD-UUID', 'yogurt', 1776916800000, 1776916800000);"
    ```

    Favorite a food:

    ```sh
    sql "/* macrodex: Saving favorite */ INSERT INTO favorite_foods (id, library_item_id, created_at_ms, updated_at_ms) VALUES ('FAV-UUID', 'FOOD-UUID', 1776916800000, 1776916800000);"
    ```

    ## Meal Templates

    Create a template:

    ```sh
    sql "/* macrodex: Saving meal template */
    BEGIN IMMEDIATE;
    INSERT INTO meal_templates (id, name, notes, created_at_ms, updated_at_ms) VALUES ('TEMPLATE-UUID', 'Usual breakfast', NULL, 1776916800000, 1776916800000);
    INSERT INTO meal_template_items (id, template_id, library_item_id, quantity, sort_order, created_at_ms, updated_at_ms) VALUES ('ITEM-UUID', 'TEMPLATE-UUID', 'FOOD-UUID', 1, 0, 1776916800000, 1776916800000);
    COMMIT;"
    ```

    Log a template by copying its active library items into `food_log_items` for the target date.

    ## Daily Notes

    ```sh
    sql "/* macrodex: Saving daily note */ INSERT INTO daily_notes (id, note_date, note, mood, hunger, training, created_at_ms, updated_at_ms) VALUES ('NOTE-UUID', '2026-04-23', 'Felt good today.', 'good', 'normal', 'lifted', 1776916800000, 1776916800000);"
    ```

    If an active note for the date exists, update it instead of inserting a duplicate.

    ## Goals

    Default goals live in `goal_profiles` and `goal_profile_targets`.
    Day-specific overrides live in `daily_goal_overrides` and `daily_goal_override_targets`.
    Prefer one active default profile. For today's override, create or reuse the active `daily_goal_overrides` row for that date, then upsert target rows.

    ## Photos

    Store photo files under `/home/codex/attachments/`, then insert a row into `photo_attachments`.
    `file_relative_path` should be the filename/path relative to `/home/codex/attachments/`, not relative to `/home/codex`.

    Valid `entity_type` values:

    - `log_item`
    - `library_item`
    - `recipe_component`
    - `daily_note`

    Example:

    ```sh
    sql "/* macrodex: Saving photo */ INSERT INTO photo_attachments (id, entity_type, entity_id, file_relative_path, mime_type, byte_size, caption, created_at_ms, updated_at_ms) VALUES ('PHOTO-UUID', 'log_item', 'LOG-ITEM-UUID', 'photo.jpg', 'image/jpeg', 12345, NULL, 1776916800000, 1776916800000);"
    ```

    ## Operational Rules

    - Prefer direct SQL writes over asking the user to use app forms.
    - Keep app-visible lists clean by filtering `deleted_at_ms IS NULL`.
    - Always write `created_at_ms` and `updated_at_ms`.
    - When modifying a row, update `updated_at_ms`.
    - Use `nutrition_sources` when food info comes from a label, website, restaurant, database, user estimate, or AI estimate.
    - Use transactions for multi-table changes.
    - If a write fails, query the relevant table schema with `PRAGMA table_info(table_name);`.
    """

    private static let healthKitMarkdown = """
    # HealthKit Tool

    Macrodex exposes Apple Health data to the on-device agent shell through the native `healthkit` command. It runs inside the app process, so it uses Macrodex's HealthKit permissions and prints JSON.

    ## Permission Model

    - The app asks for the default HealthKit read/write set once on launch.
    - The user can request access again from Macrodex Settings > Health > Request HealthKit Access.
    - From the shell, `healthkit request` opens the same system authorization prompt.
    - iOS does not disclose read authorization status. If a query returns no rows, the data may be absent or read access may be denied.
    - Write access can be checked with `healthkit status`.

    ## Command Summary

    ```sh
    healthkit status
    healthkit request
    healthkit types
    healthkit characteristics
    healthkit query --type quantity --identifier stepCount --start today --end now
    healthkit stats --identifier stepCount --start 2026-04-01 --end now --bucket day --stat sum
    healthkit sync-nutrition --date today
    healthkit write-quantity --identifier dietaryEnergyConsumed --value 450 --unit kcal --start now
    healthkit write-category --identifier sleepAnalysis --value asleepCore --start 2026-04-22T23:00:00 --end 2026-04-23T07:00:00
    healthkit write-workout --activity running --start 2026-04-23T07:00:00 --end 2026-04-23T07:30:00 --energy 250 --distance 5000
    ```

    Use `healthkit help` for the live help text.

    ## Dates

    Date options accept:

    - `now`, `today`, `yesterday`, `tomorrow`
    - `YYYY-MM-DD`
    - ISO-8601 timestamps such as `2026-04-23T07:30:00-04:00`
    - epoch seconds or epoch milliseconds

    `--date YYYY-MM-DD` is shorthand for the local day. For queries, omitted dates default to the last 7 days. For writes, `--start` is required and `--end` defaults to `--start`.

    ## Output Files

    Shell redirection is not reliable for app-native commands. Use `--out` when you need a file:

    ```sh
    healthkit stats --identifier stepCount --start today --end now --bucket hour --out /home/codex/steps-hourly.json
    ```

    ## Macrodex Nutrition Sync

    Macrodex automatically attempts a best-effort sync for the selected nutrition day after the calorie dashboard refreshes. The agent can also invoke the same sync manually:

    ```sh
    healthkit sync-nutrition --date today
    healthkit sync-nutrition --days 7
    healthkit sync-nutrition --start 2026-04-01 --end 2026-04-23
    ```

    The command writes one daily aggregate HealthKit sample per supported nutrient with stable sync metadata, so reruns are idempotent. It syncs `calories_kcal`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugars_g`, `saturated_fat_g`, `cholesterol_mg`, `sodium_mg`, `potassium_mg`, `calcium_mg`, `iron_mg`, `vitamin_d_mcg`, and `caffeine_mg`.

    Macrodex does not send `added_sugars_g` or `trans_fat_g` to HealthKit because Apple Health has no matching writable nutrition fields. If HealthKit is unavailable or write access is missing for some nutrients, the command returns JSON with `ok: true`, an `info` message, and `skipped` entries instead of hard failing.

    ## Quantities

    Query samples:

    ```sh
    healthkit query --type quantity --identifier heartRate --unit count/min --start today --limit 20
    ```

    Bucket statistics:

    ```sh
    healthkit stats --identifier activeEnergyBurned --unit kcal --start 2026-04-01 --end now --bucket day --stat sum
    ```

    Write a quantity:

    ```sh
    healthkit write-quantity --identifier bodyMass --value 82.4 --unit kg --start now --note "manual correction from Macrodex"
    ```

    Common identifiers include `stepCount`, `activeEnergyBurned`, `basalEnergyBurned`, `appleExerciseTime`, `appleStandTime`, `bodyMass`, `height`, `heartRate`, `restingHeartRate`, `heartRateVariabilitySDNN`, `oxygenSaturation`, `bloodGlucose`, `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal`, `dietaryWater`, and `dietaryCaffeine`.

    Run `healthkit types` for the supported alias list. Raw `HKQuantityTypeIdentifier...` strings are also accepted when HealthKit supports them.

    ## Categories

    Query sleep:

    ```sh
    healthkit query --type category --identifier sleepAnalysis --start yesterday --end today
    ```

    Write sleep:

    ```sh
    healthkit write-category --identifier sleepAnalysis --value asleepCore --start 2026-04-22T23:30:00 --end 2026-04-23T06:45:00
    ```

    Sleep values: `inBed`, `asleep`, `asleepUnspecified`, `awake`, `asleepCore`, `asleepDeep`, `asleepREM`.

    Other supported category aliases include `mindfulSession` and `appleStandHour`. Raw integer category values are accepted for raw category identifiers.

    ## Workouts

    Query workouts:

    ```sh
    healthkit query --type workout --start 2026-04-01 --end now
    ```

    Write a workout:

    ```sh
    healthkit write-workout --activity cycling --start 2026-04-23T18:00:00 --end 2026-04-23T18:45:00 --energy 420 --distance 16000
    ```

    Common activities include `walking`, `running`, `cycling`, `hiking`, `swimming`, `yoga`, `hiit`, `strength`, `functionalStrength`, `mixedCardio`, `elliptical`, `rowing`, and `other`.

    ## Metadata And Idempotency

    Writes accept optional metadata:

    ```sh
    healthkit write-quantity --identifier dietaryCaffeine --value 95 --unit mg --start now --sync-id caffeine-2026-04-23-morning --sync-version 1 --metadata '{"source":"Macrodex Agent"}'
    ```

    - `--sync-id` and `--sync-version` map to HealthKit sync metadata.
    - `--note` writes `com.dj.Macrodex.note`.
    - `--user-entered false` omits HealthKit's user-entered metadata flag.

    ## Agent Rules

    - Use `healthkit sync-nutrition` directly after direct SQL changes to food logs when you need immediate HealthKit sync. Do not preflight with `healthkit status`; if the sync output says Apple Health is not set up or fields were skipped, leave the user a short note.
    - Use `healthkit status` for explicit status questions and `healthkit request` only when the user asks to connect or enable Apple Health access.
    - Prefer queries before writes so you do not duplicate existing samples.
    - Include explicit `--start`, `--end`, `--unit`, and `--note` on writes.
    - Treat HealthKit writes as user health records. Do not write guessed data unless the user explicitly asks you to.
    - Do not use shell redirects or pipelines with `healthkit`; use `--out`.
    """
}

private enum CalorieDatabaseError: LocalizedError {
    case notOpen
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .notOpen: return "Calorie database is not open."
        case .sqlite(let message): return message
        }
    }
}

private func sqliteText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
}

private func sqliteOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqliteText(statement, index)
}

private func sqliteDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double {
    sqlite3_column_double(statement, index)
}

private func sqliteOptionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqliteDouble(statement, index)
}

private func sqliteInt(_ statement: OpaquePointer?, _ index: Int32) -> Int {
    Int(sqlite3_column_int(statement, index))
}

private func sqliteInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
    Int64(sqlite3_column_int64(statement, index))
}

private func sqliteOptionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqliteInt64(statement, index)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let trimmed = trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    var doubleValue: Double {
        let raw = trimmed
        let commaCount = raw.filter { $0 == "," }.count
        if raw.contains(",") && raw.contains(".") {
            return Double(raw.replacingOccurrences(of: ",", with: "")) ?? 0
        }
        if commaCount > 1 {
            return Double(raw.replacingOccurrences(of: ",", with: "")) ?? 0
        }
        if let commaIndex = raw.firstIndex(of: ","), raw[raw.index(after: commaIndex)...].count == 3 {
            return Double(raw.replacingOccurrences(of: ",", with: "")) ?? 0
        }
        return Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    var optionalDouble: Double? {
        let value = doubleValue
        return trimmed.isEmpty ? nil : value
    }
}

private extension Double {
    var cleanString: String {
        formatted(.number.precision(.fractionLength(0...1)))
    }
}

private extension Calendar {
    func macrodexStartOfWeek(for date: Date) -> Date {
        let startOfDay = startOfDay(for: date)
        let weekday = component(.weekday, from: startOfDay)
        let distance = (weekday - firstWeekday + 7) % 7
        return self.date(byAdding: .day, value: -distance, to: startOfDay) ?? startOfDay
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DashboardScreen()
            .environment(DrawerController())
    }
}
#endif
