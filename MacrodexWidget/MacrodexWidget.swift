import SwiftUI
import WidgetKit

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

    private var snapshot: MacrodexProgressSnapshot {
        entry.snapshot
    }

    var body: some View {
        switch family {
        case .systemMedium:
            mediumWidget
                .macrodexWidgetBackground()
        case .systemLarge:
            largeWidget
                .macrodexWidgetBackground()
        case .accessoryCircular:
            circularAccessory
        case .accessoryRectangular:
            rectangularAccessory
        case .accessoryInline:
            Text(inlineText)
        default:
            smallWidget
                .macrodexWidgetBackground()
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Spacer(minLength: 0)

            ZStack {
                ProgressRing(
                    progress: snapshot.calorieProgress,
                    lineWidth: 12,
                    track: palette.track,
                    fill: calorieTint
                )
                VStack(spacing: 2) {
                    Text("\(Int(snapshot.caloriesConsumed.rounded()))")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(Int(snapshot.calorieGoal.rounded()))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)

            remainingPill
        }
        .padding(16)
    }

    private var mediumWidget: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                header
                Text(remainingText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(calorieTint)
                    .lineLimit(2)
                    .minimumScaleFactor(0.74)
                Text("\(snapshot.logCount) logged today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                remainingPill
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                MacroColumn(
                    title: "Cal",
                    value: Int(snapshot.caloriesConsumed.rounded()),
                    goal: Int(snapshot.calorieGoal.rounded()),
                    progress: snapshot.calorieProgress,
                    color: calorieTint
                )
                MacroColumn(
                    title: "P",
                    value: Int(snapshot.proteinConsumed.rounded()),
                    goal: Int(snapshot.proteinGoal.rounded()),
                    progress: snapshot.proteinProgress,
                    color: palette.protein
                )
                MacroColumn(
                    title: "C",
                    value: Int(snapshot.carbsConsumed.rounded()),
                    goal: Int(snapshot.carbsGoal.rounded()),
                    progress: snapshot.carbsProgress,
                    color: palette.carbs
                )
                MacroColumn(
                    title: "F",
                    value: Int(snapshot.fatConsumed.rounded()),
                    goal: Int(snapshot.fatGoal.rounded()),
                    progress: snapshot.fatProgress,
                    color: palette.fat
                )
            }
        }
        .padding(16)
    }

    private var largeWidget: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    ProgressRing(progress: snapshot.calorieProgress, lineWidth: 14, track: palette.track, fill: calorieTint)
                    VStack(spacing: 3) {
                        Text("\(Int(snapshot.caloriesConsumed.rounded()))")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(remainingText)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(calorieTint)
                    }
                }
                .frame(width: 128, height: 128)

                VStack(spacing: 10) {
                    MacroBar(title: "Protein", value: snapshot.proteinConsumed, goal: snapshot.proteinGoal, color: palette.protein)
                    MacroBar(title: "Carbs", value: snapshot.carbsConsumed, goal: snapshot.carbsGoal, color: palette.carbs)
                    MacroBar(title: "Fat", value: snapshot.fatConsumed, goal: snapshot.fatGoal, color: palette.fat)
                }
            }
            MealBreakdownView(meals: snapshot.resolvedMealCalories, palette: palette)
            WeekSparkline(points: snapshot.resolvedWeekCalories, goal: snapshot.calorieGoal, color: calorieTint)
        }
        .padding(18)
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
            ProgressView(value: min(snapshot.calorieProgress, 1))
                .tint(calorieTint)
            Text(remainingText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.heart.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(palette.accent)
            Text("Macrodex")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private var remainingPill: some View {
        Text(remainingText)
            .font(.caption2.weight(.bold))
            .foregroundStyle(calorieTint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(calorieTint.opacity(colorScheme == .dark ? 0.18 : 0.13), in: Capsule())
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

    private var calorieTint: Color {
        snapshot.remainingCalories < -20 ? palette.warning : palette.accent
    }

    private var palette: WidgetPalette {
        WidgetPalette(colorScheme: colorScheme)
    }
}

private struct MacroColumn: View {
    let title: String
    let value: Int
    let goal: Int
    let progress: Double
    let color: Color

    var body: some View {
        VStack(spacing: 7) {
            ProgressRing(progress: progress, lineWidth: 7, track: Color.primary.opacity(0.1), fill: color)
                .frame(width: 42, height: 42)
                .overlay {
                    Text(title)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(color)
                }
            VStack(spacing: 1) {
                Text("\(value)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                Text("/\(max(goal, 0))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: 46)
    }
}

private struct MacroBar: View {
    let title: String
    let value: Double
    let goal: Double
    let color: Color

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1.15)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(value.rounded()))/\(Int(goal.rounded()))g")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: min(progress, 1))
                .tint(color)
        }
    }
}

