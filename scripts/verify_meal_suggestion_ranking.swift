#!/usr/bin/env swift
import Foundation

private enum Meal: String {
    case breakfast
    case lunch
    case dinner
    case snack
    case other
}

private struct Food {
    let name: String
    let calories: Double
    let protein: Double
    let totalUseCount: Int
    let lastMeal: Meal
    let mealUseCounts: [Meal: Int]
    let mealLastUsedAtMs: [Meal: Int64]

    func usualMeal(fallback: Meal) -> Meal {
        let ranked = mealUseCounts
            .filter { $0.key != .other && $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let leftLastUsed = mealLastUsedAtMs[lhs.key] ?? 0
                let rightLastUsed = mealLastUsedAtMs[rhs.key] ?? 0
                if leftLastUsed != rightLastUsed { return leftLastUsed > rightLastUsed }
                return lhs.key.rawValue < rhs.key.rawValue
            }
        if let meal = ranked.first?.key {
            return meal
        }
        return lastMeal == .other ? fallback : lastMeal
    }
}

private struct Suggestion {
    let food: Food
    let meal: Meal

    var mealUseCount: Int {
        food.mealUseCounts[meal, default: 0]
    }

    var mealLastUsedAtMs: Int64? {
        food.mealLastUsedAtMs[meal]
    }
}

private func score(_ suggestion: Suggestion, targetCalories: Double, currentMeal: Meal) -> Double {
    let calorieFit = abs(suggestion.food.calories - targetCalories) / max(targetCalories, 1)
    let calorieWeight = suggestion.mealUseCount > 0 ? 0.42 : 0.9
    let mealPenalty = suggestion.meal == currentMeal ? 0.0 : 0.18
    let proteinBonus = min(suggestion.food.protein / 35, 1) * 0.12
    let missingMealHistoryPenalty = suggestion.mealUseCount == 0 ? 0.28 : 0.0
    let mealHistoryBonus = min(Double(suggestion.mealUseCount), 12) * 0.11
    let totalHistoryBonus = min(Double(suggestion.food.totalUseCount), 25) * 0.006
    let recencyBonus = suggestion.mealLastUsedAtMs == nil ? 0.0 : 0.06
    return (calorieFit * calorieWeight)
        + mealPenalty
        + missingMealHistoryPenalty
        - proteinBonus
        - mealHistoryBonus
        - totalHistoryBonus
        - recencyBonus
}

private let breakfastFrequent = Food(
    name: "Greek yogurt",
    calories: 220,
    protein: 22,
    totalUseCount: 42,
    lastMeal: .snack,
    mealUseCounts: [.breakfast: 18, .snack: 2],
    mealLastUsedAtMs: [.breakfast: 1_780_000_000_000, .snack: 1_790_000_000_000]
)

private let wrongRecent = Food(
    name: "Protein chips",
    calories: 260,
    protein: 19,
    totalUseCount: 11,
    lastMeal: .snack,
    mealUseCounts: [.snack: 11],
    mealLastUsedAtMs: [.snack: 1_800_000_000_000]
)

private let currentMeal = Meal.breakfast
private let targetCalories = 260.0
private let breakfastMeal = breakfastFrequent.usualMeal(fallback: currentMeal)

guard breakfastMeal == .breakfast else {
    fatalError("Expected usual meal to prefer breakfast history over stale snack lastMeal.")
}

private let ranked = [
    Suggestion(food: breakfastFrequent, meal: breakfastMeal),
    Suggestion(food: wrongRecent, meal: currentMeal)
].sorted {
    score($0, targetCalories: targetCalories, currentMeal: currentMeal)
        < score($1, targetCalories: targetCalories, currentMeal: currentMeal)
}

guard ranked.first?.food.name == "Greek yogurt" else {
    fatalError("Expected meal-specific frequent food to outrank generic recent/wrong item.")
}

print("meal suggestion ranking fixture passed")
