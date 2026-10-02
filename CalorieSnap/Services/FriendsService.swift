import Foundation
import SwiftData
import Observation

// MARK: - Models returned by the backend

struct FriendProfile: Codable, Equatable {
    var id: UUID
    var displayName: String
    var friendCode: String
    var calorieGoal: Int
    var shareCalories: Bool
    var shareMacros: Bool
    var shareMeals: Bool
    var shareStreak: Bool

    /// "ABC123" → "ABC-123"
    var formattedCode: String { FriendCode.format(friendCode) }
}

struct FriendSummary: Codable, Hashable, Identifiable {
    var friendId: UUID
    var displayName: String
    var status: String
    var outgoing: Bool
    var calorieGoal: Int?
    var todayCalories: Double?
    var streak: Int?

    var id: UUID { friendId }
    var isAccepted: Bool { status == "accepted" }
}

struct FriendStats: Decodable {
    struct Day: Decodable {
        var day: Date
        var calories: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var mealCount: Int
    }

    struct Meal: Decodable, Identifiable {
        var id: UUID
        var eatenAt: Date
        var name: String
        var mealType: String
        var calories: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var photoPath: String?
    }

    var id: UUID
    var displayName: String
    var shareCalories: Bool
    var shareMacros: Bool
    var shareMeals: Bool
    var shareStreak: Bool
    var calorieGoal: Int?
    var streak: Int?
    var days: [Day]
    var meals: [Meal]
}

enum FriendCode {
    static let qrPrefix = "calsnap:"

    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix(qrPrefix) { text = String(text.dropFirst(qrPrefix.count)) }
        return text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func format(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3))-\(code.suffix(3))"
    }
}

// MARK: - Store used by the Friends screens

@MainActor
@Observable
final class FriendsStore {
    var profile: FriendProfile?
    var friends: [FriendSummary] = []
    var isLoading = false
    var hasLoaded = false
    var errorMessage: String?

    private let client = SupabaseClient.shared
    private var today: String { SupabaseJSON.day(.now) }

    var incoming: [FriendSummary] { friends.filter { !$0.isAccepted && !$0.outgoing } }
    var outgoing: [FriendSummary] { friends.filter { !$0.isAccepted && $0.outgoing } }
    var accepted: [FriendSummary] { friends.filter(\.isAccepted) }

