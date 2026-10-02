import SwiftUI
import UIKit

/// Ring + macro bars summarizing a day's intake against the calorie goal.
struct DailySummaryCard: View {
    let totals: NutritionTotals
    let goal: Double

    private var progress: Double { goal > 0 ? min(totals.calories / goal, 1) : 0 }
    private var remaining: Double { goal - totals.calories }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(remaining >= 0 ? Color.accentColor : .orange,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: progress)
                VStack(spacing: 0) {
                    Text(totals.calories.whole)
                        .font(.title.bold())
                        .monospacedDigit()
                    Text("of \(goal.whole) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 130)

            VStack(alignment: .leading, spacing: 10) {
                Text(remaining >= 0 ? "\(remaining.whole) kcal left" : "\((-remaining).whole) kcal over")
                    .font(.headline)
                    .foregroundStyle(remaining >= 0 ? Color.primary : Color.orange)
                MacroBar(label: "Protein", grams: totals.protein, color: .blue)
                MacroBar(label: "Carbs", grams: totals.carbs, color: .green)
                MacroBar(label: "Fat", grams: totals.fat, color: .pink)
            }
        }
        .padding(.vertical, 8)
    }
}

struct MacroBar: View {
    let label: String
    let grams: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text("\(grams.whole) g").font(.subheadline.monospacedDigit())
        }
    }
}

/// Compact grid of all nutrients.
struct NutritionGrid: View {
    let totals: NutritionTotals

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Calories", "\(totals.calories.whole) kcal")
            row("Protein", "\(totals.protein.whole) g")
            row("Carbs", "\(totals.carbs.whole) g")
            row("Fat", "\(totals.fat.whole) g")
            row("Fiber", "\(totals.fiber.whole) g")
            row("Sugar", "\(totals.sugar.whole) g")
            row("Sodium", "\(totals.sodiumMg.whole) mg")
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}

struct MealThumbnail: View {
    let data: Data?
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MealRow: View {
    let meal: MealEntry

    var body: some View {
        HStack(spacing: 12) {
            MealThumbnail(data: meal.photoData)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name.isEmpty ? meal.mealType.title : meal.name)
                    .font(.headline)
                    .lineLimit(1)
                Label("\(meal.mealType.title) · \(meal.date.formatted(date: .omitted, time: .shortened))",
                      systemImage: meal.mealType.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(meal.totals.calories.whole).font(.headline.monospacedDigit())
                Text("kcal").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct FoodItemRow: View {
    let item: FoodItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body)
                Text("\(item.portion) · P \(item.protein.whole)g · C \(item.carbs.whole)g · F \(item.fat.whole)g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let confidence = item.confidence, confidence < 0.6 {
                    Label("Low confidence — double-check", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text("\(item.calories.whole) kcal").font(.subheadline.monospacedDigit())
        }
    }
}

/// UIKit camera wrapper (PhotosPicker covers the photo library).
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
