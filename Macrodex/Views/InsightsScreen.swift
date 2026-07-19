import Charts
import HealthKit
import Observation
import SwiftUI

enum HealthInsightsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        }
    }
}

struct HealthInsightDay: Identifiable, Equatable {
    let date: Date
    var intake: Double = 0
    var activeEnergy: Double = 0
    var basalEnergy: Double = 0
    var steps: Double = 0

    var id: Date { date }
    var expenditure: Double { activeEnergy + basalEnergy }
    var balance: Double { intake - expenditure }
    var hasData: Bool { intake > 0 || activeEnergy > 0 || basalEnergy > 0 || steps > 0 }
}

@MainActor
@Observable
final class HealthInsightsStore {
    private struct Metric {
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let assign: (inout HealthInsightDay, Double) -> Void
    }

    private let healthStore = HKHealthStore()
    private let calendar = Calendar.current

    var days: [HealthInsightDay] = []
    var isLoading = false
    var statusMessage: String?

    private static let metrics: [Metric] = [
        Metric(identifier: .dietaryEnergyConsumed, unit: .kilocalorie()) { $0.intake = $1 },
        Metric(identifier: .activeEnergyBurned, unit: .kilocalorie()) { $0.activeEnergy = $1 },
        Metric(identifier: .basalEnergyBurned, unit: .kilocalorie()) { $0.basalEnergy = $1 },
        Metric(identifier: .stepCount, unit: .count()) { $0.steps = $1 }
    ]

    func load(range: HealthInsightsRange, localIntake: [Date: Double]) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        #if DEBUG
        if ProcessInfo.processInfo.environment["MACRODEX_DEBUG_INSIGHTS_SAMPLE_DATA"] == "1" {
            days = debugDays(range: range)
            statusMessage = nil
            return
        }
        if ProcessInfo.processInfo.environment["MACRODEX_SKIP_HEALTHKIT_AUTH_PROMPT"] == "1" {
            days = localDays(range: range, localIntake: localIntake)
            statusMessage = "Apple Health authorization skipped for UI automation."
            return
        }
        #endif

        guard HKHealthStore.isHealthDataAvailable() else {
            days = localDays(range: range, localIntake: localIntake)
            statusMessage = "Apple Health is unavailable on this device."
            return
        }

        let readTypes = Set(Self.metrics.compactMap { HKObjectType.quantityType(forIdentifier: $0.identifier) })
        let authorizationError = await requestAuthorization(readTypes: readTypes)
        if let authorizationError {
            days = localDays(range: range, localIntake: localIntake)
            statusMessage = authorizationError
            return
        }

        let endDate = Date()
        let endDay = calendar.startOfDay(for: endDate)
        let startDate = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: endDay) ?? endDay
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDate
        var loaded = daySkeleton(startDate: startDate, count: range.rawValue)
        var queryErrors: [String] = []

        for metric in Self.metrics {
            let result = await dailyValues(
                metric: metric,
                startDate: startDate,
                endDateExclusive: endExclusive
            )
            if let error = result.error {
                queryErrors.append(error)
            }
            for index in loaded.indices {
                let key = calendar.startOfDay(for: loaded[index].date)
                if let value = result.values[key] {
                    metric.assign(&loaded[index], value)
                }
            }
        }

        for index in loaded.indices {
            let key = calendar.startOfDay(for: loaded[index].date)
            loaded[index].intake = max(loaded[index].intake, localIntake[key] ?? 0)
        }
        days = loaded
        statusMessage = queryErrors.first
    }

    private func requestAuthorization(readTypes: Set<HKObjectType>) async -> String? {
        guard !readTypes.isEmpty else { return "Apple Health metrics are unavailable." }
        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(returning: "Apple Health access failed: \(error.localizedDescription)")
                } else if !success {
                    continuation.resume(returning: "Apple Health access was not completed.")
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func dailyValues(
        metric: Metric,
        startDate: Date,
        endDateExclusive: Date
    ) async -> (values: [Date: Double], error: String?) {
        guard let type = HKObjectType.quantityType(forIdentifier: metric.identifier) else {
            return ([:], "Apple Health does not expose \(metric.identifier.rawValue) on this device.")
        }
        let unit = metric.unit

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: startDate,
                end: endDateExclusive,
                options: [.strictStartDate]
            )
            var interval = DateComponents()
            interval.day = 1
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startDate,
                intervalComponents: interval
            )
            query.initialResultsHandler = { [calendar] _, collection, error in
                guard let collection, error == nil else {
                    continuation.resume(returning: ([:], error?.localizedDescription ?? "Apple Health returned no data."))
                    return
                }
                var values: [Date: Double] = [:]
                collection.enumerateStatistics(from: startDate, to: endDateExclusive) { statistics, _ in
                    let date = calendar.startOfDay(for: statistics.startDate)
                    values[date] = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
                }
                continuation.resume(returning: (values, nil))
            }
            healthStore.execute(query)
        }
    }

    private func localDays(range: HealthInsightsRange, localIntake: [Date: Double]) -> [HealthInsightDay] {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: today) ?? today
        return daySkeleton(startDate: start, count: range.rawValue).map { day in
            var day = day
            day.intake = localIntake[calendar.startOfDay(for: day.date)] ?? 0
            return day
        }
    }

    private func daySkeleton(startDate: Date, count: Int) -> [HealthInsightDay] {
        (0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDate).map { date in
                HealthInsightDay(date: date)
            }
        }
    }

    #if DEBUG
    private func debugDays(range: HealthInsightsRange) -> [HealthInsightDay] {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: today) ?? today
        return daySkeleton(startDate: start, count: range.rawValue).enumerated().map { index, day in
            let wave = sin(Double(index) * 0.72)
            let weekend = calendar.isDateInWeekend(day.date)
            return HealthInsightDay(
                date: day.date,
                intake: 1_920 + wave * 210 + (weekend ? 160 : 0),
                activeEnergy: 510 + cos(Double(index) * 0.58) * 145,
                basalEnergy: 1_690 + sin(Double(index) * 0.24) * 38,
                steps: 8_400 + cos(Double(index) * 0.45) * 2_300
            )
        }
    }
    #endif
}

