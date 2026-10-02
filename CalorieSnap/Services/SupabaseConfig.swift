import Foundation

/// Fill these in from Supabase Dashboard → Project Settings → API (or "Connect").
/// Everyone who uses the Friends feature must run a build with the same values.
/// The anon / publishable key is designed to ship inside apps; row-level security protects the data.
enum SupabaseConfig {
    static let projectURL = "https://YOUR-PROJECT-REF.supabase.co"
    static let anonKey = "YOUR-ANON-OR-PUBLISHABLE-KEY"

    static let photoBucket = "meal-photos"

    static var isConfigured: Bool {
        !projectURL.contains("YOUR-") && !anonKey.contains("YOUR-") && URL(string: projectURL) != nil
    }
}
