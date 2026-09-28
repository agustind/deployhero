// Railway: GraphQL API, account token. Scopes are workspaces; an entry is
// one service in one environment ("project / service", tagged with the env).

import Foundation

struct Railway: Provider {
    let id = ProviderID.railway
    let name = "Railway"
    let host = "backboard.railway.com"
    let scopeLabel: String? = "Workspace"
    let tokenURL = URL(string: "https://railway.com/account/tokens")!
    let tokenHelp = "Use an account token (no workspace selected) so the app can list your workspaces."
    let dashboard = URL(string: "https://railway.com/dashboard")!

    private static let states: [String: DeployState?] = [
        "SUCCESS": .ready,
        "SLEEPING": .ready,
        "FAILED": .error,
        "CRASHED": .error,
        "BUILDING": .building,
        "DEPLOYING": .building,
        "INITIALIZING": .building,
        "QUEUED": .building,
        "WAITING": .building,
        "NEEDS_APPROVAL": .building,
        // Superseded, torn down or skipped — not the deployment that matters.
        "REMOVED": nil,
        "REMOVING": nil,
        "SKIPPED": nil,
    ]

    private static let maxProjects = 30

    private func gql<T: Decodable, V: Encodable>(_ token: String, _ query: String, _ variables: V) async throws -> T {
        let res: GraphQLResponse<T> = try await HTTP.request(
            URL(string: "https://backboard.railway.com/graphql/v2")!,
            auth: "Bearer " + token,
            method: "POST",
            json: GraphQLBody(query: query, variables: variables),
            label: name
        )
        if let e = res.errors?.first { throw APIError(message: e.message) }
        guard let data = res.data else { throw APIError(message: "Railway API sent no data") }
        return data
    }

    func account(token: String) async throws -> Account {
        struct Me: Decodable {
            struct M: Decodable {
                struct W: Decodable { var id: String; var name: String }
                var name: String?
                var email: String?
                var username: String?
                var workspaces: [W]
            }
            var me: M
        }
        let me: Me.M
        do {
            me = try await (gql(token, "query { me { name email username workspaces { id name } } }", [String: String]()) as Me).me
        } catch var err as APIError {
            // Workspace and project tokens can't read `me`.
            if err.message.range(of: "not authorized", options: .caseInsensitive) != nil {
                err.message = "Railway rejected that token. It needs an account token (no workspace selected)."
                err.auth = true
            }
            throw err
        }
        let scopes = me.workspaces.map { Scope(id: $0.id, name: $0.name) }
        return Account(
            name: [me.name, me.username, me.email].compactMap { $0 }.first { !$0.isEmpty } ?? "Railway",
            detail: me.email ?? "",
            scopes: scopes,
            defaultScope: scopes.first?.id ?? ""
        )
    }

    func deployments(token: String, scope: String, productionOnly: Bool) async throws -> [Deployment] {
        guard !scope.isEmpty else { return [] }
        struct Workspace: Decodable {
            struct W: Decodable {
                struct Projects: Decodable {
                    struct Edge: Decodable { var node: Project }
                    var edges: [Edge]
                }
                var projects: Projects
            }
            var workspace: W
        }
        struct Project: Decodable { var id: String; var name: String; var deletedAt: String? }
        let ws: Workspace = try await gql(token, """
            query ($id: String!) {
              workspace(workspaceId: $id) { projects(first: \(Self.maxProjects)) { edges { node { id name deletedAt } } } }
            }
            """, ["id": scope])
        let projects = ws.workspace.projects.edges.map(\.node).filter { $0.deletedAt == nil }
        if projects.isEmpty { return [] }

        // One request for every project's recent deployments, aliased p0, p1, …
        struct Named: Decodable { var name: String }
        struct Meta: Decodable { var commitMessage: String? }
        struct D: Decodable {
            var id: String
            var status: String
            var createdAt: String
            var projectId: String
            var serviceId: String
            var environmentId: String
            var meta: Meta?
            var service: Named?
            var environment: Named?
        }
        struct Connection: Decodable {
            struct Edge: Decodable { var node: D }
            var edges: [Edge]
        }
        let fields = "id status createdAt meta projectId serviceId environmentId service { name } environment { name }"
        let vars = projects.indices.map { "$p\($0): DeploymentListInput!" }.joined(separator: ", ")
        let body = projects.indices
            .map { "p\($0): deployments(first: 50, input: $p\($0)) { edges { node { \(fields) } } }" }
            .joined(separator: "\n")
        var input: [String: [String: String]] = [:]
        for (i, p) in projects.enumerated() { input["p\(i)"] = ["projectId": p.id] }
        let data: [String: Connection?] = try await gql(token, "query (\(vars)) { \(body) }", input)

        var out: [Deployment] = []
        for (i, p) in projects.enumerated() {
            // Newest first; keep the first live one per service + environment.
            var seen = Set<String>()
            for d in (data["p\(i)"] ?? nil)?.edges.map(\.node) ?? [] {
                let key = d.serviceId + ":" + d.environmentId
                let state = Self.states[d.status] ?? .building
                guard let state, !seen.contains(key) else { continue }
                seen.insert(key)
                let env = d.environment?.name ?? ""
                if productionOnly && env != "production" { continue }
                var url = URLComponents(string: "https://railway.com/project/\(d.projectId)/service/\(d.serviceId)")!
                url.queryItems = [.init(name: "environmentId", value: d.environmentId), .init(name: "id", value: d.id)]
                out.append(Deployment(
                    provider: id,
                    key: key,
                    uid: d.id,
                    project: "\(p.name) / \(d.service?.name ?? "service")",
                    state: state,
                    status: d.status.lowercased().replacingOccurrences(of: "_", with: " "),
                    target: env,
                    created: ISODate.parse(d.createdAt) ?? .distantPast,
                    url: url.url,
                    message: d.meta?.commitMessage?.firstLine
                ))
            }
        }
        return out
    }
}
