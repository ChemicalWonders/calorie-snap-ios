import SwiftUI

struct SharingSettingsView: View {
    let store: FriendsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var draft: FriendProfile?
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let binding = Binding($draft) {
                    Section("Your name") {
                        TextField("Display name", text: binding.displayName)
                    }

                    Section {
                        Toggle(isOn: binding.shareCalories) {
                            Label("Daily calories vs goal", systemImage: "chart.pie")
                        }
                        Toggle(isOn: binding.shareMacros) {
                            Label("Macros (protein, carbs, fat)", systemImage: "chart.bar")
                        }
                        Toggle(isOn: binding.shareMeals) {
                            Label("Meals & photos", systemImage: "photo.on.rectangle")
                        }
                        Toggle(isOn: binding.shareStreak) {
                            Label("Logging streak", systemImage: "flame")
                        }
                    } header: {
                        Text("What friends can see")
                    } footer: {
                        Text("Only friends you've accepted can see these. Meals are shared for the last \(FriendsSync.mealWindowDays) days. Turning a toggle off removes that data from the server.")
                    }

                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .bold()
                            .disabled(draft == nil || draft == store.profile
                                      || draft?.displayName.trimmingCharacters(in: .whitespaces).isEmpty == true)
                    }
                }
            }
            .onAppear { if draft == nil { draft = store.profile } }
        }
    }

    private func save() async {
        guard let draft else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.saveProfile(draft)
            FriendsSync.shared.requestSync(context.container, delay: .zero)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
