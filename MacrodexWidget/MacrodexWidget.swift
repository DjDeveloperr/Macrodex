import SwiftUI
import WidgetKit
#if MACRODEX_WIDGET_RENDERER
import UIKit
#endif

private enum MacrodexWidgetStore {
    static let suiteName = "group.com.dj.macrodex"
    static let snapshotKey = "dashboard.progress.snapshot"
}

private struct MacrodexProgressSnapshot: Codable, Equatable {
    struct DayPoint: Codable, Equatable {
        let dateKey: String
        let calories: Double
    }

    let dateKey: String
    let caloriesConsumed: Double
    let calorieGoal: Double
    let proteinConsumed: Double
    let proteinGoal: Double
    let carbsConsumed: Double
    let carbsGoal: Double
    let fatConsumed: Double
    let fatGoal: Double
    let logCount: Int
    let mealCalories: [String: Double]?
    let weekCalories: [DayPoint]?
    let updatedAt: Date

    static let placeholder = MacrodexProgressSnapshot(
        dateKey: "Today",
        caloriesConsumed: 1_640,
        calorieGoal: 2_200,
        proteinConsumed: 112,
        proteinGoal: 165,
        carbsConsumed: 154,
        carbsGoal: 220,
        fatConsumed: 48,
        fatGoal: 73,
        logCount: 5,
        mealCalories: [
            "breakfast": 420,
            "lunch": 610,
            "dinner": 520,
            "snack": 90
        ],
        weekCalories: [
            .init(dateKey: "2026-06-06", calories: 2_080),
            .init(dateKey: "2026-06-07", calories: 1_960),
            .init(dateKey: "2026-06-08", calories: 2_140),
            .init(dateKey: "2026-06-09", calories: 2_010),
            .init(dateKey: "2026-06-10", calories: 1_880),
            .init(dateKey: "2026-06-11", calories: 2_230),
            .init(dateKey: "2026-06-12", calories: 1_640)
        ],
        updatedAt: Date()
    )

    var calorieProgress: Double {
        progress(consumed: caloriesConsumed, goal: calorieGoal)
    }

    var proteinProgress: Double {
        progress(consumed: proteinConsumed, goal: proteinGoal)
    }

    var carbsProgress: Double {
        progress(consumed: carbsConsumed, goal: carbsGoal)
    }

    var fatProgress: Double {
        progress(consumed: fatConsumed, goal: fatGoal)
    }

    var remainingCalories: Double {
        calorieGoal - caloriesConsumed
    }

    var resolvedMealCalories: [String: Double] {
        mealCalories ?? [:]
    }

    var resolvedWeekCalories: [DayPoint] {
        weekCalories ?? []
    }

    private func progress(consumed: Double, goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return min(max(consumed / goal, 0), 1.15)
    }
}

private struct MacrodexProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: MacrodexProgressSnapshot
}

private struct MacrodexProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacrodexProgressEntry {
        MacrodexProgressEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacrodexProgressEntry) -> Void) {
        completion(MacrodexProgressEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacrodexProgressEntry>) -> Void) {
        let entry = MacrodexProgressEntry(date: Date(), snapshot: loadSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 20, to: Date()) ?? Date().addingTimeInterval(1_200)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> MacrodexProgressSnapshot {
        guard let defaults = UserDefaults(suiteName: MacrodexWidgetStore.suiteName),
              let data = defaults.data(forKey: MacrodexWidgetStore.snapshotKey),
              let snapshot = try? JSONDecoder().decode(MacrodexProgressSnapshot.self, from: data)
        else {
            return .placeholder
        }
        return snapshot
    }
}

