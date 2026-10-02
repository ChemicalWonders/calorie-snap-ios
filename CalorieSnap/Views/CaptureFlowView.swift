import SwiftUI
import SwiftData
import PhotosUI

/// Editable, not-yet-saved meal (used for new meals and for editing existing ones).
struct MealDraft {
    var name: String
    var mealType: MealType
    var date: Date
    var items: [FoodItem]
    var notes: String?
    var image: UIImage?

    var totals: NutritionTotals { NutritionTotals(items: items) }
}

/// Sheet: pick/take a photo → analyze with Gemini → review & edit → save.
struct CaptureFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.geminiModel) private var model = SettingsKey.defaultGeminiModel
    @AppStorage(SettingsKey.fallbackGeminiModel) private var fallbackModel = SettingsKey.defaultFallbackModel
    @State private var statusMessage: String?

    @State private var image: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var hint = ""
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var draft: MealDraft?

    var body: some View {
        NavigationStack {
            Group {
                if let binding = Binding($draft) {
                    AnalysisReviewView(draft: binding, saveTitle: "Log Meal") { finished in
                        save(finished)
                    }
                } else {
                    pickerForm
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isAnalyzing || draft != nil)
    }

    // MARK: Step 1 – choose a photo

    private var pickerForm: some View {
        Form {
            Section {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                }

                if CameraPicker.isAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label(image == nil ? "Take Photo" : "Retake Photo", systemImage: "camera")
                    }
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
            }

            if image != nil {
                Section {
                    TextField("Optional: e.g. \"large bowl\", \"made with olive oil\"", text: $hint, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Anything the AI should know?")
                }

                Section {
                    Button {
                        Task { await analyze() }
                    } label: {
                        HStack {
                            Spacer()
                            if isAnalyzing {
                                ProgressView().padding(.trailing, 6)
                                Text(statusMessage ?? "Analyzing…")
                            } else {
                                Label("Analyze Nutrition", systemImage: "sparkles")
                            }
                            Spacer()
                        }
                        .font(.headline)
                    }
                    .disabled(isAnalyzing)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Enter a meal manually") {
                    draft = MealDraft(name: "", mealType: .suggested(for: .now), date: .now,
                                      items: [.blank()], notes: nil, image: image)
                }
            }
        }
        .navigationTitle("Log a Meal")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { picked in
                image = picked
                errorMessage = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let picked = UIImage(data: data) {
                    image = picked
                    errorMessage = nil
                } else {
                    errorMessage = "Couldn't load that photo."
                }
            }
        }
    }

    // MARK: Step 2 – analyze

    private func analyze() async {
        guard let image else { return }
        guard let apiKey = KeychainHelper.geminiAPIKey else {
            errorMessage = GeminiError.missingAPIKey.localizedDescription
            return
        }
        errorMessage = nil
        isAnalyzing = true
        statusMessage = nil
        defer { isAnalyzing = false; statusMessage = nil }

        do {
            let service = GeminiService(apiKey: apiKey, model: model, fallbackModel: fallbackModel,
                                        onStatus: { statusMessage = $0 })
            let result = try await service.analyze(image: image, hint: hint)
            guard !result.items.isEmpty else {
                let reason = result.notes?.isEmpty == false ? result.notes! : "No food was detected in this photo."
                errorMessage = reason
                return
            }
            draft = MealDraft(name: result.mealName,
                              mealType: .suggested(for: .now),
                              date: .now,
                              items: result.items.map(\.asFoodItem),
                              notes: result.notes,
                              image: image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Step 3 – save

    private func save(_ draft: MealDraft) {
        let meal = MealEntry(date: draft.date,
                             name: draft.name,
                             mealType: draft.mealType,
                             photoData: draft.image?.storageJPEG,
                             items: draft.items,
                             notes: draft.notes)
        context.insert(meal)
        try? context.save()
        Task { await MealActions.syncToHealth(meal, context: context) }
        dismiss()
    }
}
