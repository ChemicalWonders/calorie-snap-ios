import SwiftUI

/// Review and correct the AI's estimate before saving.
struct AnalysisReviewView: View {
    @Binding var draft: MealDraft
    let saveTitle: String
    let onSave: (MealDraft) -> Void

    var body: some View {
        Form {
            if let image = draft.image {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Meal") {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: $draft.mealType) {
                    ForEach(MealType.allCases) { type in
                        Label(type.title, systemImage: type.icon).tag(type)
                    }
                }
                DatePicker("Time", selection: $draft.date)
            }

            Section("Total") {
                NutritionGrid(totals: draft.totals)
            }

            Section {
                ForEach($draft.items) { $item in
                    NavigationLink {
                        FoodItemEditor(item: $item)
                    } label: {
                        FoodItemRow(item: item)
                    }
                }
                .onDelete { draft.items.remove(atOffsets: $0) }

                Button {
                    draft.items.append(.blank())
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
            } header: {
                Text("Items")
            } footer: {
                Text("Tap an item to correct its name, portion or nutrients. Swipe to remove.")
            }

            Section("Whole meal portion") {
                HStack {
                    ForEach([0.5, 0.75, 1.5, 2.0], id: \.self) { factor in
                        Button(factor.formatted() + "×") {
                            draft.items = draft.items.map { $0.scaled(by: factor) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if let notes = draft.notes, !notes.isEmpty {
                Section("AI notes") {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Text("AI estimates can be off by 20% or more. Adjust anything that looks wrong.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) { onSave(draft) }
                    .bold()
                    .disabled(draft.items.isEmpty)
            }
        }
    }
}

/// Edit one food item's details.
struct FoodItemEditor: View {
    @Binding var item: FoodItem

    var body: some View {
        Form {
            Section("Food") {
                TextField("Name", text: $item.name)
                TextField("Portion", text: $item.portion)
                numberField("Weight", value: $item.grams, unit: "g")
            }

            Section("Nutrition for this portion") {
                numberField("Calories", value: $item.calories, unit: "kcal")
                numberField("Protein", value: $item.protein, unit: "g")
                numberField("Carbs", value: $item.carbs, unit: "g")
                numberField("Fat", value: $item.fat, unit: "g")
                numberField("Fiber", value: $item.fiber, unit: "g")
                numberField("Sugar", value: $item.sugar, unit: "g")
                numberField("Sodium", value: $item.sodiumMg, unit: "mg")
            }

            Section {
                HStack {
                    ForEach([0.5, 0.75, 1.5, 2.0], id: \.self) { factor in
                        Button(factor.formatted() + "×") { item = item.scaled(by: factor) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                }
            } header: {
                Text("Scale portion")
            } footer: {
                Text("Multiplies weight and every nutrient.")
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func numberField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
        }
    }
}