private struct MacrodexProgressWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    let entry: MacrodexProgressEntry
    var renderedFamily: WidgetFamily?

    private var snapshot: MacrodexProgressSnapshot {
        entry.snapshot
    }

    private var resolvedFamily: WidgetFamily {
        renderedFamily ?? family
    }

    var body: some View {
        switch resolvedFamily {
        case .systemMedium:
            mediumWidget
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .macrodexWidgetBackground()
        case .systemLarge:
            largeWidget
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .macrodexWidgetBackground()
        case .accessoryCircular:
            circularAccessory
        case .accessoryRectangular:
            rectangularAccessory
        case .accessoryInline:
            Text(inlineText)
        default:
            smallWidget
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .macrodexWidgetBackground()
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            widgetHeader(title: "Today", icon: "bolt.heart.fill", color: calorieTint, palette: palette)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(remainingHeadline)
                    .font(.system(size: remainingIsNearGoal ? 25 : 34, weight: .bold, design: .rounded))
                    .foregroundStyle(calorieTint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if !remainingIsNearGoal {
                    Text(remainingCaption)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }

            WidgetProgressBar(progress: snapshot.calorieProgress, color: calorieTint, palette: palette, height: 8)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(calorieSummary)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Text("\(snapshot.logCount) logs")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(spacing: 5) {
                MacroMini(label: "P", value: snapshot.proteinConsumed, color: palette.protein)
                MacroMini(label: "C", value: snapshot.carbsConsumed, color: palette.carbs)
                MacroMini(label: "F", value: snapshot.fatConsumed, color: palette.fat)
            }
        }
        .padding(14)
    }

    private var mediumWidget: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                widgetHeader(title: "Today", icon: "bolt.heart.fill", color: calorieTint, palette: palette)
                Spacer(minLength: 0)
                Text(remainingText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(calorieTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(calorieSummary)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                WidgetProgressBar(progress: snapshot.calorieProgress, color: calorieTint, palette: palette, height: 8)
                Text("\(snapshot.logCount) logged")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(width: 132, alignment: .leading)

            VStack(spacing: 10) {
                MacroBar(
                    title: "Protein",
                    value: Int(snapshot.proteinConsumed.rounded()),
                    goal: Int(snapshot.proteinGoal.rounded()),
                    progress: snapshot.proteinProgress,
                    color: palette.protein,
                    palette: palette
                )
                MacroBar(
                    title: "Carbs",
                    value: Int(snapshot.carbsConsumed.rounded()),
                    goal: Int(snapshot.carbsGoal.rounded()),
                    progress: snapshot.carbsProgress,
                    color: palette.carbs,
                    palette: palette
                )
                MacroBar(
                    title: "Fat",
                    value: Int(snapshot.fatConsumed.rounded()),
                    goal: Int(snapshot.fatGoal.rounded()),
                    progress: snapshot.fatProgress,
                    color: palette.fat,
                    palette: palette
                )
            }
        }
        .padding(16)
    }

    private var largeWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetHeader(title: "Macrodex", icon: "bolt.heart.fill", color: calorieTint, palette: palette)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(remainingText)
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(calorieTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 0)
                    Text("\(Int(snapshot.caloriesConsumed.rounded())) kcal")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(palette.textSecondary)
                }
                WidgetProgressBar(progress: snapshot.calorieProgress, color: calorieTint, palette: palette, height: 10)
                Text("\(calorieSummary) today · \(snapshot.logCount) logged")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }

            MacroSummaryStrip(snapshot: snapshot, palette: palette)
            MealGridView(meals: snapshot.resolvedMealCalories, palette: palette)
            WeekSparkline(points: snapshot.resolvedWeekCalories, goal: snapshot.calorieGoal, color: calorieTint, palette: palette, compact: true)
        }
        .padding(16)
    }

    private var circularAccessory: some View {
        Gauge(value: min(snapshot.calorieProgress, 1)) {
            Text("Cal")
        } currentValueLabel: {
            Text("\(Int(snapshot.caloriesConsumed.rounded()))")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(calorieTint)
    }

    private var rectangularAccessory: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Macrodex")
                    .font(.caption.weight(.semibold))
                Text("\(Int(snapshot.caloriesConsumed.rounded()))/\(Int(snapshot.calorieGoal.rounded()))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            WidgetProgressBar(progress: snapshot.calorieProgress, color: calorieTint, palette: palette, height: 4)
            Text(remainingText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var remainingText: String {
        let remaining = Int(abs(snapshot.remainingCalories).rounded())
        if remaining <= 20 {
            return "Near goal"
        }
        if snapshot.remainingCalories >= 0 {
            return "\(remaining) kcal left"
        }
        return "\(remaining) kcal over"
    }

    private var inlineText: String {
        let remaining = Int(snapshot.remainingCalories.rounded())
        if abs(remaining) <= 20 {
            return "\(Int(snapshot.caloriesConsumed.rounded())) kcal, near goal"
        }
        if remaining > 0 {
            return "\(remaining) kcal left"
        }
        return "\(abs(remaining)) kcal over"
    }

    private var remainingIsNearGoal: Bool {
        abs(snapshot.remainingCalories) <= 20
    }

    private var remainingHeadline: String {
        remainingIsNearGoal ? "Near goal" : "\(Int(abs(snapshot.remainingCalories).rounded()))"
    }

    private var remainingCaption: String {
        snapshot.remainingCalories >= 0 ? "kcal left" : "kcal over"
    }

    private var calorieSummary: String {
        "\(Int(snapshot.caloriesConsumed.rounded())) / \(Int(snapshot.calorieGoal.rounded()))"
    }

    private var calorieTint: Color {
        snapshot.remainingCalories < -20 ? palette.warning : palette.accent
    }

    private var palette: WidgetPalette {
        WidgetPalette(colorScheme: colorScheme)
    }
}

private struct MacroMini: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(label) \(Int(value.rounded()))")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.76))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MacroBar: View {
    let title: String
    let value: Int
    let goal: Int
    let progress: Double
    let color: Color
    let palette: WidgetPalette
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(value)/\(max(goal, 0))g")
                    .font((compact ? Font.system(size: 10, weight: .bold) : .caption2.weight(.bold)).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            WidgetProgressBar(progress: progress, color: color, palette: palette, height: compact ? 5 : 6)
        }
    }
}