    func load() async {
        guard SupabaseConfig.isConfigured else { hasLoaded = true; return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            // Don't create an account until the user opts in via onboarding.
            guard client.hasSession, let uid = client.userIDString else { profile = nil; return }
            profile = try await client.select("profiles", query: "id=eq.\(uid)&select=*", as: FriendProfile.self).first
            if profile != nil {
                friends = try await client.rpc("list_friends", ["p_today": today])
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createProfile(displayName: String) async throws {
        try await client.validSession()   // signs in anonymously the first time
        profile = try await client.rpc("ensure_profile", ["p_display_name": displayName], as: FriendProfile.self)
        await load()
    }

    func saveProfile(_ updated: FriendProfile) async throws {
        guard let uid = client.userIDString else { throw SupabaseError.notSignedIn }
        try await client.update("profiles", query: "id=eq.\(uid)", values: [
            "display_name": updated.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            "share_calories": updated.shareCalories,
            "share_macros": updated.shareMacros,
            "share_meals": updated.shareMeals,
            "share_streak": updated.shareStreak,
            "updated_at": SupabaseJSON.timestamp(.now)
        ])
        profile = updated
    }

    /// Returns "pending" or "accepted".
    func addFriend(code: String) async throws -> String {
        let status: String = try await client.rpc("send_friend_request", ["p_code": FriendCode.normalize(code)])
        await load()
        return status
    }

    func respond(to friend: FriendSummary, accept: Bool) async {
        await run { try await self.client.rpcVoid("respond_friend_request",
                                                  ["p_requester": friend.friendId.uuidString.lowercased(),
                                                   "p_accept": accept]) }
    }

    func remove(_ friend: FriendSummary) async {
        await run { try await self.client.rpcVoid("remove_friend", ["p_other": friend.friendId.uuidString.lowercased()]) }
    }

    func stats(for friendID: UUID, days: Int = 7) async throws -> FriendStats {
        try await client.rpc("get_friend_stats", ["p_friend": friendID.uuidString.lowercased(),
                                                  "p_today": today,
                                                  "p_days": days])
    }

    private func run(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Uploading your own stats

/// Pushes your daily totals (and recent meals, if shared) to Supabase.
/// Only uploads what your sharing toggles allow; the server enforces them again.
@MainActor
final class FriendsSync {
    static let shared = FriendsSync()

    /// How far back meals (with photos) are shared.
    static let mealWindowDays = 14
    private static let uploadedPhotosKey = "uploadedMealPhotoIDs"

    private var pending: Task<Void, Never>?
    private var isSyncing = false
    private var needsAnotherPass = false

    /// Debounced: rapid edits collapse into one sync. No-op until the user has set up Friends.
    func requestSync(_ container: ModelContainer, delay: Duration = .seconds(2)) {
        guard SupabaseConfig.isConfigured, SupabaseClient.shared.hasSession else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Run in a separate task so a later cancel can't interrupt a sync halfway through.
            await Task { await self.syncNow(container) }.value
        }
    }

    private func syncNow(_ container: ModelContainer) async {
        if isSyncing { needsAnotherPass = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsAnotherPass = false
            do { try await sync(container) } catch { print("Friends sync failed: \(error)") }
        } while needsAnotherPass
    }

    private func sync(_ container: ModelContainer) async throws {
        let client = SupabaseClient.shared
        guard let uid = client.userIDString else { return }
        guard let profile = try await client.select("profiles", query: "id=eq.\(uid)&select=*",
                                                    as: FriendProfile.self).first else { return }

        // Keep the calorie goal in step with Settings.
        let goal = Int((UserDefaults.standard.object(forKey: SettingsKey.dailyCalorieGoal) as? Double) ?? 2000)
        if profile.calorieGoal != goal {
            try await client.update("profiles", query: "id=eq.\(uid)", values: ["calorie_goal": goal])
        }

        let meals = try ModelContext(container).fetch(FetchDescriptor<MealEntry>())
        let calendar = Calendar.current

        // 1. Daily totals (replaced wholesale so deleted days disappear).
        func value(_ include: Bool, _ number: Double) -> Any {
            include ? ((number * 10).rounded() / 10) as Any : NSNull() as Any
        }
        let byDay = Dictionary(grouping: meals) { calendar.startOfDay(for: $0.date) }
        let dayRows: [[String: Any]] = byDay.map { entry -> [String: Any] in
            let (day, dayMeals) = (entry.key, entry.value)
            let totals = NutritionTotals(meals: dayMeals)
            return [
                "user_id": uid,
                "day": SupabaseJSON.day(day),
                "calories": value(profile.shareCalories, totals.calories),
                "protein": value(profile.shareMacros, totals.protein),
                "carbs": value(profile.shareMacros, totals.carbs),
                "fat": value(profile.shareMacros, totals.fat),
                "meal_count": dayMeals.count
            ]
        }
        try await client.delete("daily_stats", query: "user_id=eq.\(uid)")
        try await client.insert("daily_stats", rows: dayRows)

        // 2. Recent meals + photos (only if sharing meals).
        let cutoff = calendar.date(byAdding: .day, value: -Self.mealWindowDays, to: .now) ?? .distantPast
        let recent = profile.shareMeals ? meals.filter { $0.date >= cutoff } : []
        let mealID = { (meal: MealEntry) in meal.id.uuidString.lowercased() }
        let photoPath = { (id: String) in "\(uid)/\(id).jpg" }

        var uploaded = Set(UserDefaults.standard.stringArray(forKey: Self.uploadedPhotosKey) ?? [])
        let wanted = Set(recent.filter { $0.photoData != nil }.map(mealID))

        let stale = uploaded.subtracting(wanted)
        if !stale.isEmpty {
            try await client.remove(bucket: SupabaseConfig.photoBucket, paths: stale.map(photoPath))
            uploaded.subtract(stale)
            UserDefaults.standard.set(Array(uploaded), forKey: Self.uploadedPhotosKey)
        }
        for meal in recent {
            let id = mealID(meal)
            guard let data = meal.photoData, !uploaded.contains(id) else { continue }
            try await client.upload(data, bucket: SupabaseConfig.photoBucket, path: photoPath(id))
            uploaded.insert(id)
            UserDefaults.standard.set(Array(uploaded), forKey: Self.uploadedPhotosKey)
        }

        let mealRows: [[String: Any]] = recent.map { meal -> [String: Any] in
            let totals = meal.totals
            let id = mealID(meal)
            return [
                "id": id,
                "user_id": uid,
                "eaten_at": SupabaseJSON.timestamp(meal.date),
                "name": meal.name.isEmpty ? meal.mealType.title : meal.name,
                "meal_type": meal.mealType.rawValue,
                "calories": (totals.calories * 10).rounded() / 10,
                "protein": value(profile.shareMacros, totals.protein),
                "carbs": value(profile.shareMacros, totals.carbs),
                "fat": value(profile.shareMacros, totals.fat),
                "photo_path": wanted.contains(id) ? photoPath(id) as Any : NSNull() as Any
            ]
        }
        try await client.delete("shared_meals", query: "user_id=eq.\(uid)")
        try await client.insert("shared_meals", rows: mealRows)
    }
}

// MARK: - Authenticated photo loading

@MainActor
final class FriendPhotoCache {
    static let shared = FriendPhotoCache()
    private let cache = NSCache<NSString, UIImageBox>()

    final class UIImageBox { let data: Data; init(_ data: Data) { self.data = data } }

    func imageData(path: String) async -> Data? {
        if let hit = cache.object(forKey: path as NSString) { return hit.data }
        guard let data = try? await SupabaseClient.shared.download(bucket: SupabaseConfig.photoBucket, path: path) else {
            return nil
        }
        cache.setObject(UIImageBox(data), forKey: path as NSString)
        return data
    }
}
