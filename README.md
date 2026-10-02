# CalorieSnap

Native SwiftUI app: snap a photo of your food → Google Gemini estimates each item's portion, calories and macros → you review/edit → it's logged on-device (SwiftData) and optionally saved to Apple Health.

## Requirements
- Xcode 16 or newer, iOS 17+ device or simulator
- A Google Gemini API key (https://aistudio.google.com/apikey)
- An Apple ID signed into Xcode (free account works for your own phone)

## Run it
1. Open `CalorieSnap.xcodeproj`.
2. Select the **CalorieSnap** target → **Signing & Capabilities** → choose your **Team**. If the bundle ID is taken, change `com.kevinchan.CalorieSnap` to something unique.
3. Confirm the **HealthKit** capability is listed (it comes from `CalorieSnap.entitlements`). If Xcode flags it, click **+ Capability → HealthKit**.
4. Pick your iPhone as the run destination and press **⌘R**. (The simulator works too, but has no camera — use "Choose from Library".)
5. In the app: **Settings** → paste your Gemini key → **Save Key**. Optionally turn on **Save meals to Apple Health**.
6. **Today** → **Snap a Meal** → take a photo → **Analyze Nutrition** → review → **Log Meal**.

## How it works
| File | Role |
|---|---|
| `Services/GeminiService.swift` | Sends the downscaled JPEG + prompt to `generateContent` with a JSON response schema, decodes items |
| `Services/HealthKitManager.swift` | Writes each meal as an `HKCorrelation` (food) with energy, protein, carbs, fat, fiber, sugar, sodium; deletes/rewrites on edit or delete |
| `Services/KeychainHelper.swift` | Stores the API key in the Keychain |
| `Models/MealEntry.swift` | SwiftData model + `FoodItem` |
| `Views/CaptureFlowView.swift` | Camera / library → analyze → review |
| `Views/AnalysisReviewView.swift` | Edit items, portions (0.5×–2×), nutrients |
| `Views/TodayView.swift`, `HistoryView.swift` | Daily ring + macros, 7-day chart, history by day |

The model defaults to `gemini-3.8-flash` and can be changed in Settings (e.g. a Pro model for better accuracy, a Flash-Lite model for speed/cost).

## Friends (Supabase)
Friends see only the stats you choose (calories vs goal, macros, meals & photos, streak). Sharing rules are enforced on the server with row-level security.

One-time setup:
1. Create a free project at https://supabase.com.
2. **Authentication → Sign In / Providers →** turn on **Allow anonymous sign-ins**. Each phone gets a private account automatically; there's no email or password.
3. **SQL Editor → New query →** paste all of `supabase/schema.sql` → **Run**. This creates the tables, the security rules and the private `meal-photos` storage bucket.
4. **Project Settings → API** (or the **Connect** button): copy the **Project URL** and the **anon / publishable** key into `CalorieSnap/Services/SupabaseConfig.swift`.
5. Rebuild. Open **Friends**, pick a display name, and share your code (or QR) with a friend.

Friends must run a build of this app pointed at the same Supabase project. They also need their own Gemini key to analyze photos.

| File | Role |
|---|---|
| `supabase/schema.sql` | Tables, RLS policies, friend functions, storage bucket |
| `Services/SupabaseClient.swift` | Anonymous auth, REST/RPC and storage over URLSession (no SDK) |
| `Services/FriendsService.swift` | Friends store + background sync of your daily totals and recent meals |
| `Views/FriendsView.swift`, `FriendDetailView.swift`, `AddFriendView.swift`, `SharingSettingsView.swift` | Friends UI |

## Notes
- AI portion estimates are approximate; the review screen is there so you can fix them.
- The key lives on your device. Before publishing to the App Store, move the Gemini call behind your own backend so the key isn't shipped in the app.