private struct MacroSummaryStrip: View {
    let snapshot: MacrodexProgressSnapshot
    let palette: WidgetPalette

    var body: some View {
        HStack(spacing: 10) {
            CompactMacroMetric(title: "Protein", value: snapshot.proteinConsumed, goal: snapshot.proteinGoal, progress: snapshot.proteinProgress, color: palette.protein, palette: palette)
            CompactMacroMetric(title: "Carbs", value: snapshot.carbsConsumed, goal: snapshot.carbsGoal, progress: snapshot.carbsProgress, color: palette.carbs, palette: palette)
            CompactMacroMetric(title: "Fat", value: snapshot.fatConsumed, goal: snapshot.fatGoal, progress: snapshot.fatProgress, color: palette.fat, palette: palette)
        }
    }
}

private struct CompactMacroMetric: View {
    let title: String
    let value: Double
    let goal: Double
    let progress: Double
    let color: Color
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
            }
            WidgetProgressBar(progress: progress, color: color, palette: palette, height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WidgetProgressBar: View {
    let progress: Double
    let color: Color
    let palette: WidgetPalette
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 0)
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.track)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: width * CGFloat(clamped))
                if progress > 1 {
                    Capsule(style: .continuous)
                        .fill(palette.warning)
                        .frame(width: width * CGFloat(min(progress - 1, 0.18) / 0.18) * 0.18)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(height: height)
    }
}

private struct MealBreakdownView: View {
    let meals: [String: Double]
    let palette: WidgetPalette
    var compact = true
    var showsTitle = true

    private var rows: [(String, Double, Color)] {
        [
            ("Breakfast", meals["breakfast"] ?? 0, palette.protein),
            ("Lunch", meals["lunch"] ?? 0, palette.carbs),
            ("Dinner", meals["dinner"] ?? 0, palette.fat),
            ("Snack", meals["snack"] ?? 0, palette.accent)
        ]
    }

