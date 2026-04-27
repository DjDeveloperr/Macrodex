import Foundation

struct StandardFoodItem: Identifiable, Equatable {
    let id: String
    let name: String
    let aliases: [String]
    let servingQuantity: Double
    let servingUnit: String
    let servingWeight: Double?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let mealHints: [String]

    var detail: String {
        "\(calories.cleanString) kcal · P \(protein.cleanString)g · \(servingQuantity.cleanString) \(servingUnit)"
    }
}

enum StandardFoodDatabase {
    static let foods: [StandardFoodItem] = [
        .init(id: "egg", name: "Eggs", aliases: ["egg", "eggs", "large egg"], servingQuantity: 1, servingUnit: "egg", servingWeight: 50, calories: 72, protein: 6.3, carbs: 0.4, fat: 4.8, mealHints: ["breakfast", "snack"]),
        .init(id: "egg-whites", name: "Egg whites", aliases: ["egg white", "egg whites"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 52, protein: 10.9, carbs: 0.7, fat: 0.2, mealHints: ["breakfast"]),
        .init(id: "banana", name: "Banana", aliases: ["banana", "bananas"], servingQuantity: 1, servingUnit: "banana", servingWeight: 118, calories: 105, protein: 1.3, carbs: 27, fat: 0.4, mealHints: ["breakfast", "snack", "pre_workout"]),
        .init(id: "apple", name: "Apple", aliases: ["apple", "apples"], servingQuantity: 1, servingUnit: "apple", servingWeight: 182, calories: 95, protein: 0.5, carbs: 25, fat: 0.3, mealHints: ["snack"]),
        .init(id: "grapes", name: "Grapes", aliases: ["grape", "grapes"], servingQuantity: 15, servingUnit: "grapes", servingWeight: 75, calories: 52, protein: 0.5, carbs: 14, fat: 0.1, mealHints: ["snack"]),
        .init(id: "greek-yogurt", name: "Greek yogurt", aliases: ["greek yogurt", "yogurt", "plain greek yogurt"], servingQuantity: 170, servingUnit: "g", servingWeight: 170, calories: 100, protein: 17, carbs: 6, fat: 0.7, mealHints: ["breakfast", "snack"]),
        .init(id: "cottage-cheese", name: "Cottage cheese", aliases: ["cottage cheese"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 98, protein: 11, carbs: 3.4, fat: 4.3, mealHints: ["breakfast", "snack"]),
        .init(id: "oatmeal", name: "Oatmeal", aliases: ["oats", "oatmeal", "rolled oats"], servingQuantity: 40, servingUnit: "g", servingWeight: 40, calories: 150, protein: 5, carbs: 27, fat: 3, mealHints: ["breakfast"]),
        .init(id: "chicken-breast", name: "Chicken breast", aliases: ["chicken", "chicken breast"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 165, protein: 31, carbs: 0, fat: 3.6, mealHints: ["lunch", "dinner"]),
        .init(id: "salmon", name: "Salmon", aliases: ["salmon", "salmon fillet"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 208, protein: 20, carbs: 0, fat: 13, mealHints: ["lunch", "dinner"]),
        .init(id: "rice", name: "Rice bowl", aliases: ["rice", "white rice", "rice bowl"], servingQuantity: 1, servingUnit: "cup", servingWeight: 158, calories: 205, protein: 4.3, carbs: 45, fat: 0.4, mealHints: ["lunch", "dinner"]),
        .init(id: "avocado", name: "Avocado", aliases: ["avocado"], servingQuantity: 0.5, servingUnit: "avocado", servingWeight: 75, calories: 120, protein: 1.5, carbs: 6, fat: 11, mealHints: ["breakfast", "lunch", "snack"]),
        .init(id: "protein-shake", name: "Protein shake", aliases: ["protein shake", "whey", "whey protein"], servingQuantity: 1, servingUnit: "scoop", servingWeight: 31, calories: 120, protein: 24, carbs: 3, fat: 1.5, mealHints: ["snack", "post_workout"]),
        .init(id: "coffee", name: "Coffee", aliases: ["coffee", "black coffee"], servingQuantity: 1, servingUnit: "cup", servingWeight: 240, calories: 2, protein: 0.3, carbs: 0, fat: 0, mealHints: ["drink", "breakfast"]),
        .init(id: "salad", name: "Salad", aliases: ["salad", "green salad"], servingQuantity: 1, servingUnit: "serving", servingWeight: 150, calories: 80, protein: 3, carbs: 12, fat: 3, mealHints: ["lunch", "dinner"]),
        .init(id: "sweet-potato", name: "Sweet potato", aliases: ["sweet potato", "yam"], servingQuantity: 1, servingUnit: "sweet potato", servingWeight: 130, calories: 112, protein: 2, carbs: 26, fat: 0.1, mealHints: ["lunch", "dinner"]),
        .init(id: "peanut-butter", name: "Peanut butter", aliases: ["peanut butter"], servingQuantity: 1, servingUnit: "tbsp", servingWeight: 16, calories: 94, protein: 3.5, carbs: 3.2, fat: 8, mealHints: ["breakfast", "snack"]),
        .init(id: "milk", name: "Milk", aliases: ["milk"], servingQuantity: 1, servingUnit: "cup", servingWeight: 244, calories: 122, protein: 8, carbs: 12, fat: 4.8, mealHints: ["drink", "breakfast"]),
        .init(id: "tofu", name: "Tofu", aliases: ["tofu"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 144, protein: 17, carbs: 3, fat: 9, mealHints: ["lunch", "dinner"]),
        .init(id: "brown-rice", name: "Brown rice", aliases: ["brown rice", "cooked brown rice"], servingQuantity: 1, servingUnit: "cup", servingWeight: 195, calories: 216, protein: 5, carbs: 45, fat: 1.8, mealHints: ["lunch", "dinner"]),
        .init(id: "pasta", name: "Pasta", aliases: ["pasta", "spaghetti", "cooked pasta"], servingQuantity: 1, servingUnit: "cup", servingWeight: 140, calories: 221, protein: 8, carbs: 43, fat: 1.3, mealHints: ["lunch", "dinner"]),
        .init(id: "bread", name: "Bread", aliases: ["bread", "toast", "slice bread"], servingQuantity: 1, servingUnit: "slice", servingWeight: 32, calories: 80, protein: 3, carbs: 15, fat: 1, mealHints: ["breakfast", "lunch", "snack"]),
        .init(id: "whole-wheat-bread", name: "Whole wheat bread", aliases: ["whole wheat bread", "wheat bread"], servingQuantity: 1, servingUnit: "slice", servingWeight: 32, calories: 81, protein: 4, carbs: 14, fat: 1.1, mealHints: ["breakfast", "lunch", "snack"]),
        .init(id: "potato", name: "Potato", aliases: ["potato", "baked potato"], servingQuantity: 1, servingUnit: "potato", servingWeight: 173, calories: 161, protein: 4.3, carbs: 37, fat: 0.2, mealHints: ["lunch", "dinner"]),
        .init(id: "broccoli", name: "Broccoli", aliases: ["broccoli", "steamed broccoli"], servingQuantity: 1, servingUnit: "cup", servingWeight: 156, calories: 55, protein: 3.7, carbs: 11, fat: 0.6, mealHints: ["lunch", "dinner"]),
        .init(id: "spinach", name: "Spinach", aliases: ["spinach", "baby spinach"], servingQuantity: 2, servingUnit: "cups", servingWeight: 60, calories: 14, protein: 1.7, carbs: 2.2, fat: 0.2, mealHints: ["lunch", "dinner"]),
        .init(id: "beef", name: "Lean beef", aliases: ["beef", "lean beef", "ground beef"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 217, protein: 26, carbs: 0, fat: 12, mealHints: ["lunch", "dinner"]),
        .init(id: "turkey", name: "Turkey breast", aliases: ["turkey", "turkey breast"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 135, protein: 30, carbs: 0, fat: 1, mealHints: ["lunch", "dinner"]),
        .init(id: "tuna", name: "Tuna", aliases: ["tuna", "canned tuna"], servingQuantity: 1, servingUnit: "can", servingWeight: 113, calories: 132, protein: 29, carbs: 0, fat: 1, mealHints: ["lunch", "dinner"]),
        .init(id: "shrimp", name: "Shrimp", aliases: ["shrimp", "prawns"], servingQuantity: 100, servingUnit: "g", servingWeight: 100, calories: 99, protein: 24, carbs: 0.2, fat: 0.3, mealHints: ["lunch", "dinner"]),
        .init(id: "black-beans", name: "Black beans", aliases: ["black beans", "beans"], servingQuantity: 0.5, servingUnit: "cup", servingWeight: 86, calories: 114, protein: 7.6, carbs: 20, fat: 0.5, mealHints: ["lunch", "dinner"]),
        .init(id: "lentils", name: "Lentils", aliases: ["lentils", "cooked lentils"], servingQuantity: 0.5, servingUnit: "cup", servingWeight: 99, calories: 115, protein: 9, carbs: 20, fat: 0.4, mealHints: ["lunch", "dinner"]),
        .init(id: "cheddar-cheese", name: "Cheddar cheese", aliases: ["cheese", "cheddar", "cheddar cheese"], servingQuantity: 1, servingUnit: "oz", servingWeight: 28, calories: 113, protein: 7, carbs: 0.4, fat: 9.3, mealHints: ["snack", "lunch"]),
        .init(id: "almonds", name: "Almonds", aliases: ["almonds", "nuts"], servingQuantity: 1, servingUnit: "oz", servingWeight: 28, calories: 164, protein: 6, carbs: 6, fat: 14, mealHints: ["snack"]),
        .init(id: "orange", name: "Orange", aliases: ["orange", "oranges"], servingQuantity: 1, servingUnit: "orange", servingWeight: 131, calories: 62, protein: 1.2, carbs: 15, fat: 0.2, mealHints: ["snack"]),
        .init(id: "blueberries", name: "Blueberries", aliases: ["blueberry", "blueberries"], servingQuantity: 1, servingUnit: "cup", servingWeight: 148, calories: 84, protein: 1.1, carbs: 21, fat: 0.5, mealHints: ["breakfast", "snack"]),
        .init(id: "bagel", name: "Bagel", aliases: ["bagel"], servingQuantity: 1, servingUnit: "bagel", servingWeight: 105, calories: 270, protein: 10, carbs: 53, fat: 1.5, mealHints: ["breakfast"]),
        .init(id: "tortilla-chips", name: "Tortilla chips", aliases: ["tortilla chips", "corn chips", "chips"], servingQuantity: 1, servingUnit: "oz", servingWeight: 28, calories: 140, protein: 2, carbs: 18, fat: 7, mealHints: ["snack"]),
        .init(id: "doritos-cool-ranch", name: "Doritos Cool Ranch Tortilla Chips", aliases: ["doritos", "doritos cool ranch", "cool ranch doritos", "cool ranch chips"], servingQuantity: 1, servingUnit: "oz", servingWeight: 28, calories: 150, protein: 2, carbs: 18, fat: 8, mealHints: ["snack"]),
        .init(id: "potato-chips", name: "Potato chips", aliases: ["potato chips", "chips", "plain chips"], servingQuantity: 1, servingUnit: "oz", servingWeight: 28, calories: 152, protein: 2, carbs: 15, fat: 10, mealHints: ["snack"]),
        .init(id: "granola-bar", name: "Granola bar", aliases: ["granola bar", "protein bar", "snack bar"], servingQuantity: 1, servingUnit: "bar", servingWeight: 40, calories: 170, protein: 4, carbs: 25, fat: 6, mealHints: ["snack", "pre_workout"]),
        .init(id: "cola", name: "Cola", aliases: ["cola", "coke", "pepsi", "soda"], servingQuantity: 12, servingUnit: "fl oz", servingWeight: 355, calories: 140, protein: 0, carbs: 39, fat: 0, mealHints: ["drink"])
    ]

    static func matches(query: String, limit: Int = 8) -> [(StandardFoodItem, Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return foods.compactMap { food -> (StandardFoodItem, Int)? in
            let values = [food.name] + food.aliases
            guard let score = values.compactMap({ fuzzyScore(candidate: $0, query: trimmed) }).max() else { return nil }
            return (food, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    static func item(id: String) -> StandardFoodItem? {
        foods.first { $0.id == id }
    }

    private static func fuzzyScore(candidate: String, query: String) -> Int? {
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

private extension Double {
    var cleanString: String {
        if rounded() == self {
            return String(Int(self))
        }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.1f", self)
    }
}
