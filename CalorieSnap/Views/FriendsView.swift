import SwiftUI
import SwiftData
import UIKit
import CoreImage.CIFilterBuiltins

struct FriendsView: View {
    @Environment(\.modelContext) private var context
    @State private var store = FriendsStore()
    @State private var showAddFriend = false
    @State private var showSharing = false

    var body: some View {
        NavigationStack {
            Group {
                if !SupabaseConfig.isConfigured {
                    ContentUnavailableView("Friends isn't set up",
                                           systemImage: "person.2.slash",
                                           description: Text("Add your Supabase project URL and key to SupabaseConfig.swift, then rebuild. See the README."))
                } else if !store.hasLoaded {
                    ProgressView()
                } else if store.profile == nil, let error = store.errorMessage, SupabaseClient.shared.hasSession {
                    ContentUnavailableView {
                        Label("Couldn't load friends", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await store.load() } }
                    }
                } else if store.profile == nil {
                    FriendsOnboardingView(store: store)
                } else {
                    friendsList
                }
            }
            .navigationTitle("Friends")
            .navigationDestination(for: FriendSummary.self) { FriendDetailView(store: store, friend: $0) }
            .toolbar {
                if store.profile != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSharing = true } label: { Label("Sharing", systemImage: "hand.raised") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAddFriend = true } label: { Label("Add Friend", systemImage: "person.badge.plus") }
                    }
                }
            }
            .sheet(isPresented: $showAddFriend) { AddFriendView(store: store) }
            .sheet(isPresented: $showSharing) { SharingSettingsView(store: store) }
            .task {
                await store.load()
                FriendsSync.shared.requestSync(context.container, delay: .zero)
            }
        }
    }

    private var friendsList: some View {
        List {
            if let profile = store.profile {
                Section { MyFriendCodeCard(profile: profile) }
            }

            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }

            if !store.incoming.isEmpty {
                Section("Friend requests") {
                    ForEach(store.incoming) { friend in
                        HStack {
                            Label(friend.displayName, systemImage: "person.crop.circle.badge.questionmark")
                            Spacer()
                            Button("Decline") { Task { await store.respond(to: friend, accept: false) } }
                                .buttonStyle(.bordered)
                            Button("Accept") { Task { await store.respond(to: friend, accept: true) } }
                                .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Friends") {
                if store.accepted.isEmpty {
                    Text("No friends yet. Tap \(Image(systemName: "person.badge.plus")) and enter a friend's code, or have them scan yours.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.accepted) { friend in
                        NavigationLink(value: friend) { FriendRow(friend: friend) }
                    }
                }
            }

            if !store.outgoing.isEmpty {
                Section {
                    ForEach(store.outgoing) { friend in
                        HStack {
                            Text(friend.displayName)
                            Spacer()
                            Text("Waiting…").foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Cancel", role: .destructive) { Task { await store.remove(friend) } }
                        }
                    }
                } header: {
                    Text("Sent requests")
                } footer: {
                    Text("Swipe left to cancel a request.")
                }
            }
        }
        .refreshable { await store.load() }
    }
}

// MARK: - Rows & cards

struct FriendRow: View {
    let friend: FriendSummary

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Text(String(friend.displayName.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName).font(.headline)
                if let calories = friend.todayCalories, let goal = friend.calorieGoal {
                    Text("Today: \(calories.whole) / \(goal) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Calories not shared").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let streak = friend.streak, streak > 0 {
                Label("\(streak)", systemImage: "flame.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct MyFriendCodeCard: View {
    let profile: FriendProfile
    @State private var showQR = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your friend code").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(profile.formattedCode)
                    .font(.system(.largeTitle, design: .monospaced).bold())
                Spacer()
                Button {
                    UIPasteboard.general.string = profile.formattedCode
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Button { showQR = true } label: { Label("Show QR", systemImage: "qrcode") }
                    .buttonStyle(.bordered)
                ShareLink(item: "Add me on CalorieSnap! My friend code is \(profile.formattedCode)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showQR) {
            VStack(spacing: 16) {
                Text(profile.displayName).font(.title2.bold())
                QRCodeImage(text: FriendCode.qrPrefix + profile.friendCode)
                    .frame(width: 240, height: 240)
                Text(profile.formattedCode).font(.title.monospaced())
                Text("Have your friend open Friends → Add Friend → Scan QR Code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .presentationDetents([.medium])
        }
    }
}

struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - First-time setup

struct FriendsOnboardingView: View {
    let store: FriendsStore
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "person.2.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                    Text("Share progress with friends").font(.title3.bold())
                    Text("Pick a name your friends will see. You'll get a friend code to share, and you choose exactly which stats friends can see.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("Display name") {
                TextField("e.g. Kevin", text: $name)
                    .textInputAutocapitalization(.words)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView() } else { Text("Get My Friend Code").bold() }
                        Spacer()
                    }
                }
                .disabled(trimmed.isEmpty || isSaving)
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.createProfile(displayName: String(trimmed.prefix(40)))
            FriendsSync.shared.requestSync(context.container, delay: .zero)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