    private var maxMealCalories: Double {
        max(rows.map(\.1).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 8) {
            if showsTitle {
                Text("Meals")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.textSecondary)
            }
            ForEach(rows, id: \.0) { row in
                mealRow(row)
            }
        }
    }

    private func mealRow(_ row: (String, Double, Color)) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.2)
                    .frame(width: 7, height: 7)
                Text(row.0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int(row.1.rounded()))")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(palette.textPrimary)
            }
            if !compact {
                WidgetProgressBar(progress: row.1 / maxMealCalories, color: row.2, palette: palette, height: 4)
                    .padding(.leading, 15)
            }
        }
    }
}

private struct MealGridView: View {
    let meals: [String: Double]
    let palette: WidgetPalette

    private var rows: [(String, Double, Color)] {
        [
            ("Breakfast", meals["breakfast"] ?? 0, palette.protein),
            ("Lunch", meals["lunch"] ?? 0, palette.carbs),
            ("Dinner", meals["dinner"] ?? 0, palette.fat),
            ("Snack", meals["snack"] ?? 0, palette.accent)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Meals")
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(row.2)
                            .frame(width: 6, height: 6)
                        Text(row.0)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Text("\(Int(row.1.rounded()))")
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(palette.textPrimary)
                    }
                }
            }
        }
    }
}

private struct WeekSparkline: View {
    let points: [MacrodexProgressSnapshot.DayPoint]
    let goal: Double
    let color: Color
    let palette: WidgetPalette
    var compact = false

    private var maxValue: Double {
        max(points.map(\.calories).max() ?? 1, goal, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? "7 days" : "7 day calories")
                    .font((compact ? Font.caption2 : .caption).weight(.bold))
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                if let average = weekAverage {
                    Text("\(Int(average.rounded())) avg")
                        .font((compact ? Font.system(size: 10, weight: .bold) : .caption2.weight(.bold)).monospacedDigit())
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(point.calories > goal ? palette.warning : color)
                            .frame(height: max(compact ? 6 : 7, CGFloat(point.calories / maxValue) * chartHeight))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)

                if goal > 0 {
                    Rectangle()
                        .fill(palette.textSecondary.opacity(0.34))
                        .frame(height: 1)
                        .offset(y: -CGFloat(min(goal / maxValue, 1)) * chartHeight)
                }
            }
            .frame(height: chartHeight + 4, alignment: .bottom)
        }
    }

    private var weekAverage: Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0) { $0 + $1.calories } / Double(points.count)
    }

    private var chartHeight: CGFloat {
        compact ? 34 : 44
    }
}

