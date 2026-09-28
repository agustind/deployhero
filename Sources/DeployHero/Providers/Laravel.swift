// Laravel Cloud: JSON:API REST, organization API token. A token belongs to
// one organization, so there are no scopes to pick. An entry is one
// environment of an application.

import Foundation

struct Laravel: Provider {
    let id = ProviderID.laravel
    let name = "Laravel Cloud"
    let host = "cloud.laravel.com"
    let scopeLabel: String? = nil
    let tokenURL = URL(string: "https://cloud.laravel.com")!
    let tokenHelp = "Navigate to your Laravel Cloud organization settings, click on the “API tokens” section in the sidebar, then click the “Create API Token” button."
    let dashboard = URL(string: "https://cloud.laravel.com")!

    private static let api = "https://cloud.laravel.com/api"
    private static let maxPages = 5

    private static let states: [String: DeployState?] = [
        "deployment.succeeded": .ready,
        "failed": .error,
        "build.failed": .error,
        "deployment.failed": .error,
        "cancelled": nil,
        // pending, build.*, deployment.pending/created/queued/running → building
    ]

    /// One JSON:API resource; only the attributes and relationships we read.
    struct Resource: Decodable {
        struct Attributes: Decodable {
            var name: String?
            var vanity_domain: String?
            var status: String?
            var created_at: String?
            var started_at: String?
            var finished_at: String?
            var failure_reason: String?
            var commit_message: String?
        }
        struct Ref: Decodable { var id: String }
        struct Relationships: Decodable {
            struct Many: Decodable { var data: [Ref]? }
            struct One: Decodable { var data: Ref? }
            var environments: Many?
            var defaultEnvironment: One?
        }
        var id: String
        var type: String?
        var attributes: Attributes
        var relationships: Relationships?
    }

    struct Page: Decodable {
        struct Links: Decodable { var next: String?; var last: String? }
        struct Meta: Decodable { var last_page: Int? }
        var data: [Resource]?
        var included: [Resource]?
        var links: Links?
        var meta: Meta?
    }

    private func cloud<T: Decodable>(_ token: String, _ path: String) async throws -> T {
        guard let url = URL(string: path.hasPrefix("http") ? path : Self.api + path) else {
            throw APIError(message: "Laravel Cloud sent a bad link")
        }
        return try await HTTP.request(url, auth: "Bearer " + token, label: name)
    }

    private static func isCancelled(_ d: Resource) -> Bool {
        states[d.attributes.status ?? ""] == .some(nil)
    }

    /// When a deployment was made. One with no timestamp at all is the newest
    /// there is if it's still in progress, and the oldest if it already ended
    /// (e.g. it failed before it ever started).
    private static func startedAt(_ d: Resource) -> Double {
        let a = d.attributes
        if let date = ISODate.parse(a.created_at ?? a.started_at ?? a.finished_at) {
            return date.timeIntervalSince1970
        }
        return states[a.status ?? ""] != nil ? -.infinity : .infinity
    }

    private func latestDeployment(_ token: String, envID: String) async throws -> Resource? {
        let page: Page = try await cloud(token, "/environments/\(envID)/deployments")
        var list = page.data ?? []
        // The API doesn't document its order. If page one runs oldest → newest,
        // the latest deployment is on the last page.
        if list.count > 1, (page.meta?.last_page ?? 1) > 1, let last = page.links?.last,
           Self.startedAt(list[0]) < Self.startedAt(list[list.count - 1]) {
            list = (try await cloud(token, last) as Page).data ?? []
        }
        // Like the other platforms, a cancelled deployment doesn't count.
        return list
            .filter { !Self.isCancelled($0) }
            .reduce(nil) { best, d in best.map { Self.startedAt(d) > Self.startedAt($0) ? d : $0 } ?? d }
    }

    func account(token: String) async throws -> Account {
        struct Org: Decodable { var data: Resource }
        let org: Org = try await cloud(token, "/meta/organization")
        return Account(name: org.data.attributes.name ?? "Laravel Cloud", detail: "Organization", scopes: [], defaultScope: "")
    }

    func deployments(token: String, scope: String, productionOnly: Bool) async throws -> [Deployment] {
        var apps: [Resource] = []
        var envs: [String: Resource] = [:]
        var next: String? = "/applications?include=environments,defaultEnvironment"
        for _ in 0..<Self.maxPages {
            guard let path = next else { break }
            let page: Page = try await cloud(token, path)
            apps += page.data ?? []
            for inc in page.included ?? [] where inc.type == "environments" { envs[inc.id] = inc }
            next = page.links?.next
        }

        struct Target { var app: Resource; var env: Resource?; var id: String; var name: String }
        var targets: [Target] = []
        for app in apps {
            let defaultID = app.relationships?.defaultEnvironment?.data?.id
            for ref in app.relationships?.environments?.data ?? [] {
                let env = envs[ref.id]
                let name = env?.attributes.name ?? "environment"
                if productionOnly && ref.id != defaultID && name != "production" { continue }
                targets.append(Target(app: app, env: env, id: ref.id, name: name))
            }
        }

        let latest = try await withThrowingTaskGroup(of: (Int, Resource?).self) { group in
            for (i, t) in targets.enumerated() {
                group.addTask { (i, try await latestDeployment(token, envID: t.id)) }
            }
            var out = [Resource?](repeating: nil, count: targets.count)
            for try await (i, d) in group { out[i] = d }
            return out
        }

        var out: [Deployment] = []
        for (t, d) in zip(targets, latest) {
            guard let d else { continue }
            let a = d.attributes
            let status = a.status ?? ""
            guard let state = Self.states[status] ?? .building else { continue }
            let domain = t.env?.attributes.vanity_domain.flatMap { $0.isEmpty ? nil : $0 }
            let failure = state == .error ? a.failure_reason.flatMap { $0.isEmpty ? nil : $0 } : nil
            out.append(Deployment(
                provider: id,
                key: t.id,
                uid: d.id,
                project: t.app.attributes.name ?? "application",
                state: state,
                status: status.replacingOccurrences(of: ".", with: " "),
                target: t.name,
                created: ISODate.parse(a.started_at ?? a.finished_at) ?? Date(),
                url: domain.flatMap { URL(string: "https://" + $0) } ?? dashboard,
                message: failure ?? a.commit_message?.firstLine
            ))
        }
        return out
    }
}