private struct MealBreakdownView: View {
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
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(row.2)
                        .frame(width: 7, height: 7)
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(row.1.rounded()))")
                        .font(.caption.monospacedDigit().weight(.bold))
                }
            }
        }
    }
}

private struct WeekSparkline: View {
    let points: [MacrodexProgressSnapshot.DayPoint]
    let goal: Double
    let color: Color

    private var maxValue: Double {
        max(points.map(\.calories).max() ?? 1, goal, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("7 day calories")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(point.calories > goal ? WidgetPalette(colorScheme: .light).warning : color)
                        .frame(height: max(8, CGFloat(point.calories / maxValue) * 44))
                        .overlay(alignment: .bottom) {
                            if point.calories > goal {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(Color.orange.opacity(0.7), lineWidth: 1)
                            }
                        }
                }
            }
            .frame(height: 48, alignment: .bottom)
        }
    }
}

private struct MacrodexMacrosWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: MacrodexProgressEntry

    private var snapshot: MacrodexProgressSnapshot { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetHeader(title: "Macros", icon: "chart.bar.fill", color: palette.protein)
            MacroBar(title: "Protein", value: snapshot.proteinConsumed, goal: snapshot.proteinGoal, color: palette.protein)
            MacroBar(title: "Carbs", value: snapshot.carbsConsumed, goal: snapshot.carbsGoal, color: palette.carbs)
            MacroBar(title: "Fat", value: snapshot.fatConsumed, goal: snapshot.fatGoal, color: palette.fat)
            Spacer(minLength: 0)
            Text("\(Int(snapshot.caloriesConsumed.rounded()))/\(Int(snapshot.calorieGoal.rounded())) kcal")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(16)
        .macrodexWidgetBackground()
    }
}

private struct MacrodexMealsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MacrodexProgressEntry

    private var snapshot: MacrodexProgressSnapshot { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            widgetHeader(title: "Meals", icon: "fork.knife.circle.fill", color: palette.accent)
            MealBreakdownView(meals: snapshot.resolvedMealCalories, palette: palette)
            if family != .systemSmall {
                Spacer(minLength: 0)
                Text("\(snapshot.logCount) logged today")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .macrodexWidgetBackground()
    }
}

private struct MacrodexWeekWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: MacrodexProgressEntry

    private var snapshot: MacrodexProgressSnapshot { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetHeader(title: "Week", icon: "calendar", color: palette.accent)
            WeekSparkline(points: snapshot.resolvedWeekCalories, goal: snapshot.calorieGoal, color: palette.accent)
            Spacer(minLength: 0)
            HStack {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(snapshot.caloriesConsumed.rounded()))")
                    .font(.headline.monospacedDigit().weight(.bold))
            }
        }
        .padding(16)
        .macrodexWidgetBackground()
    }
}

private func widgetHeader(title: String, icon: String, color: Color) -> some View {
    HStack(spacing: 7) {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
        Text(title)
            .font(.caption.weight(.bold))
        Spacer(minLength: 0)
    }
}

private struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let track: Color
    let fill: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 0.15) / 0.15)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: max(lineWidth * 0.45, 3), lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct WidgetPalette {
    let colorScheme: ColorScheme

    var accent: Color { Color(red: 0.20, green: 0.60, blue: 1.00) }
    var protein: Color { Color(red: 0.17, green: 0.72, blue: 0.52) }
    var carbs: Color { Color(red: 0.94, green: 0.58, blue: 0.18) }
    var fat: Color { Color(red: 0.74, green: 0.47, blue: 0.95) }
    var warning: Color { Color(red: 0.98, green: 0.47, blue: 0.23) }
    var track: Color { Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10) }
}

private extension View {
    func macrodexWidgetBackground() -> some View {
        containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .secondarySystemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
    }
}

@main
struct MacrodexWidgets: WidgetBundle {
    var body: some Widget {
        MacrodexProgressWidget()
        MacrodexMacrosWidget()
        MacrodexMealsWidget()
        MacrodexWeekWidget()
    }
}