struct InsightsScreen: View {
    @Environment(DrawerController.self) private var drawerController
    @State private var insights = HealthInsightsStore()
    @StateObject private var calorieStore = CalorieTrackerStore.shared
    @State private var range: HealthInsightsRange = .month

    private var populatedDays: [HealthInsightDay] { insights.days.filter(\.hasData) }
    private var averageIntake: Double { average(\.intake) }
    private var averageExpenditure: Double { average(\.expenditure) }
    private var averageSteps: Double { average(\.steps) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if insights.isLoading && insights.days.isEmpty {
                    loadingState
                } else if populatedDays.isEmpty {
                    emptyState
                } else {
                    energySummary
                    energyChart
                    activitySection
                    sourceFooter
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .scrollDisabled(drawerController.progress > 0.001)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerMenuButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(insights.isLoading)
                .accessibilityLabel("Refresh insights")
            }
        }
        .task(id: range) {
            await reload()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Insights")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("Nutrition and activity from Macrodex and Apple Health")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Picker("Range", selection: $range) {
                ForEach(HealthInsightsRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Reading Apple Health...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No insight data yet", systemImage: "chart.xyaxis.line")
        } description: {
            Text(insights.statusMessage ?? "Log food or connect Apple Health to build trends.")
        } actions: {
            Button("Connect Apple Health") {
                codex_healthkit_request_authorization_from_settings()
                Task { await reload() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var energySummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily energy")
                .font(.headline)
            HStack(spacing: 18) {
                insightMetric(title: "Eating", value: averageIntake, unit: "kcal", tint: .blue)
                insightMetric(title: "Burning", value: averageExpenditure, unit: "kcal", tint: .green)
                insightMetric(
                    title: "Balance",
                    value: averageIntake - averageExpenditure,
                    unit: "kcal",
                    tint: averageIntake > averageExpenditure ? .orange : .mint,
                    signed: true
                )
            }
        }
    }

    private var energyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(insights.days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Intake", day.intake)
                )
                .foregroundStyle(.blue.opacity(0.56))
                .cornerRadius(3)

                LineMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Expenditure", day.expenditure)
                )
                .foregroundStyle(.green)
                .lineStyle(.init(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 5)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                    AxisGridLine().foregroundStyle(.clear)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                    AxisValueLabel()
                }
            }
            .frame(height: 230)

            HStack(spacing: 18) {
                chartKey("Food", color: .blue)
                chartKey("Total expenditure", color: .green)
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Text("\(Int(averageSteps).formatted()) steps/day")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Chart(insights.days) { day in
                AreaMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Steps", day.steps)
                )
                .foregroundStyle(.cyan.opacity(0.16))
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Steps", day.steps)
                )
                .foregroundStyle(.cyan)
                .lineStyle(.init(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
        }
    }

    @ViewBuilder
    private var sourceFooter: some View {
        if let message = insights.statusMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Apple Health and Macrodex data", systemImage: "heart.text.square")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func insightMetric(
        title: String,
        value: Double,
        unit: String,
        tint: Color,
        signed: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(signed && value > 0 ? "+" : "")\(Int(value).formatted())")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartKey(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 4)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func average(_ keyPath: KeyPath<HealthInsightDay, Double>) -> Double {
        let values = populatedDays.map { $0[keyPath: keyPath] }.filter { $0 > 0 }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func reload() async {
        await calorieStore.refresh()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var localIntake: [Date: Double] = [:]
        for offset in 0..<range.rawValue {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            localIntake[date] = calorieStore.summary(for: date).totals.calories
        }
        await insights.load(range: range, localIntake: localIntake)
    }
}
