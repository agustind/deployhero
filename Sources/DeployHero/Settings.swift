import Foundation

/// What the user picked. Saved to UserDefaults as JSON.
struct Settings: Codable, Equatable {
    var productionOnly = false
    /// nil: the light follows every project, else only these keys
    /// ("<provider>:<project key>").
    var watch: [String]? = nil
    /// provider id → the scope ids (teams, workspaces, orgs) it follows.
    var scopes: [String: [String]] = [:]

    private static let key = "settings"

    static func load() -> Settings {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            return s
        }
        return legacy() ?? Settings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Up to 0.4.1 each platform followed one scope, and a Vercel project key
    /// was its bare name. Vercel keys now start with the team ("<team>/<name>"),
    /// since two teams can have a project with the same name.
    private mutating func upgrade(singleScopes: [String: String]) {
        scopes = singleScopes.mapValues { [$0] }
        let team = singleScopes["vercel"] ?? ""
        watch = watch?.map { key in
            guard key.hasPrefix("vercel:"), !key.contains("/") else { return key }
            return "vercel:" + team + "/" + key.dropFirst("vercel:".count)
        }
    }

    /// Settings saved by the tinyjs build (store.json), including the
    /// Vercel-only app's teamId and bare project names in watch.
    private static func legacy() -> Settings? {
        struct Store: Decodable {
            struct Saved: Decodable {
                var productionOnly: Bool?
                var watch: [String]?
                var scopes: [String: String]?
                var teamId: String?
            }
            var settings: Saved?
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Keychain.service)
            .appendingPathComponent("store.json")
        guard let data = try? Data(contentsOf: url),
              let saved = (try? JSONDecoder().decode(Store.self, from: data))?.settings else { return nil }
        var s = Settings()
        s.productionOnly = saved.productionOnly ?? false
        var scopes = saved.scopes ?? [:]
        if let team = saved.teamId, scopes["vercel"] == nil { scopes["vercel"] = team }
        s.watch = saved.watch?.map { $0.contains(":") ? $0 : "vercel:" + $0 }
        s.upgrade(singleScopes: scopes)
        s.save()
        return s
    }
}

extension Settings {
    private enum CodingKeys: String, CodingKey { case productionOnly, watch, scopes }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productionOnly = try c.decodeIfPresent(Bool.self, forKey: .productionOnly) ?? false
        watch = try c.decodeIfPresent([String].self, forKey: .watch)
        if let many = try? c.decodeIfPresent([String: [String]].self, forKey: .scopes) {
            scopes = many
        } else {
            upgrade(singleScopes: try c.decodeIfPresent([String: String].self, forKey: .scopes) ?? [:])
        }
    }
}
