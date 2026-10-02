import SwiftUI
import SwiftData

@main
struct CalorieSnapApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: MealEntry.self)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "fork.knife") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Keys for values stored in UserDefaults / @AppStorage.
enum SettingsKey {
    static let geminiModel = "geminiModel"
    static let dailyCalorieGoal = "dailyCalorieGoal"
    static let healthSyncEnabled = "healthSyncEnabled"
    static let defaultGeminiModel = "gemini-3.8-flash"
    static let fallbackGeminiModel = "fallbackGeminiModel"
    static let defaultFallbackModel = "gemini-3.5-flash-lite"
}
