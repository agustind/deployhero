import Foundation

/// What the user picked. Saved to UserDefaults as JSON.
struct Settings: Codable, Equatable {
    var productionOnly = false
    /// nil: the light follows every project, else only these keys
    /// ("<provider>:<project key>").
    var watch: [String]? = nil
    /// provider id → scope id (team, workspace, org).
    var scopes: [String: String] = [:]

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
        s.scopes = saved.scopes ?? [:]
        if let team = saved.teamId, s.scopes["vercel"] == nil { s.scopes["vercel"] = team }
        s.watch = saved.watch?.map { $0.contains(":") ? $0 : "vercel:" + $0 }
        s.save()
        return s
    }
}
