import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.geminiModel) private var model = SettingsKey.defaultGeminiModel
    @AppStorage(SettingsKey.fallbackGeminiModel) private var fallbackModel = SettingsKey.defaultFallbackModel
    @AppStorage(SettingsKey.dailyCalorieGoal) private var goal = 2000.0
    @AppStorage(SettingsKey.healthSyncEnabled) private var healthSync = false

    @State private var apiKeyInput = ""
    @State private var hasKey = KeychainHelper.geminiAPIKey != nil
    @State private var healthError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Label(hasKey ? "Key saved" : "No key",
                              systemImage: hasKey ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(hasKey ? Color.green : Color.secondary)
                    }
                    SecureField(hasKey ? "Replace API key" : "Paste API key", text: $apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save Key") {
                            KeychainHelper.save(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                                account: KeychainHelper.geminiAPIKeyAccount)
                            apiKeyInput = ""
                            hasKey = KeychainHelper.geminiAPIKey != nil
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        if hasKey {
                            Button("Remove", role: .destructive) {
                                KeychainHelper.save("", account: KeychainHelper.geminiAPIKeyAccount)
                                hasKey = false
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    LabeledContent("Model") {
                        TextField("Model", text: $model)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Fallback") {
                        TextField("Optional", text: $fallbackModel)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Link("Get a key at Google AI Studio",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                } header: {
                    Text("Google Gemini")
                } footer: {
                    Text("Your key is stored in the iOS Keychain on this device and sent only to Google's Gemini API. If the main model is overloaded, the app retries and then uses the fallback model.")
                }

                Section("Daily goal") {
                    Stepper(value: $goal, in: 1000...5000, step: 50) {
                        LabeledContent("Calories", value: "\(goal.whole) kcal")
                    }
                }

                Section {
                    Toggle("Save meals to Apple Health", isOn: $healthSync)
                        .onChange(of: healthSync) { _, enabled in
                            guard enabled else { return }
                            Task { await enableHealth() }
                        }
                    if let healthError {
                        Text(healthError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Writes calories, protein, carbs, fat, fiber, sugar and sodium for each meal. Editing or deleting a meal here updates Health too.")
                }

                Section {
                    Text("Nutrition values are AI estimates from photos and may be inaccurate. This app isn't medical advice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func enableHealth() async {
        healthError = nil
        guard HealthKitManager.shared.isAvailable else {
            healthError = "Apple Health isn't available on this device."
            healthSync = false
            return
        }
        do {
            try await HealthKitManager.shared.requestAuthorization()
        } catch {
            healthError = error.localizedDescription
            healthSync = false
        }
    }
}