private struct MacrodexMacrosWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MacrodexProgressEntry
    var renderedFamily: WidgetFamily?

    private var snapshot: MacrodexProgressSnapshot { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette(colorScheme: colorScheme) }
    private var isSmall: Bool { (renderedFamily ?? family) == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 8 : 12) {
            widgetHeader(title: "Macros", icon: "chart.bar.fill", color: palette.protein, palette: palette)
            MacroBar(title: "Protein", value: Int(snapshot.proteinConsumed.rounded()), goal: Int(snapshot.proteinGoal.rounded()), progress: snapshot.proteinProgress, color: palette.protein, palette: palette, compact: isSmall)
            MacroBar(title: "Carbs", value: Int(snapshot.carbsConsumed.rounded()), goal: Int(snapshot.carbsGoal.rounded()), progress: snapshot.carbsProgress, color: palette.carbs, palette: palette, compact: isSmall)
            MacroBar(title: "Fat", value: Int(snapshot.fatConsumed.rounded()), goal: Int(snapshot.fatGoal.rounded()), progress: snapshot.fatProgress, color: palette.fat, palette: palette, compact: isSmall)
            Spacer(minLength: 0)
            Text("\(Int(snapshot.caloriesConsumed.rounded()))/\(Int(snapshot.calorieGoal.rounded())) kcal")
                .font((isSmall ? Font.caption2 : .caption).weight(.bold))
                .foregroundStyle(palette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(isSmall ? 14 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .macrodexWidgetBackground()
    }
}

private struct MacrodexMealsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MacrodexProgressEntry
    var renderedFamily: WidgetFamily?

    private var snapshot: MacrodexProgressSnapshot { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            widgetHeader(title: "Meals", icon: "fork.knife.circle.fill", color: palette.accent, palette: palette)
            MealBreakdownView(meals: snapshot.resolvedMealCalories, palette: palette, showsTitle: false)
            if (renderedFamily ?? family) != .systemSmall {
                Spacer(minLength: 0)
                Text("\(snapshot.logCount) logged today")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .macrodexWidgetBackground()
    }
}

private struct MacrodexWeekWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MacrodexProgressEntry
    var renderedFamily: WidgetFamily?

    private var snapshot: MacrodexProgressSnapshot { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette(colorScheme: colorScheme) }
    private var isSmall: Bool { (renderedFamily ?? family) == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 10 : 14) {
            widgetHeader(title: "Week", icon: "calendar", color: palette.accent, palette: palette)
            WeekSparkline(points: snapshot.resolvedWeekCalories, goal: snapshot.calorieGoal, color: palette.accent, palette: palette, compact: isSmall)
            Spacer(minLength: 0)
            HStack {
                Text("Today")
                    .font((isSmall ? Font.caption2 : .caption).weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Text("\(Int(snapshot.caloriesConsumed.rounded()))")
                    .font((isSmall ? Font.title3 : .headline).monospacedDigit().weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
        }
        .padding(isSmall ? 14 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .macrodexWidgetBackground()
    }
}

private func widgetHeader(title: String, icon: String, color: Color, palette: WidgetPalette) -> some View {
    HStack(spacing: 7) {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(palette.textPrimary)
            .lineLimit(1)
        Spacer(minLength: 0)
    }
}

private struct WidgetPalette {
    let colorScheme: ColorScheme

    var accent: Color { Color(red: 0.20, green: 0.60, blue: 1.00) }
    var protein: Color { Color(red: 0.17, green: 0.72, blue: 0.52) }
    var carbs: Color { Color(red: 0.94, green: 0.58, blue: 0.18) }
    var fat: Color { Color(red: 0.74, green: 0.47, blue: 0.95) }
    var warning: Color { Color(red: 0.98, green: 0.47, blue: 0.23) }
    var backgroundTop: Color { Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground) }
    var backgroundBottom: Color { Color(uiColor: colorScheme == .dark ? .systemBackground : .secondarySystemBackground) }
    var surfaceGlow: Color { accent.opacity(colorScheme == .dark ? 0.18 : 0.09) }
    var textPrimary: Color { Color(uiColor: .label) }
    var textSecondary: Color { Color(uiColor: .secondaryLabel) }
    var track: Color { Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09) }
}

private struct WidgetSurfaceBackground: View {
    let palette: WidgetPalette

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [palette.surfaceGlow, .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 180
            )
        }
    }
}

private struct MacrodexWidgetBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = WidgetPalette(colorScheme: colorScheme)
        content
            .background(WidgetSurfaceBackground(palette: palette))
            .containerBackground(for: .widget) {
                WidgetSurfaceBackground(palette: palette)
            }
    }
}

private extension View {
    func macrodexWidgetBackground() -> some View {
        modifier(MacrodexWidgetBackgroundModifier())
    }
}

