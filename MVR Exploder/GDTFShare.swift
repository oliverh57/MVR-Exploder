import Foundation
import Security

/// One fixture revision on GDTF Share.
nonisolated struct GDTFShareEntry: Identifiable, Hashable, Sendable {
    struct Mode: Hashable, Sendable {
        let name: String
        let footprint: Int
    }

    /// The revision id, which is what a download asks for.
    let rid: Int
    let manufacturer: String
    let fixture: String
    let revision: String
    let lastModified: Date
    /// "Manuf." for the manufacturer's own upload, "User" otherwise.
    let uploader: String
    let rating: Double
    /// The fixture type's id, the same across revisions.
    let uuid: String
    let modes: [Mode]

    var id: Int { rid }
    var isFromManufacturer: Bool { uploader.lowercased().hasPrefix("manuf") }

    /// How it's named in the file: "Robe@Robin MegaPointe@r3038.gdtf", the
    /// form GDTF Share's own downloads already take in real MVRs.
    var fileName: String {
        let clean = { (text: String) in
            text.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "@", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return "\(clean(manufacturer))@\(clean(fixture))@r\(rid).gdtf"
    }
}

/// GDTF Share's public API: sign in, list every fixture revision, download
/// one. Three calls under `gdtf-share.com/apis/public/`, a session cookie
/// in between that lasts two hours. A free GDTF Share account is needed.
actor GDTFShareClient {
    static let shared = GDTFShareClient()

    enum Failure: LocalizedError {
        case signInRejected(String)
        case notSignedIn
        case server(String)

        var errorDescription: String? {
            switch self {
            case .signInRejected(let reason): return reason.isEmpty ? "GDTF Share didn't accept that username and password." : reason
            case .notSignedIn: return "Sign in to GDTF Share first."
            case .server(let reason): return reason
            }
        }
    }

    private static let base = URL(string: "https://gdtf-share.com/apis/public/")!

    /// Its own cookie jar, kept to this session, so the GDTF Share cookie
    /// never mixes with anything else.
    private let session = URLSession(configuration: .ephemeral)
    private var credentials: (user: String, password: String)?
    private var list: [GDTFShareEntry]?

    var signedInUser: String? { credentials?.user }

    func signIn(user: String, password: String) async throws {
        var request = URLRequest(url: Self.base.appendingPathComponent("login.php"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["user": user, "password": password])
        let (data, _) = try await session.data(for: request)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard reply?["result"] as? Bool == true else {
            throw Failure.signInRejected(reply?["error"] as? String ?? "")
        }
        credentials = (user, password)
    }

    func signOut() {
        credentials = nil
        list = nil
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    /// Every fixture revision, fetched once a session — it's thousands of
    /// entries.
    func entries() async throws -> [GDTFShareEntry] {
        if let list { return list }
        let data = try await authorised(Self.base.appendingPathComponent("getList.php"))
        let parsed = try Self.parseList(data)
        list = parsed
        return parsed
    }

    func download(_ entry: GDTFShareEntry) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent("downloadFile.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "rid", value: String(entry.rid))]
        let data = try await authorised(components.url!)
        // A failure comes back as JSON; a .gdtf is a zip.
        guard data.starts(with: [0x50, 0x4B]) else {
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Failure.server(reply?["error"] as? String ?? "GDTF Share didn't send the file.")
        }
        return data
    }

    /// A GET with the session cookie, signing in again once if it has
    /// lapsed — it only lasts two hours.
    private func authorised(_ url: URL) async throws -> Data {
        guard let credentials else { throw Failure.notSignedIn }
        for attempt in 0..<2 {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                try await signIn(user: credentials.user, password: credentials.password)
                continue
            }
            guard (200..<300).contains(status) else {
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw Failure.server(reply?["error"] as? String ?? "GDTF Share answered \(status).")
            }
            return data
        }
        throw Failure.notSignedIn
    }

    // MARK: - Reading the list

    /// Tolerant of numbers arriving as strings and the reverse, since the
    /// API documents types it doesn't always keep to.
    nonisolated static func parseList(_ data: Data) throws -> [GDTFShareEntry] {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.server("GDTF Share sent something that isn't a fixture list.")
        }
        guard reply["result"] as? Bool != false else {
            throw Failure.server(reply["error"] as? String ?? "GDTF Share wouldn't send the fixture list.")
        }
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? String { return Double(value) }
            return nil
        }
        func text(_ value: Any?) -> String {
            if let value = value as? String { return value }
            if let value = value as? NSNumber { return value.stringValue }
            return ""
        }
        return (reply["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard let rid = number(item["rid"]).map(Int.init) else { return nil }
            let modes = (item["modes"] as? [[String: Any]] ?? []).map {
                GDTFShareEntry.Mode(name: text($0["name"]), footprint: Int(number($0["dmxfootprint"]) ?? 0))
            }
            return GDTFShareEntry(
                rid: rid,
                manufacturer: text(item["manufacturer"]),
                fixture: text(item["fixture"]),
                revision: text(item["revision"]),
                lastModified: Date(timeIntervalSince1970: number(item["lastModified"]) ?? 0),
                uploader: text(item["uploader"]),
                rating: number(item["rating"]) ?? 0,
                uuid: text(item["uuid"]),
                modes: modes)
        }
    }

    // MARK: - Finding a match

    /// What to search for to find a type: its manufacturer and name, from
    /// a spec like "Robe@Robin MegaPointe [Bulb=LED].gdtf".
    @MainActor static func suggestedQuery(for spec: String) -> String {
        let name = GDTFSpecName.readable(spec)
        let head = spec.components(separatedBy: "@").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let manufacturer = spec.contains("@") && !["custom", "mvr exploder", "generic"].contains(head.lowercased()) ? head : ""
        return [manufacturer, name].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The newest revision of each fixture type matching `query`, best
    /// first: most words matched, then the manufacturer's own upload, then
    /// rating, then newest. Words are matched loosely — "Aura Raven XIP"
    /// should still find "MAC Aura XIP" — so a fixture needs only half of
    /// them.
    nonisolated static func search(_ entries: [GDTFShareEntry], for query: String, limit: Int = 200) -> [GDTFShareEntry] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        var newest: [String: GDTFShareEntry] = [:]
        for entry in entries {
            let key = entry.uuid.isEmpty ? String(entry.rid) : entry.uuid
            if let kept = newest[key], kept.lastModified >= entry.lastModified { continue }
            newest[key] = entry
        }

        let scored = newest.values.compactMap { entry -> (GDTFShareEntry, Int)? in
            let haystack = (entry.manufacturer + " " + entry.fixture).lowercased()
            let matched = words.filter { haystack.contains($0) }.count
            guard matched * 2 >= words.count, matched > 0 else { return nil }
            return (entry, matched)
        }
        return scored.sorted { first, second in
            if first.1 != second.1 { return first.1 > second.1 }
            if first.0.isFromManufacturer != second.0.isFromManufacturer { return first.0.isFromManufacturer }
            if first.0.rating != second.0.rating { return first.0.rating > second.0.rating }
            return first.0.lastModified > second.0.lastModified
        }
        .prefix(limit)
        .map(\.0)
    }

    /// The new GDTF's mode for an old one: the same name, else the same
    /// footprint, else the first.
    nonisolated static func defaultMode(for old: String, footprint: Int?, in modes: [GDTFShareEntry.Mode]) -> String? {
        if let same = modes.first(where: { $0.name.caseInsensitiveCompare(old) == .orderedSame }) { return same.name }
        if let footprint, let same = modes.first(where: { $0.footprint == footprint }) { return same.name }
        return modes.first?.name
    }
}

/// The GDTF Share sign-in, kept in the Keychain so it's asked for once.
enum GDTFShareKeychain {
    private static let service = "GDTF Share"

    static func save(user: String, password: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> (user: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let user = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return (user, password)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
