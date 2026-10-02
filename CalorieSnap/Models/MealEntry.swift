import Foundation
import SwiftData

/// One food or drink within a meal. Stored inline in `MealEntry.items`.
struct FoodItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var portion: String
    var grams: Double
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double = 0
    var sugar: Double = 0
    var sodiumMg: Double = 0
    /// 0...1 confidence reported by the AI (nil for manually entered items).
    var confidence: Double?

    static func blank() -> FoodItem {
        FoodItem(name: "New item", portion: "1 serving", grams: 0, calories: 0, protein: 0, carbs: 0, fat: 0)
    }

    /// Returns a copy with every quantity multiplied by `factor` (e.g. 0.5 for half the portion).
    func scaled(by factor: Double) -> FoodItem {
        var copy = self
        copy.grams *= factor
        copy.calories *= factor
        copy.protein *= factor
        copy.carbs *= factor
        copy.fat *= factor
        copy.fiber *= factor
        copy.sugar *= factor
        copy.sodiumMg *= factor
        return copy
    }
}

enum MealType: String, CaseIterable, Codable, Identifiable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "carrot"
        }
    }

    /// Guess the meal type from the time of day.
    static func suggested(for date: Date) -> MealType {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 4..<11: return .breakfast
        case 11..<15: return .lunch
        case 17..<22: return .dinner
        default: return .snack
        }
    }
}

struct NutritionTotals {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sugar: Double = 0
    var sodiumMg: Double = 0

    init() {}

    init(items: [FoodItem]) {
        for item in items { add(item) }
    }

    init(meals: [MealEntry]) {
        for meal in meals { for item in meal.items { add(item) } }
    }

    private mutating func add(_ item: FoodItem) {
        calories += item.calories
        protein += item.protein
        carbs += item.carbs
        fat += item.fat
        fiber += item.fiber
        sugar += item.sugar
        sodiumMg += item.sodiumMg
    }
}

@Model
final class MealEntry {
    var id: UUID = UUID()
    var date: Date = Date.now
    var name: String = ""
    var mealTypeRaw: String = MealType.snack.rawValue
    @Attribute(.externalStorage) var photoData: Data?
    var items: [FoodItem] = []
    var notes: String?
    /// UUID of the HKCorrelation saved to Apple Health, so it can be removed/updated later.
    var healthKitCorrelationID: UUID?

    init(date: Date, name: String, mealType: MealType, photoData: Data?, items: [FoodItem], notes: String?) {
        self.date = date
        self.name = name
        self.mealTypeRaw = mealType.rawValue
        self.photoData = photoData
        self.items = items
        self.notes = notes
    }

    var mealType: MealType {
        get { MealType(rawValue: mealTypeRaw) ?? .snack }
        set { mealTypeRaw = newValue.rawValue }
    }

    var totals: NutritionTotals { NutritionTotals(items: items) }
}

extension Double {
    /// Rounded whole-number string, e.g. "523".
    var whole: String { String(Int(self.rounded())) }
}
