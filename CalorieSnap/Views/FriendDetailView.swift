import SwiftUI
import Charts
import UIKit

struct FriendDetailView: View {
    let store: FriendsStore
    let friend: FriendSummary

    @Environment(\.dismiss) private var dismiss
    @State private var stats: FriendStats?
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        List {
            if let stats {
                content(stats)
            } else if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            } else {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }

            Section {
                Button("Remove Friend", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(friend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Remove \(friend.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.remove(friend)
                    dismiss()
                }
            }
        } message: {
            Text("You'll stop seeing each other's stats.")
        }
    }

    private func load() async {
        do {
            stats = try await store.stats(for: friend.friendId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ stats: FriendStats) -> some View {
        let today = stats.days.first { Calendar.current.isDateInToday($0.day) }

        if stats.shareStreak, let streak = stats.streak {
            Section {
                Label {
                    Text(streak == 1 ? "1-day logging streak" : "\(streak)-day logging streak").font(.headline)
                } icon: {
                    Image(systemName: "flame.fill").foregroundStyle(streak > 0 ? Color.orange : Color.secondary)
                }
            }
        }

        if stats.shareCalories || stats.shareMacros {
            Section("Today") {
                FriendTodayCard(calories: today?.calories ?? 0,
                                goal: stats.calorieGoal.map(Double.init),
                                protein: stats.shareMacros ? (today?.protein ?? 0) : nil,
                                carbs: stats.shareMacros ? (today?.carbs ?? 0) : nil,
                                fat: stats.shareMacros ? (today?.fat ?? 0) : nil,
                                showCalories: stats.shareCalories)
            }
        }

        if stats.shareCalories {
            Section("Last 7 days") {
                FriendWeekChart(days: stats.days, goal: Double(stats.calorieGoal ?? 0))
            }
        }

        if stats.shareMeals {
            Section("Recent meals") {
                if stats.meals.isEmpty {
                    Text("No meals in the last week.").foregroundStyle(.secondary)
                }
                ForEach(stats.meals) { meal in
                    HStack(spacing: 12) {
                        RemoteMealPhoto(path: meal.photoPath)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meal.name).font(.headline).lineLimit(1)
                            Text(meal.eatenAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let p = meal.protein, let c = meal.carbs, let f = meal.fat {
                                Text("P \(p.whole)g · C \(c.whole)g · F \(f.whole)g")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let calories = meal.calories {
                            Text("\(calories.whole) kcal").font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }
        }

        let hidden = [
            stats.shareCalories ? nil : "calories",
            stats.shareMacros ? nil : "macros",
            stats.shareMeals ? nil : "meals",
            stats.shareStreak ? nil : "streak"
        ].compactMap { $0 }
        if !hidden.isEmpty {
            Section {
                Text("\(stats.displayName) isn't sharing: \(hidden.joined(separator: ", ")).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pieces

struct FriendTodayCard: View {
    let calories: Double
    let goal: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let showCalories: Bool

    var body: some View {
        HStack(spacing: 20) {
            if showCalories, let goal, goal > 0 {
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: min(calories / goal, 1))
                        .stroke(calories <= goal ? Color.accentColor : .orange,
                                style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(calories.whole).font(.title2.bold()).monospacedDigit()
                        Text("of \(goal.whole)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)
            }
            if let protein, let carbs, let fat {
                VStack(alignment: .leading, spacing: 10) {
                    MacroBar(label: "Protein", grams: protein, color: .blue)
                    MacroBar(label: "Carbs", grams: carbs, color: .green)
                    MacroBar(label: "Fat", grams: fat, color: .pink)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct FriendWeekChart: View {
    let days: [FriendStats.Day]
    let goal: Double

    private struct Point: Identifiable {
        let day: Date
        let calories: Double
        var id: Date { day }
    }

    private var points: [Point] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let byDay = Dictionary(days.map { (calendar.startOfDay(for: $0.day), $0.calories ?? 0) },
                               uniquingKeysWith: { first, _ in first })
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Point(day: day, calories: byDay[day] ?? 0)
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Day", point.day, unit: .day), y: .value("kcal", point.calories))
                    .foregroundStyle(goal > 0 && point.calories > goal ? Color.orange : Color.accentColor)
                    .cornerRadius(4)
            }
            if goal > 0 {
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .frame(height: 160)
        .padding(.vertical, 8)
    }
}

/// Loads a friend's meal photo from private Supabase storage.
struct RemoteMealPhoto: View {
    let path: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: path == nil ? "fork.knife" : "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: path) {
            guard let path, let data = await FriendPhotoCache.shared.imageData(path: path) else { return }
            image = UIImage(data: data)
        }
    }
}
