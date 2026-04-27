import SwiftUI

enum ConversationComposerPopupState {
    case none
    case slash([ComposerSlashCommand])
    case file(loading: Bool, error: String?, suggestions: [FileSearchResult])
    case skill(loading: Bool, suggestions: [SkillMetadata])
    case foodSearch(loading: Bool, suggestions: [ComposerFoodSearchResult])
}

struct ComposerFoodSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let insertText: String
    let servingQuantity: Double?
    let servingUnit: String?
    let servingWeight: Double?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let source: String?
    let sourceURL: String?
    let notes: String?
    let confidence: Double?

    init(
        id: String,
        title: String,
        detail: String,
        insertText: String,
        servingQuantity: Double? = nil,
        servingUnit: String? = nil,
        servingWeight: Double? = nil,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        source: String? = nil,
        sourceURL: String? = nil,
        notes: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.insertText = insertText
        self.servingQuantity = servingQuantity
        self.servingUnit = servingUnit
        self.servingWeight = servingWeight
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.source = source
        self.sourceURL = sourceURL
        self.notes = notes
        self.confidence = confidence
    }
}

struct ConversationComposerContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 56

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ConversationComposerPopupOverlayView: View {
    let state: ConversationComposerPopupState
    let onApplySlashSuggestion: (ComposerSlashCommand) -> Void
    let onApplyFileSuggestion: (FileSearchResult) -> Void
    let onApplySkillSuggestion: (SkillMetadata) -> Void
    var bottomInset: CGFloat = 56
    var popupLift: CGFloat = 10
    var onApplyFoodSuggestion: (ComposerFoodSearchResult) -> Void = { _ in }

    var body: some View {
        switch state {
        case .none:
            EmptyView()

        case .slash(let suggestions):
            suggestionPopup {
                let indexedSuggestions = Array(suggestions.enumerated())
                ForEach(indexedSuggestions, id: \.offset) { item in
                    let index = item.offset
                    let command = item.element
                    VStack(spacing: 0) {
                        Button {
                            onApplySlashSuggestion(command)
                        } label: {
                            HStack(spacing: 10) {
                                Text("/\(command.rawValue)")
                                    .macrodexFont(.body)
                                    .foregroundColor(MacrodexTheme.success)
                                Text(command.description)
                                    .macrodexFont(.body)
                                    .foregroundColor(MacrodexTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .background(MacrodexTheme.border)
                            .opacity(index < suggestions.count - 1 ? 1 : 0)
                    }
                }
            }

        case .file(let loading, let error, let suggestions):
            suggestionPopup {
                if loading {
                    popupStateText("Searching files...")
                } else if let error, !error.isEmpty {
                    popupStateText(error, color: .red)
                } else if suggestions.isEmpty {
                    popupStateText("No matches")
                } else {
                    let indexedSuggestions = Array(Array(suggestions.prefix(8)).enumerated())
                    ForEach(indexedSuggestions, id: \.offset) { item in
                        let index = item.offset
                        let suggestion = item.element
                        VStack(spacing: 0) {
                            Button {
                                onApplyFileSuggestion(suggestion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .macrodexFont(.caption)
                                        .foregroundColor(MacrodexTheme.textSecondary)
                                    Text(suggestion.path)
                                        .macrodexFont(.footnote)
                                        .foregroundColor(MacrodexTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .background(MacrodexTheme.border)
                                .opacity(index < indexedSuggestions.count - 1 ? 1 : 0)
                        }
                    }
                }
            }

        case .skill(let loading, let suggestions):
            suggestionPopup {
                if loading && suggestions.isEmpty {
                    popupStateText("Loading skills...")
                } else if suggestions.isEmpty {
                    popupStateText("No skills found")
                } else {
                    let indexedSuggestions = Array(Array(suggestions.prefix(8)).enumerated())
                    ForEach(indexedSuggestions, id: \.offset) { item in
                        let index = item.offset
                        let skill = item.element
                        VStack(spacing: 0) {
                            Button {
                                onApplySkillSuggestion(skill)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("$\(skill.name)")
                                        .macrodexFont(.footnote)
                                        .foregroundColor(MacrodexTheme.success)
                                    Text(skill.description)
                                        .macrodexFont(.footnote)
                                        .foregroundColor(MacrodexTheme.textSecondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .background(MacrodexTheme.border)
                                .opacity(index < indexedSuggestions.count - 1 ? 1 : 0)
                        }
                    }
                }
            }

        case .foodSearch(let loading, let suggestions):
            suggestionPopup(preferredHeight: foodSearchPopupHeight(loading: loading, suggestions: suggestions)) {
                if loading && suggestions.isEmpty {
                    popupStateText("Searching foods...")
                } else if suggestions.isEmpty {
                    popupStateText("No food matches")
                } else {
                    let sortedSuggestions = suggestions.sorted { lhs, rhs in
                        let lhsConfidence = lhs.confidence ?? 0
                        let rhsConfidence = rhs.confidence ?? 0
                        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                    let indexedSuggestions = Array(Array(sortedSuggestions.prefix(20)).enumerated())
                    ForEach(indexedSuggestions, id: \.element.id) { item in
                        let index = item.offset
                        let suggestion = item.element
                        VStack(spacing: 0) {
                            Button {
                                onApplyFoodSuggestion(suggestion)
                            } label: {
                                HStack(spacing: 9) {
                                    FoodIconView(foodName: suggestion.title, size: 34)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.title)
                                            .macrodexFont(.footnote, weight: .semibold)
                                            .foregroundColor(MacrodexTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(suggestion.detail)
                                            .macrodexFont(.caption)
                                            .foregroundColor(MacrodexTheme.textSecondary)
                                            .lineLimit(1)
                                        if let provenance = foodProvenanceLine(for: suggestion) {
                                            Text(provenance)
                                                .macrodexFont(.caption2)
                                                .foregroundColor(MacrodexTheme.textMuted)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .background(MacrodexTheme.border)
                                .opacity(index < indexedSuggestions.count - 1 ? 1 : 0)
                        }
                    }
                }
            }
        }
    }

    private func foodProvenanceLine(for suggestion: ComposerFoodSearchResult) -> String? {
        var parts: [String] = []
        if let confidence = suggestion.confidence {
            parts.append("\(Int((confidence * 100).rounded()))% match")
        }
        if let source = suggestion.source?.nilIfBlank {
            parts.append(source)
        }
        if let notes = suggestion.notes?.nilIfBlank {
            parts.append(notes)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func foodSearchPopupHeight(
        loading: Bool,
        suggestions: [ComposerFoodSearchResult]
    ) -> CGFloat {
        if suggestions.isEmpty {
            return loading ? 42 : 40
        }
        let visibleRows = min(suggestions.count, 20)
        return min(max(CGFloat(visibleRows) * 84, 220), 320)
    }

    @ViewBuilder
    private func popupStateText(_ text: String, color: Color = MacrodexTheme.textSecondary) -> some View {
        Text(text)
            .macrodexFont(.footnote)
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private func suggestionPopup<Content: View>(
        preferredHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: preferredHeight, alignment: .bottom)
        }
        .scrollIndicators(.visible)
        .frame(height: preferredHeight)
        .frame(maxHeight: 320)
        .frame(maxWidth: .infinity)
        .background(MacrodexTheme.surface.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(MacrodexTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .offset(y: -(max(56, bottomInset) + popupLift))
    }
}

enum FoodSearchAIResolver {
    static func results(
        query: String,
        candidates: [ComposerFoodSearchResult],
        timeoutSeconds: Double = 10
    ) async -> [ComposerFoodSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedCandidates = sortedByConfidence(candidates)
        guard trimmed.count >= 2 else { return sortedCandidates }

        if isHighConfidenceLocalMatch(query: trimmed, candidates: sortedCandidates),
           !shouldPreferWebForProductSearch(query: trimmed, candidates: sortedCandidates) {
            return Array(sortedCandidates.prefix(20))
        }

        let needsWeb = candidates.isEmpty
            || shouldEscalateBeyondLocal(query: trimmed, candidates: sortedCandidates)
            || shouldPreferWebForProductSearch(query: trimmed, candidates: sortedCandidates)
        let webResults: [ComposerFoodSearchResult]
        if needsWeb {
            webResults = await FoodSearchWebFallback.results(query: trimmed)
        } else {
            webResults = []
        }

        let fallback = fallbackResults(localResults: sortedCandidates, webResults: webResults)
        let aiCandidates = aiCandidates(
            query: trimmed,
            localResults: sortedCandidates,
            fallbackResults: fallback,
            webResults: webResults
        )
        let suppressWeakFallbackOnTimeout = aiCandidates.isEmpty
            && shouldForceGeneratedWebSuggestion(query: trimmed, candidates: sortedCandidates)
        if fallback.isEmpty {
            let webResults = await FoodSearchWebFallback.results(query: trimmed)
            if !webResults.isEmpty {
                return sortedByConfidence(webResults)
            }
        }

        return await withCheckedContinuation { continuation in
            let gate = FoodSearchTimeoutGate()
            let worker = Task {
                let result = (try? await PiAgentRuntimeBackend.shared.rerankFoodSearch(
                    query: trimmed,
                    candidates: aiCandidates
                )) ?? aiCandidates
                await gate.resume(
                    continuation,
                    returning: mergedResults(
                        primary: result,
                        secondary: suppressWeakFallbackOnTimeout ? [] : fallback
                    )
                )
            }

            Task {
                let nanoseconds = UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                worker.cancel()
                await gate.resume(
                    continuation,
                    returning: suppressWeakFallbackOnTimeout ? [] : sortedByConfidence(fallback)
                )
            }
        }
    }

    private static func aiCandidates(
        query: String,
        localResults: [ComposerFoodSearchResult],
        fallbackResults: [ComposerFoodSearchResult],
        webResults: [ComposerFoodSearchResult]
    ) -> [ComposerFoodSearchResult] {
        let forceGeneratedWebSuggestion = shouldForceGeneratedWebSuggestion(
            query: query,
            candidates: localResults
        )
        let hasOnlyWeakWebResults = !webResults.isEmpty
            && webResults.allSatisfy { ($0.confidence ?? 0) < 0.85 }
        guard forceGeneratedWebSuggestion,
              webResults.isEmpty || hasOnlyWeakWebResults
        else {
            return fallbackResults
        }

        return fallbackResults.filter { result in
            let confidence = result.confidence ?? 0
            guard confidence >= 0.85 else { return false }
            return result.source != "Foundation food"
                && result.source != "USDA Foundation"
        }
    }

    private static func sortedByConfidence(_ results: [ComposerFoodSearchResult]) -> [ComposerFoodSearchResult] {
        results.sorted { lhs, rhs in
            let lhsConfidence = lhs.confidence ?? 0
            let rhsConfidence = rhs.confidence ?? 0
            if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func mergedResults(
        primary: [ComposerFoodSearchResult],
        secondary: [ComposerFoodSearchResult]
    ) -> [ComposerFoodSearchResult] {
        var seen = Set<String>()
        var merged: [ComposerFoodSearchResult] = []
        for result in primary + secondary {
            let key = result.title.normalizedFoodSearchKey
            guard seen.insert(key).inserted else { continue }
            merged.append(result)
        }
        return sortedByConfidence(merged)
    }

    private static func fallbackResults(
        localResults: [ComposerFoodSearchResult],
        webResults: [ComposerFoodSearchResult]
    ) -> [ComposerFoodSearchResult] {
        guard !webResults.isEmpty else { return localResults }
        let bestLocalConfidence = localResults.first?.confidence ?? 0
        if bestLocalConfidence < 0.85 {
            let strongLocalResults = localResults.filter { result in
                guard (result.confidence ?? 0) >= 0.85 else { return false }
                return result.source != "Foundation food"
            }
            return mergedResults(primary: webResults, secondary: strongLocalResults)
        }
        return mergedResults(primary: localResults, secondary: webResults)
    }

    private static func isHighConfidenceLocalMatch(
        query: String,
        candidates: [ComposerFoodSearchResult]
    ) -> Bool {
        guard let best = candidates.first,
              let confidence = best.confidence,
              confidence >= 0.94
        else { return false }
        let queryTokens = query.foodSearchTokens
        guard !queryTokens.isEmpty else { return true }
        let titleTokens = best.title.foodSearchTokens
        return queryTokens.allSatisfy { titleTokens.contains($0) }
    }

    private static func shouldEscalateBeyondLocal(
        query: String,
        candidates: [ComposerFoodSearchResult]
    ) -> Bool {
        guard let best = candidates.first else { return true }
        let queryTokens = query.foodSearchTokens
        let titleTokens = best.title.foodSearchTokens
        let missingTokenCount = queryTokens.filter { !titleTokens.contains($0) }.count
        if missingTokenCount >= 1, queryTokens.count >= 3 { return true }
        return (best.confidence ?? 0) < 0.88
    }

    private static func shouldPreferWebForProductSearch(
        query: String,
        candidates: [ComposerFoodSearchResult]
    ) -> Bool {
        guard let best = candidates.first else { return true }
        let source = best.source ?? ""
        guard source == "Foundation food" || source == "USDA Foundation" else {
            return false
        }

        let queryTokens = query.foodSearchTokens
        guard queryTokens.count >= 2, queryTokens.count <= 8 else { return false }
        let hasProductSignal = query.contains("'")
            || query.contains("’")
            || query.contains("%")
            || queryTokens.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        let confidence = best.confidence ?? 0
        return hasProductSignal || confidence < 0.94
    }

    private static func shouldForceGeneratedWebSuggestion(
        query: String,
        candidates: [ComposerFoodSearchResult]
    ) -> Bool {
        guard query.count >= 3 else { return false }
        guard let best = candidates.first else { return true }
        let bestConfidence = best.confidence ?? 0
        let source = best.source ?? ""
        if bestConfidence < 0.85 { return true }
        if source == "Foundation food" || source == "USDA Foundation" {
            let queryTokens = query.foodSearchTokens
            let titleTokens = best.title.foodSearchTokens
            return queryTokens.count >= 3 && queryTokens.contains { !titleTokens.contains($0) }
        }
        return false
    }
}

private enum FoodSearchWebFallback {
    static func results(query: String) async -> [ComposerFoodSearchResult] {
        async let openFoodFacts = openFoodFactsResults(query: query)
        async let usda = usdaResults(query: query)
        let webResults = await openFoodFacts
        let usdaResults = await usda
        if webResults.isEmpty {
            return sortedByConfidence(usdaResults)
        }
        return mergedResults(primary: webResults, secondary: usdaResults.filter { result in
            result.source != "USDA Foundation"
        })
    }

    private static func usdaResults(query: String) async -> [ComposerFoodSearchResult] {
        guard var components = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: "DEMO_KEY"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "pageSize", value: "8")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let payload = try JSONDecoder().decode(USDAFoodSearchResponse.self, from: data)
            return payload.foods.prefix(8).compactMap { usdaResult(from: $0, query: query) }
        } catch {
            return []
        }
    }

    private static func openFoodFactsResults(query: String) async -> [ComposerFoodSearchResult] {
        guard var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "8")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Macrodex iOS food search", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let payload = try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data)
            return payload.products.prefix(8).compactMap { result(from: $0, query: query) }
        } catch {
            return []
        }
    }

    private static func usdaResult(from food: USDAFood, query: String) -> ComposerFoodSearchResult? {
        let servingSize = food.servingSize ?? 100
        let rawServingUnit = food.servingSizeUnit?.lowercased() ?? "g"
        let isGramServing = rawServingUnit == "g"
            || rawServingUnit == "grm"
            || rawServingUnit.contains("gram")
        let servingUnit = isGramServing ? "g" : rawServingUnit
        let scale = isGramServing ? servingSize / 100 : 1
        guard let calories100g = food.nutrient(named: "Energy", number: "208") else { return nil }
        let calories = calories100g * scale
        guard calories > 0 else { return nil }

        let description = food.description
            .lowercased()
            .capitalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = (food.brandName ?? food.brandOwner)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let brand, !brand.isEmpty, !description.localizedCaseInsensitiveContains(brand) {
            title = "\(brand) \(description)"
        } else {
            title = description
        }

        let detailServing = food.householdServingFullText?.nilIfBlank
            ?? "\(servingSize.cleanString) \(servingUnit)"
        let sourceNote = [brand, food.dataType]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: " · ")
        let dataType = food.dataType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFoundation = dataType?.localizedCaseInsensitiveContains("foundation") == true
        let source = isFoundation ? "USDA Foundation" : "USDA FoodData Central"
        let confidence = webConfidence(query: query, title: title, notes: sourceNote, base: isFoundation ? 0.62 : 0.7)
        return ComposerFoodSearchResult(
            id: "usda-\(food.fdcId)",
            title: title,
            detail: "\(calories.cleanString) kcal · \(detailServing)",
            insertText: title,
            servingQuantity: servingSize,
            servingUnit: servingUnit,
            servingWeight: isGramServing ? servingSize : nil,
            calories: calories,
            protein: food.nutrient(named: "Protein", number: "203").map { $0 * scale },
            carbs: food.nutrient(named: "Carbohydrate", number: "205").map { $0 * scale },
            fat: food.nutrient(named: "Total lipid", number: "204").map { $0 * scale },
            source: source,
            sourceURL: "https://fdc.nal.usda.gov/fdc-app.html#/food-details/\(food.fdcId)/nutrients",
            notes: sourceNote.nilIfBlank,
            confidence: confidence
        )
    }

    private static func result(from product: OpenFoodFactsProduct, query: String) -> ComposerFoodSearchResult? {
        let title = [product.brands, product.productName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = product.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = title.isEmpty ? fallbackTitle : title
        guard !resolvedTitle.isEmpty else { return nil }

        let serving = parseServing(product.servingSize)
        let calories = product.nutriments?.energyKcalServing
            ?? product.nutriments?.energyKcal100g
        guard let calories, calories > 0 else { return nil }

        let detailServing = product.servingSize?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "100 g"
        let productCode = product.code?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let notes = product.brands?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        return ComposerFoodSearchResult(
            id: "openfoodfacts-\(product.code ?? resolvedTitle.lowercased())",
            title: resolvedTitle,
            detail: "\(calories.cleanString) kcal · \(detailServing)",
            insertText: resolvedTitle,
            servingQuantity: serving?.quantity,
            servingUnit: serving?.unit,
            servingWeight: serving?.grams,
            calories: calories,
            protein: product.nutriments?.proteinsServing ?? product.nutriments?.proteins100g,
            carbs: product.nutriments?.carbohydratesServing ?? product.nutriments?.carbohydrates100g,
            fat: product.nutriments?.fatServing ?? product.nutriments?.fat100g,
            source: "Open Food Facts",
            sourceURL: productCode.map { "https://world.openfoodfacts.org/product/\($0)" },
            notes: notes,
            confidence: webConfidence(query: query, title: resolvedTitle, notes: notes, base: 0.76)
        )
    }

    private static func sortedByConfidence(_ results: [ComposerFoodSearchResult]) -> [ComposerFoodSearchResult] {
        results.sorted { lhs, rhs in
            let lhsConfidence = lhs.confidence ?? 0
            let rhsConfidence = rhs.confidence ?? 0
            if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func mergedResults(
        primary: [ComposerFoodSearchResult],
        secondary: [ComposerFoodSearchResult]
    ) -> [ComposerFoodSearchResult] {
        var seen = Set<String>()
        var merged: [ComposerFoodSearchResult] = []
        for result in primary + secondary {
            let key = result.title.normalizedFoodSearchKey
            guard seen.insert(key).inserted else { continue }
            merged.append(result)
        }
        return sortedByConfidence(merged)
    }

    private static func webConfidence(
        query: String,
        title: String,
        notes: String?,
        base: Double
    ) -> Double {
        let queryTokens = query.foodSearchTokens
        guard !queryTokens.isEmpty else { return base }
        let searchableTokens = "\(title) \(notes ?? "")".foodSearchTokens
        let matchedCount = queryTokens.filter { queryToken in
            searchableTokens.contains { $0.foodSearchTokenMatches(queryToken) }
        }.count
        let ratio = Double(matchedCount) / Double(queryTokens.count)
        let exactishBonus = ratio >= 0.99 ? 0.08 : 0
        return min(max(base + ratio * 0.16 + exactishBonus, base), 0.96)
    }

    private static func parseServing(_ value: String?) -> (quantity: Double, unit: String, grams: Double?)? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let parts = raw
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(separator: " ")
        guard let firstNumber = parts.compactMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }).first else {
            return nil
        }
        let lower = raw.lowercased()
        let grams = lower.contains("g") ? firstNumber : nil
        let unit: String
        if lower.contains("ml") {
            unit = "ml"
        } else if lower.contains("oz") {
            unit = "oz"
        } else if lower.contains("g") {
            unit = "g"
        } else {
            unit = "serving"
        }
        return (firstNumber, unit, grams)
    }

    private struct OpenFoodFactsSearchResponse: Decodable {
        let products: [OpenFoodFactsProduct]
    }

    private struct USDAFoodSearchResponse: Decodable {
        let foods: [USDAFood]
    }

    private struct USDAFood: Decodable {
        let fdcId: Int
        let description: String
        let brandName: String?
        let brandOwner: String?
        let servingSize: Double?
        let servingSizeUnit: String?
        let householdServingFullText: String?
        let dataType: String?
        let score: Double?
        let foodNutrients: [USDANutrient]

        func nutrient(named name: String, number: String) -> Double? {
            foodNutrients.first {
                $0.nutrientNumber == number || $0.nutrientName.localizedCaseInsensitiveContains(name)
            }?.value
        }
    }

    private struct USDANutrient: Decodable {
        let nutrientName: String
        let nutrientNumber: String?
        let value: Double
    }

    private struct OpenFoodFactsProduct: Decodable {
        let code: String?
        let productName: String?
        let brands: String?
        let servingSize: String?
        let nutriments: OpenFoodFactsNutriments?

        enum CodingKeys: String, CodingKey {
            case code
            case productName = "product_name"
            case brands
            case servingSize = "serving_size"
            case nutriments
        }
    }

    private struct OpenFoodFactsNutriments: Decodable {
        let energyKcalServing: Double?
        let energyKcal100g: Double?
        let proteinsServing: Double?
        let proteins100g: Double?
        let carbohydratesServing: Double?
        let carbohydrates100g: Double?
        let fatServing: Double?
        let fat100g: Double?

        enum CodingKeys: String, CodingKey {
            case energyKcalServing = "energy-kcal_serving"
            case energyKcal100g = "energy-kcal_100g"
            case proteinsServing = "proteins_serving"
            case proteins100g = "proteins_100g"
            case carbohydratesServing = "carbohydrates_serving"
            case carbohydrates100g = "carbohydrates_100g"
            case fatServing = "fat_serving"
            case fat100g = "fat_100g"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            energyKcalServing = Self.decodeDouble(.energyKcalServing, from: container)
            energyKcal100g = Self.decodeDouble(.energyKcal100g, from: container)
            proteinsServing = Self.decodeDouble(.proteinsServing, from: container)
            proteins100g = Self.decodeDouble(.proteins100g, from: container)
            carbohydratesServing = Self.decodeDouble(.carbohydratesServing, from: container)
            carbohydrates100g = Self.decodeDouble(.carbohydrates100g, from: container)
            fatServing = Self.decodeDouble(.fatServing, from: container)
            fat100g = Self.decodeDouble(.fat100g, from: container)
        }

        private static func decodeDouble(
            _ key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }
            if let string = try? container.decode(String.self, forKey: key) {
                return Double(string.replacingOccurrences(of: ",", with: "."))
            }
            return nil
        }
    }
}

private actor FoodSearchTimeoutGate {
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<[ComposerFoodSearchResult], Never>,
        returning value: [ComposerFoodSearchResult]
    ) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedFoodSearchKey: String {
        foodSearchTokens.joined(separator: " ")
    }

    var foodSearchTokens: [String] {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func foodSearchTokenMatches(_ other: String) -> Bool {
        let lhs = foodSearchComparableToken
        let rhs = other.foodSearchComparableToken
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private var foodSearchComparableToken: String {
        var token = lowercased()
        if token.count > 3, token.hasSuffix("s") {
            token.removeLast()
        }
        return token
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
