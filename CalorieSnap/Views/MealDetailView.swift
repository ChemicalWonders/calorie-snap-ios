import SwiftUI
import SwiftData

struct MealDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let meal: MealEntry

    @State private var editDraft: MealDraft?
    @State private var confirmDelete = false

    var body: some View {
        List {
            if let data = meal.photoData, let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                LabeledContent("Type") { Label(meal.mealType.title, systemImage: meal.mealType.icon) }
                LabeledContent("Time", value: meal.date.formatted(date: .abbreviated, time: .shortened))
                if meal.healthKitCorrelationID != nil {
                    Label("Saved to Apple Health", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                        .font(.footnote)
                }
            }

            Section("Total") {
                NutritionGrid(totals: meal.totals)
            }

            Section("Items") {
                ForEach(meal.items) { FoodItemRow(item: $0) }
            }

            if let notes = meal.notes, !notes.isEmpty {
                Section("AI notes") {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete Meal", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(meal.name.isEmpty ? meal.mealType.title : meal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") {
                editDraft = MealDraft(name: meal.name, mealType: meal.mealType, date: meal.date,
                                      items: meal.items, notes: meal.notes,
                                      image: meal.photoData.flatMap(UIImage.init(data:)))
            }
        }
        .sheet(isPresented: Binding(get: { editDraft != nil }, set: { if !$0 { editDraft = nil } })) {
            if let binding = Binding($editDraft) {
                NavigationStack {
                    AnalysisReviewView(draft: binding, saveTitle: "Save") { updated in
                        apply(updated)
                        editDraft = nil
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editDraft = nil }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                // Delete after the pop animation so this view never renders a deleted model.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    MealActions.delete(meal, context: context)
                }
            }
        } message: {
            Text("It will also be removed from Apple Health.")
        }
    }

    private func apply(_ draft: MealDraft) {
        meal.name = draft.name
        meal.mealType = draft.mealType
        meal.date = draft.date
        meal.items = draft.items
        try? context.save()
        Task { await MealActions.syncToHealth(meal, context: context) }
    }
}
