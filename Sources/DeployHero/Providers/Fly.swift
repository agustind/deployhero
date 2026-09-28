// Fly.io: GraphQL API. Takes a personal access token or an org token
// ("FlyV1 fm2_…"). Scopes are organizations; an entry is one app and its
// latest release.

import Foundation

struct Fly: Provider {
    let id = ProviderID.fly
    let name = "Fly.io"
    let host = "api.fly.io"
    let scopeLabel: String? = "Org"
    let tokenURL = URL(string: "https://fly.io/user/personal_access_tokens")!
    let tokenHelp = "A personal access token, or an org token from `fly tokens create org`."
    let dashboard = URL(string: "https://fly.io/dashboard")!

    // Release statuses flyctl writes: running → complete | failed | interrupted.
    private static let states: [String: DeployState?] = [
        "complete": .ready,
        "succeeded": .ready,
        "successful": .ready,
        "failed": .error,
        "interrupted": nil,
        "pending": .building,
        "running": .building,
    ]

    // Macaroon tokens go in as-is with their FlyV1 scheme; the rest are bearer.
    private static func authHeader(_ token: String) -> String {
        if token.hasPrefix("FlyV1 ") { return token }
        if token.hasPrefix("fm1") || token.hasPrefix("fm2") { return "FlyV1 " + token }
        return "Bearer " + token
    }

    private func gql<T: Decodable, V: Encodable>(_ token: String, _ query: String, _ variables: V) async throws -> T {
        let res: GraphQLResponse<T> = try await HTTP.request(
            URL(string: "https://api.fly.io/graphql")!,
            auth: Self.authHeader(token),
            method: "POST",
            json: GraphQLBody(query: query, variables: variables),
            label: name
        )
        if let e = res.errors?.first {
            let auth = e.message.range(of: "must be authenticated|unauthorized", options: [.regularExpression, .caseInsensitive]) != nil
            throw APIError(message: e.message, auth: auth)
        }
        guard let data = res.data else { throw APIError(message: "Fly.io API sent no data") }
        return data
    }

    func account(token: String) async throws -> Account {
        struct R: Decodable {
            struct Viewer: Decodable { var name: String?; var email: String? }
            struct Orgs: Decodable {
                struct O: Decodable { var id: String; var slug: String; var name: String; var type: String? }
                var nodes: [O]
            }
            var viewer: Viewer?
            var organizations: Orgs
        }
        let r: R = try await gql(token, """
            query {
              viewer { name email }
              organizations(first: 100) { nodes { id slug name type } }
            }
            """, [String: String]())
        let scopes = r.organizations.nodes.map { Scope(id: $0.slug, name: $0.name, slug: $0.slug) }
        let personal = r.organizations.nodes.first { $0.type == "PERSONAL" }
        return Account(
            name: [r.viewer?.name, r.viewer?.email, scopes.first?.name].compactMap { $0 }.first { !$0.isEmpty } ?? "Fly.io",
            detail: r.viewer?.email ?? "",
            scopes: scopes,
            defaultScope: personal?.slug ?? scopes.first?.id ?? ""
        )
    }

    // Fly has no preview deployments, so productionOnly doesn't narrow anything.
    func deployments(token: String, scope: String, productionOnly: Bool) async throws -> [Deployment] {
        guard !scope.isEmpty else { return [] }
        struct R: Decodable {
            struct Release: Decodable {
                var id: String
                var version: Int
                var status: String
                var description: String?
                var createdAt: String
            }
            struct App: Decodable {
                struct Releases: Decodable { var nodes: [Release] }
                var name: String
                var releases: Releases
            }
            struct Org: Decodable {
                struct Apps: Decodable { var nodes: [App] }
                var apps: Apps
            }
            var organization: Org?
        }
        let r: R = try await gql(token, """
            query ($slug: String!) {
              organization(slug: $slug) {
                apps(first: 100) { nodes {
                  name deployed
                  releases(first: 1) { nodes { id version status description createdAt } }
                } }
              }
            }
            """, ["slug": scope])
        return (r.organization?.apps.nodes ?? []).compactMap { app in
            guard let rel = app.releases.nodes.first,
                  let state = Self.states[rel.status] ?? .building else { return nil }
            return Deployment(
                provider: id,
                key: app.name,
                uid: rel.id,
                project: app.name,
                state: state,
                status: rel.status,
                target: "v\(rel.version)",
                created: ISODate.parse(rel.createdAt) ?? .distantPast,
                url: URL(string: "https://fly.io/apps/\(app.name)"),
                message: rel.description.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    func dashboardURL(account: Account?, scope: String) -> URL {
        scope.isEmpty ? dashboard : URL(string: "https://fly.io/dashboard/\(scope)") ?? dashboard
    }
}
