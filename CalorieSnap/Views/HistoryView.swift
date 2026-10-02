import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MealEntry.date, order: .reverse) private var meals: [MealEntry]
    @AppStorage(SettingsKey.dailyCalorieGoal) private var goal = 2000.0

    private struct DayGroup: Identifiable {
        let day: Date
        let meals: [MealEntry]
        var id: Date { day }
        var calories: Double { NutritionTotals(meals: meals).calories }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: meals) { calendar.startOfDay(for: $0.date) }
        return grouped.map { DayGroup(day: $0.key, meals: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private struct DayTotal: Identifiable {
        let day: Date
        let calories: Double
        var id: Date { day }
    }

    /// Calories for each of the last 7 days (including days with nothing logged).
    private var lastSevenDays: [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let byDay = Dictionary(uniqueKeysWithValues: groups.map { ($0.day, $0.calories) })
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayTotal(day: day, calories: byDay[day] ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Last 7 days") {
                    Chart {
                        ForEach(lastSevenDays) { entry in
                            BarMark(x: .value("Day", entry.day, unit: .day),
                                    y: .value("kcal", entry.calories))
                                .foregroundStyle(entry.calories > goal ? Color.orange : Color.accentColor)
                                .cornerRadius(4)
                        }
                        RuleMark(y: .value("Goal", goal))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .leading) {
                                Text("Goal \(goal.whole)").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                        }
                    }
                    .frame(height: 180)
                    .padding(.vertical, 8)
                }

                if groups.isEmpty {
                    ContentUnavailableView("No meals yet", systemImage: "calendar",
                                           description: Text("Meals you log will appear here."))
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.meals) { meal in
                            NavigationLink(value: meal) { MealRow(meal: meal) }
                        }
                        .onDelete { offsets in
                            for index in offsets { MealActions.delete(group.meals[index], context: context) }
                        }
                    } header: {
                        HStack {
                            Text(group.day.formatted(.dateTime.weekday(.wide).month().day()))
                            Spacer()
                            Text("\(group.calories.whole) kcal").monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: MealEntry.self) { MealDetailView(meal: $0) }
        }
    }
}
