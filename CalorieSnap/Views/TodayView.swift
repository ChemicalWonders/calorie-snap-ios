import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MealEntry.date, order: .reverse) private var meals: [MealEntry]
    @AppStorage(SettingsKey.dailyCalorieGoal) private var goal = 2000.0
    @State private var showCapture = false

    private var todaysMeals: [MealEntry] {
        meals.filter { Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DailySummaryCard(totals: NutritionTotals(meals: todaysMeals), goal: goal)
                }

                Section("Meals") {
                    if todaysMeals.isEmpty {
                        ContentUnavailableView("Nothing logged yet",
                                               systemImage: "camera.macro",
                                               description: Text("Snap a photo of what you're eating to log it."))
                    } else {
                        ForEach(todaysMeals) { meal in
                            NavigationLink(value: meal) { MealRow(meal: meal) }
                        }
                        .onDelete { offsets in
                            for index in offsets { MealActions.delete(todaysMeals[index], context: context) }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .navigationDestination(for: MealEntry.self) { MealDetailView(meal: $0) }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showCapture = true
                } label: {
                    Label("Snap a Meal", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .sheet(isPresented: $showCapture) {
                CaptureFlowView()
            }
        }
    }
}
