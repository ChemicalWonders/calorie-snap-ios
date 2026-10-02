import Foundation

enum SupabaseError: LocalizedError {
    case notConfigured
    case notSignedIn
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Friends isn't set up yet. Add your Supabase details to SupabaseConfig.swift."
        case .notSignedIn: "You're signed out of Friends. Try again."
        case .http(_, let message): message
        }
    }
}

/// Stored in the Keychain so the anonymous account survives app restarts.
struct SupabaseSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: UUID
}

/// Tiny Supabase client over URLSession: anonymous auth, PostgREST (tables + RPC) and Storage.
@MainActor
final class SupabaseClient {
    static let shared = SupabaseClient()

    private static let sessionAccount = "supabaseSession"
    private var session: SupabaseSession?
    private var refreshTask: Task<SupabaseSession, Error>?

    private init() {
        if let json = KeychainHelper.read(account: Self.sessionAccount),
           let saved = try? JSONDecoder().decode(SupabaseSession.self, from: Data(json.utf8)) {
            session = saved
        }
    }

    var hasSession: Bool { session != nil }
    var userID: UUID? { session?.userID }
    /// Lowercased user id, as Postgres prints it.
    var userIDString: String? { session?.userID.uuidString.lowercased() }

    // MARK: Auth

    /// Returns a fresh access token, signing in anonymously the first time.
    @discardableResult
    func validSession() async throws -> SupabaseSession {
        guard SupabaseConfig.isConfigured else { throw SupabaseError.notConfigured }
        if let session, session.expiresAt.timeIntervalSinceNow > 60 { return session }
        if let refreshTask { return try await refreshTask.value }

        let existing = session
        let task = Task { () throws -> SupabaseSession in
            if let existing {
                return try await self.authRequest(path: "/auth/v1/token?grant_type=refresh_token",
                                                  body: ["refresh_token": existing.refreshToken])
            }
            // Requires "Allow anonymous sign-ins" in Supabase → Authentication → Sign In / Providers.
            return try await self.authRequest(path: "/auth/v1/signup", body: [:])
        }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh = try await task.value
        store(fresh)
        return fresh
    }

    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: UUID }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User
    }

    private func authRequest(path: String, body: [String: Any]) async throws -> SupabaseSession {
        guard let url = URL(string: SupabaseConfig.projectURL + path) else { throw SupabaseError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SupabaseError.http(status, Self.errorMessage(data)) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let auth = try decoder.decode(AuthResponse.self, from: data)
        return SupabaseSession(accessToken: auth.accessToken, refreshToken: auth.refreshToken,
                               expiresAt: Date.now.addingTimeInterval(auth.expiresIn), userID: auth.user.id)
    }

    private func store(_ newSession: SupabaseSession) {
        session = newSession
        if let data = try? JSONEncoder().encode(newSession), let json = String(data: data, encoding: .utf8) {
            KeychainHelper.save(json, account: Self.sessionAccount)
        }
    }

    // MARK: Core request

    /// Authenticated request against the project. Retries once with a refreshed token on 401.
    func send(_ method: String, _ path: String,
              json: Any? = nil, body: Data? = nil, contentType: String? = nil,
              headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: SupabaseConfig.projectURL + path) else { throw SupabaseError.notConfigured }

        var payload = body
        var type = contentType
        if let json {
            payload = try JSONSerialization.data(withJSONObject: json)
            type = "application/json"
        }

        for attempt in 0..<2 {
            let current = try await validSession()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = payload

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                session?.expiresAt = .distantPast   // force a refresh, then retry
                continue
            }
            guard (200..<300).contains(status) else { throw SupabaseError.http(status, Self.errorMessage(data)) }
            return data
        }
        throw SupabaseError.notSignedIn
    }

    private static func errorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "msg", "error_description", "error"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: PostgREST

    func rpc<T: Decodable>(_ function: String, _ params: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await send("POST", "/rest/v1/rpc/\(function)", json: params)
        return try SupabaseJSON.decoder.decode(T.self, from: data)
    }

    func rpcVoid(_ function: String, _ params: [String: Any] = [:]) async throws {
        _ = try await send("POST", "/rest/v1/rpc/\(function)", json: params)
    }

    /// `query` is a PostgREST query string, e.g. "id=eq.123&select=*".
    func select<T: Decodable>(_ table: String, query: String, as type: T.Type = T.self) async throws -> [T] {
        let data = try await send("GET", "/rest/v1/\(table)?\(query)")
        return try SupabaseJSON.decoder.decode([T].self, from: data)
    }

    func insert(_ table: String, rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await send("POST", "/rest/v1/\(table)", json: rows,
                           headers: ["Prefer": "return=minimal,resolution=merge-duplicates"])
    }

    func update(_ table: String, query: String, values: [String: Any]) async throws {
        _ = try await send("PATCH", "/rest/v1/\(table)?\(query)", json: values, headers: ["Prefer": "return=minimal"])
    }

    func delete(_ table: String, query: String) async throws {
        _ = try await send("DELETE", "/rest/v1/\(table)?\(query)", headers: ["Prefer": "return=minimal"])
    }

    // MARK: Storage

    func upload(_ data: Data, bucket: String, path: String, contentType: String = "image/jpeg") async throws {
        _ = try await send("POST", "/storage/v1/object/\(bucket)/\(path)", body: data,
                           contentType: contentType, headers: ["x-upsert": "true"])
    }

    func download(bucket: String, path: String) async throws -> Data {
        try await send("GET", "/storage/v1/object/authenticated/\(bucket)/\(path)")
    }

    func remove(bucket: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await send("DELETE", "/storage/v1/object/\(bucket)", json: ["prefixes": paths])
    }
}

/// JSON + date helpers shared by Supabase calls.
enum SupabaseJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unrecognized date: \(text)"))
        }
        return decoder
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    /// "yyyy-MM-dd" in the device's time zone (used for Postgres `date` columns).
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        if text.count == 10 { return dayFormatter.date(from: text) }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    static func timestamp(_ date: Date) -> String { iso.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}
