import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct FoundationFoodNutritionEstimate {
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var sugars: Double
    var sodium: Double
    var potassium: Double
    var servingQuantity: Double
    var servingUnit: String
    var servingWeight: Double
    var notes: String
}
#endif

struct FoodNutritionEstimate: Equatable, Sendable {
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var sugars: Double
    var sodium: Double
    var potassium: Double
    var servingQuantity: Double
    var servingUnit: String
    var servingWeight: Double?
    var notes: String
}

enum FoodNutritionEstimatorError: LocalizedError {
    case unavailable(String)
    case emptyDescription
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "On-device nutrition estimation is unavailable: \(reason)"
        case .emptyDescription:
            "Describe the food before estimating it."
        case .generationFailed:
            "The on-device model couldn't estimate this food. Try again or enter the nutrition manually."
        }
    }
}

enum FoodNutritionEstimator {
    static func estimate(description: String) async throws -> FoodNutritionEstimate {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FoodNutritionEstimatorError.emptyDescription }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general)
            switch model.availability {
            case .available:
                break
            case .unavailable(let reason):
                throw FoodNutritionEstimatorError.unavailable(String(describing: reason))
            @unknown default:
                throw FoodNutritionEstimatorError.unavailable("unknown model state")
            }

            let session = LanguageModelSession(
                model: model,
                instructions: """
                Estimate nutrition for exactly the food and portion the person describes.
                Honor explicit calories, serving sizes, weights, brands, and quantities.
                Keep calories and protein/carbohydrate/fat estimates internally consistent.
                Sodium and potassium are milligrams; all other nutrient amounts are grams.
                Use zero only when a nutrient is genuinely negligible. Do not add foods that were not described.
                """
            )
            let response: LanguageModelSession.Response<FoundationFoodNutritionEstimate>
            do {
                response = try await session.respond(
                    to: "Food description: \(trimmed)",
                    generating: FoundationFoodNutritionEstimate.self,
                    includeSchemaInPrompt: true,
                    options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 420)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FoodNutritionEstimatorError.generationFailed
            }
            let estimate = response.content
            return FoodNutritionEstimate(
                name: estimate.name.trimmingCharacters(in: .whitespacesAndNewlines),
                calories: max(0, estimate.calories),
                protein: max(0, estimate.protein),
                carbs: max(0, estimate.carbs),
                fat: max(0, estimate.fat),
                fiber: max(0, estimate.fiber),
                sugars: max(0, estimate.sugars),
                sodium: max(0, estimate.sodium),
                potassium: max(0, estimate.potassium),
                servingQuantity: max(estimate.servingQuantity, 0.01),
                servingUnit: estimate.servingUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "serving"
                    : estimate.servingUnit,
                servingWeight: estimate.servingWeight > 0 ? estimate.servingWeight : nil,
                notes: estimate.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        #endif

        throw FoodNutritionEstimatorError.unavailable("Foundation Models is not included in this build")
    }
}
