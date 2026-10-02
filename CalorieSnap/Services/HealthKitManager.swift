import Foundation
import HealthKit
import SwiftData

/// Writes logged meals to Apple Health as `HKCorrelation` food entries.
@MainActor
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    private static let units: [HKQuantityTypeIdentifier: HKUnit] = [
        .dietaryEnergyConsumed: .kilocalorie(),
        .dietaryProtein: .gram(),
        .dietaryCarbohydrates: .gram(),
        .dietaryFatTotal: .gram(),
        .dietaryFiber: .gram(),
        .dietarySugar: .gram(),
        .dietarySodium: .gramUnit(with: .milli)
    ]

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        let types = Set(Self.units.keys.map { HKQuantityType($0) as HKSampleType })
        try await store.requestAuthorization(toShare: types, read: [])
    }

    /// Saves the meal and returns the correlation UUID.
    func save(_ meal: MealEntry) async throws -> UUID {
        let totals = meal.totals
        let values: [(HKQuantityTypeIdentifier, Double)] = [
            (.dietaryEnergyConsumed, totals.calories),
            (.dietaryProtein, totals.protein),
            (.dietaryCarbohydrates, totals.carbs),
            (.dietaryFatTotal, totals.fat),
            (.dietaryFiber, totals.fiber),
            (.dietarySugar, totals.sugar),
            (.dietarySodium, totals.sodiumMg)
        ]
        let metadata: [String: Any] = [HKMetadataKeyFoodType: meal.name.isEmpty ? meal.mealType.title : meal.name]

        var samples = Set<HKSample>()
        for (identifier, value) in values where value > 0 || identifier == .dietaryEnergyConsumed {
            guard let unit = Self.units[identifier] else { continue }
            samples.insert(HKQuantitySample(type: HKQuantityType(identifier),
                                            quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: meal.date, end: meal.date, metadata: metadata))
        }

        let correlation = HKCorrelation(type: HKCorrelationType(.food),
                                        start: meal.date, end: meal.date,
                                        objects: samples, metadata: metadata)
        try await store.save(correlation)
        return correlation.uuid
    }

    func delete(correlationID: UUID) async throws {
        guard isAvailable else { return }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.correlation(type: HKCorrelationType(.food),
                                      predicate: HKQuery.predicateForObject(with: correlationID))],
            sortDescriptors: []
        )
        let matches = try await descriptor.result(for: store)
        for correlation in matches {
            var objects: [HKObject] = correlation.objects.map { $0 as HKObject }
            objects.append(correlation)
            try await store.delete(objects)
        }
    }
}

/// Shared save / update / delete logic that keeps SwiftData and Apple Health in step.
@MainActor
enum MealActions {
    static var healthSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.healthSyncEnabled)
    }

    /// Writes (or re-writes) the meal to Apple Health if sync is on.
    static func syncToHealth(_ meal: MealEntry, context: ModelContext) async {
        FriendsSync.shared.requestSync(context.container)
        guard healthSyncEnabled, HealthKitManager.shared.isAvailable else { return }
        do {
            try await HealthKitManager.shared.requestAuthorization()
            if let old = meal.healthKitCorrelationID {
                try? await HealthKitManager.shared.delete(correlationID: old)
                meal.healthKitCorrelationID = nil
            }
            meal.healthKitCorrelationID = try await HealthKitManager.shared.save(meal)
            try? context.save()
        } catch {
            print("HealthKit sync failed: \(error)")
        }
    }

    static func delete(_ meal: MealEntry, context: ModelContext) {
        let healthID = meal.healthKitCorrelationID
        context.delete(meal)
        try? context.save()
        FriendsSync.shared.requestSync(context.container)
        if let healthID {
            Task { try? await HealthKitManager.shared.delete(correlationID: healthID) }
        }
    }
}
