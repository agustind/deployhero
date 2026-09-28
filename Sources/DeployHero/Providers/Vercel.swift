// Vercel: REST API, personal access token. Scopes are the personal account
// (id "") and every team the token can see.

import Foundation

struct Vercel: Provider {
    let id = ProviderID.vercel
    let name = "Vercel"
    let host = "api.vercel.com"
    let scopeLabel: String? = "Team"
    let tokenURL = URL(string: "https://vercel.com/account/tokens")!
    let tokenHelp = "Scope it to the team you want to watch."
    let dashboard = URL(string: "https://vercel.com")!

    private static let states: [String: DeployState?] = [
        "READY": .ready,
        "ERROR": .error,
        "BUILDING": .building,
        "QUEUED": .building,
        "INITIALIZING": .building,
        "CANCELED": nil,
    ]

    private func get<T: Decodable>(_ token: String, _ path: String, _ params: [String: String?] = [:]) async throws -> T {
        var url = URLComponents(string: "https://api.vercel.com" + path)!
        let items = HTTP.query(params)
        if !items.isEmpty { url.queryItems = items }
        do {
            return try await HTTP.request(url.url!, auth: "Bearer " + token, label: name)
        } catch var err as APIError {
            // Only a dead token signs us out; a 403 for one team's scope shouldn't.
            if let body = err.body, (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error?.invalidToken == true {
                err.auth = true
            }
            throw err
        }
    }

    private struct ErrorBody: Decodable {
        struct E: Decodable { var invalidToken: Bool? }
        var error: E?
    }

    func account(token: String) async throws -> Account {
        struct User: Decodable {
            struct U: Decodable { var name: String?; var username: String; var email: String?; var defaultTeamId: String? }
            var user: U
        }
        struct Teams: Decodable {
            struct T: Decodable { var id: String; var name: String; var slug: String? }
            var teams: [T]?
        }
        async let userReq: User = get(token, "/v2/user")
        async let teamsReq: Teams = get(token, "/v2/teams", ["limit": "100"])
        let (u, teams) = try await (userReq.user, teamsReq.teams ?? [])
        var scopes = teams.map { Scope(id: $0.id, name: $0.name, slug: $0.slug) }
        // Newer Vercel accounts have no personal scope — start on the default team.
        if u.defaultTeamId == nil {
            scopes.insert(Scope(id: "", name: u.username + " (personal)", slug: ""), at: 0)
        }
        return Account(
            name: u.name.flatMap { $0.isEmpty ? nil : $0 } ?? u.username,
            detail: u.email ?? "",
            scopes: scopes,
            defaultScope: u.defaultTeamId ?? ""
        )
    }

    func deployments(token: String, scope: String, productionOnly: Bool) async throws -> [Deployment] {
        struct Response: Decodable {
            struct D: Decodable {
                struct Meta: Decodable { var githubCommitMessage: String? }
                var uid: String
                var name: String
                var state: String?
                var readyState: String?
                var target: String?
                var created: Double?
                var createdAt: Double?
                var inspectorUrl: String?
                var url: String?
                var meta: Meta?
            }
            var deployments: [D]?
        }
        let res: Response = try await get(token, "/v6/deployments", [
            "limit": "100",
            "teamId": scope,
            "target": productionOnly ? "production" : nil,
        ])
        // The API returns newest first; keep the first live one we see per project.
        var seen = Set<String>()
        var out: [Deployment] = []
        for d in res.deployments ?? [] {
            let raw = d.state ?? d.readyState ?? ""
            let state = Self.states[raw] ?? .building
            guard let state, !seen.contains(d.name) else { continue }
            seen.insert(d.name)
            let url = d.inspectorUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                ?? d.url.flatMap { URL(string: "https://" + $0) }
            out.append(Deployment(
                provider: id,
                key: d.name,
                uid: d.uid,
                project: d.name,
                state: state,
                status: raw.lowercased(),
                target: d.target ?? "preview",
                created: Date(timeIntervalSince1970: (d.created ?? d.createdAt ?? 0) / 1000),
                url: url,
                message: d.meta?.githubCommitMessage?.firstLine
            ))
        }
        return out
    }

    func dashboardURL(account: Account?, scope: String) -> URL {
        let slug = account?.scopes.first { $0.id == scope }?.slug ?? ""
        return URL(string: "https://vercel.com/" + slug) ?? dashboard
    }
}