struct MacrodexProgressWidget: Widget {
    let kind = "MacrodexProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacrodexProgressProvider()) { entry in
            MacrodexProgressWidgetView(entry: entry)
        }
        .configurationDisplayName("Macrodex Progress")
        .description("Glance at today's calories and macro progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct MacrodexMacrosWidget: Widget {
    let kind = "MacrodexMacrosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacrodexProgressProvider()) { entry in
            MacrodexMacrosWidgetView(entry: entry)
        }
        .configurationDisplayName("Macrodex Macros")
        .description("Track protein, carbs, fat, and calories.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct MacrodexMealsWidget: Widget {
    let kind = "MacrodexMealsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacrodexProgressProvider()) { entry in
            MacrodexMealsWidgetView(entry: entry)
        }
        .configurationDisplayName("Macrodex Meals")
        .description("See calories by meal for today.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct MacrodexWeekWidget: Widget {
    let kind = "MacrodexWeekWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacrodexProgressProvider()) { entry in
            MacrodexWeekWidgetView(entry: entry)
        }
        .configurationDisplayName("Macrodex Week")
        .description("Review your seven-day calorie trend.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

#if !MACRODEX_WIDGET_RENDERER
@main
struct MacrodexWidgets: WidgetBundle {
    var body: some Widget {
        MacrodexProgressWidget()
        MacrodexMacrosWidget()
        MacrodexMealsWidget()
        MacrodexWeekWidget()
    }
}
#endif

#if MACRODEX_WIDGET_RENDERER
@main
enum MacrodexWidgetRenderCLI {
    @MainActor
    static func main() {
        let outputPath = ProcessInfo.processInfo.environment["MACRODEX_WIDGET_RENDER_DIR"] ?? "/tmp/macrodex-widget-renders"
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let entry = MacrodexProgressEntry(date: Date(), snapshot: .placeholder)
        let renders: [(name: String, family: WidgetFamily, size: CGSize, view: AnyView)] = [
            ("progress-small", .systemSmall, CGSize(width: 158, height: 158), AnyView(MacrodexProgressWidgetView(entry: entry, renderedFamily: .systemSmall))),
            ("progress-medium", .systemMedium, CGSize(width: 338, height: 158), AnyView(MacrodexProgressWidgetView(entry: entry, renderedFamily: .systemMedium))),
            ("progress-large", .systemLarge, CGSize(width: 338, height: 354), AnyView(MacrodexProgressWidgetView(entry: entry, renderedFamily: .systemLarge))),
            ("macros-small", .systemSmall, CGSize(width: 158, height: 158), AnyView(MacrodexMacrosWidgetView(entry: entry, renderedFamily: .systemSmall))),
            ("macros-medium", .systemMedium, CGSize(width: 338, height: 158), AnyView(MacrodexMacrosWidgetView(entry: entry, renderedFamily: .systemMedium))),
            ("meals-small", .systemSmall, CGSize(width: 158, height: 158), AnyView(MacrodexMealsWidgetView(entry: entry, renderedFamily: .systemSmall))),
            ("meals-medium", .systemMedium, CGSize(width: 338, height: 158), AnyView(MacrodexMealsWidgetView(entry: entry, renderedFamily: .systemMedium))),
            ("week-small", .systemSmall, CGSize(width: 158, height: 158), AnyView(MacrodexWeekWidgetView(entry: entry, renderedFamily: .systemSmall))),
            ("week-medium", .systemMedium, CGSize(width: 338, height: 158), AnyView(MacrodexWeekWidgetView(entry: entry, renderedFamily: .systemMedium))),
            ("progress-accessory-circular", .accessoryCircular, CGSize(width: 76, height: 76), AnyView(MacrodexProgressWidgetView(entry: entry, renderedFamily: .accessoryCircular))),
            ("progress-accessory-rectangular", .accessoryRectangular, CGSize(width: 160, height: 54), AnyView(MacrodexProgressWidgetView(entry: entry, renderedFamily: .accessoryRectangular)))
        ]

        for (schemeName, colorScheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for render in renders {
                let content = render.view
                    .environment(\.colorScheme, colorScheme)
                    .frame(width: render.size.width, height: render.size.height)

                let renderer = ImageRenderer(content: content)
                renderer.scale = 3
                renderer.proposedSize = ProposedViewSize(render.size)

                guard let data = renderer.uiImage?.pngData() else {
                    print("render-failed \(schemeName)-\(render.name)")
                    continue
                }

                let fileURL = outputURL.appendingPathComponent("\(schemeName)-\(render.name).png")
                do {
                    try data.write(to: fileURL, options: Data.WritingOptions.atomic)
                    print(fileURL.path)
                } catch {
                    print("write-failed \(fileURL.path): \(error)")
                }
            }
        }
    }
}
#endif
