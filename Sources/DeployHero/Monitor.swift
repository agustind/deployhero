// The app's state: tokens (Keychain), polling each connected platform, the
// traffic light and notifications. The status item and the settings window
// both render from it.

import Foundation
import Observation

enum Light {
    case green, yellow, red, gray
}

@MainActor @Observable
final class Monitor {
    /// A connected platform.
    struct Connection {
        var token: String
        var account: Account?
        var error: String?
        var items: [Deployment] = []
    }

    static let pollIdle: Duration = .seconds(60)   // nothing in flight
    static let pollBusy: Duration = .seconds(10)   // something is building — check more often

    private(set) var conns: [ProviderID: Connection] = [:]
    private(set) var settings: Settings
    /// Latest deployment per project, all platforms, newest first.
    private(set) var projects: [Deployment] = []
    private(set) var light = Light.gray
    private(set) var lastChecked: Date?

    /// Something to show in the settings window: a token died.
    @ObservationIgnored var onSignedOut: () -> Void = {}
    @ObservationIgnored var notify: (_ title: String, _ body: String, _ url: URL?) -> Void = { _, _, _ in }

    @ObservationIgnored private var timer: Task<Void, Never>?
    /// uid → (state, watch key), for "finished" notifications.
    @ObservationIgnored private var seenStates: [String: (state: DeployState, key: String)]?

    private static func tokenKey(_ id: ProviderID) -> String { id.rawValue + "-token" }

    init() {
        settings = Settings.load()
        for id in ProviderID.allCases {
            if let token = Keychain.get(Self.tokenKey(id)) { conns[id] = Connection(token: token) }
        }
    }

    var connected: [ProviderID] { ProviderID.allCases.filter { conns[$0] != nil } }
    var errors: [(ProviderID, String)] { connected.compactMap { id in conns[id]?.error.map { (id, $0) } } }
    func scope(of id: ProviderID) -> String { settings.scopes[id.rawValue] ?? "" }

    // MARK: - Deployments

    private func loadAccount(_ id: ProviderID) async throws {
        guard let token = conns[id]?.token else { return }
        let account = try await id.provider.account(token: token)
        guard conns[id]?.token == token else { return }   // disconnected meanwhile
        conns[id]?.account = account
        if account.scopes.isEmpty {
            settings.scopes[id.rawValue] = ""
        } else if !account.scopes.contains(where: { $0.id == settings.scopes[id.rawValue] }) {
            settings.scopes[id.rawValue] = account.defaultScope
        }
    }

    /// Returns true when the token turned out dead and the platform was disconnected.
    private func refreshOne(_ id: ProviderID) async -> Bool {
        guard let token = conns[id]?.token else { return false }
        do {
            if conns[id]?.account == nil { try await loadAccount(id) }
            let items = try await id.provider.deployments(
                token: token, scope: scope(of: id), productionOnly: settings.productionOnly)
            guard conns[id]?.token == token else { return false }
            conns[id]?.items = items
            conns[id]?.error = nil
        } catch {
            guard conns[id]?.token == token else { return false }
            conns[id]?.items = []
            conns[id]?.error = error.localizedDescription
            if (error as? APIError)?.auth == true {
                disconnect(id)
                return true
            }
        }
        return false
    }

    func isWatched(_ key: String) -> Bool { settings.watch?.contains(key) ?? true }

    private func computeLight() -> Light {
        let ids = connected
        // Every platform unreachable: we know nothing.
        if ids.isEmpty || ids.allSatisfy({ conns[$0]?.error != nil }) { return .gray }
        let list = projects.filter { isWatched($0.watchKey) }
        if list.contains(where: { $0.state == .error }) { return .red }
        if list.contains(where: { $0.state == .building }) { return .yellow }
        return list.isEmpty ? .gray : .green
    }

    // MARK: - Polling

    func refresh() async {
        timer?.cancel()
        timer = nil
        let signedOut = await withTaskGroup(of: Bool.self) { group in
            for id in connected { group.addTask { await self.refreshOne(id) } }
            var any = false
            for await out in group { any = any || out }
            return any
        }
        projects = connected
            .flatMap { conns[$0]?.items ?? [] }
            .sorted { $0.created > $1.created }
        notifyFinished(projects)
        light = computeLight()
        lastChecked = Date()
        if signedOut { onSignedOut() }
        if connected.isEmpty { return }
        timer?.cancel()   // an overlapping refresh may have scheduled one
        let delay = light == .yellow ? Self.pollBusy : Self.pollIdle
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil   // so refresh() doesn't cancel the task it runs in
            await self.refresh()
        }
    }

    func pause() {
        timer?.cancel()
        timer = nil
    }

    /// A notification when a deployment lands (or fails): one we saw building,
    /// or a new deployment of a known project that started and finished
    /// between polls.
    private func notifyFinished(_ next: [Deployment]) {
        let prev = seenStates
        let prevAt = lastChecked ?? .distantPast
        seenStates = Dictionary(next.map { ($0.uniqueID, ($0.state, $0.watchKey)) }, uniquingKeysWith: { a, _ in a })
        guard let prev else { return }   // first poll after launch/connect — don't spam history
        let knownKeys = Set(prev.values.map(\.key))
        for p in next where p.state != .building {
            let before = prev[p.uniqueID]?.state
            let sawBuilding = before == .building
            let newSincePoll = before == nil && knownKeys.contains(p.watchKey) && p.created > prevAt
            guard sawBuilding || newSincePoll else { continue }
            let where_ = p.provider.provider.name
            if p.state == .error {
                notify("❌ \(p.project) failed", p.message ?? "\(where_) deployment errored", p.url)
            } else {
                notify("✅ \(p.project) deployed", p.message ?? "\(p.target) is live on \(where_)", p.url)
            }
        }
    }

    // MARK: - Actions

    func connect(_ id: ProviderID, token raw: String) async throws {
        let p = id.provider
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError(message: "Paste a \(p.name) token first") }
        let prev = conns[id]
        conns[id] = Connection(token: token)
        do {
            try await loadAccount(id)
        } catch {
            conns[id] = prev
            if let e = error as? APIError, e.auth, e.message.range(of: "token", options: .caseInsensitive) == nil {
                throw APIError(message: "That token was rejected by \(p.name)")
            }
            throw error
        }
        try Keychain.set(Self.tokenKey(id), token)
        settings.save()
        seenStates = nil
        await refresh()
    }

    func disconnect(_ id: ProviderID) {
        conns[id] = nil
        settings.scopes[id.rawValue] = nil
        unwatch(id)
        projects.removeAll { $0.provider == id }
        seenStates = nil
        light = computeLight()
        if connected.isEmpty { pause() }
        Keychain.delete(Self.tokenKey(id))
        settings.save()
    }

    func setScope(_ scope: String, for id: ProviderID) async {
        guard conns[id] != nil, scope != self.scope(of: id) else { return }
        settings.scopes[id.rawValue] = scope
        unwatch(id)   // project keys don't carry across scopes
        await settingsChanged()
    }

    func setProductionOnly(_ on: Bool) async {
        settings.productionOnly = on
        await settingsChanged()
    }

    private func settingsChanged() async {
        settings.save()
        seenStates = nil
        await refresh()
    }

    /// Picking a project while following all narrows to just it; after that,
    /// clicks toggle. Unticking the last one goes back to all. nil follows all.
    /// Only the light changes — no need to hit the APIs again.
    func toggleWatch(_ key: String?) {
        if let key, let watch = settings.watch {
            settings.watch = watch.contains(key) ? watch.filter { $0 != key } : watch + [key]
        } else {
            settings.watch = key.map { [$0] }
        }
        if settings.watch?.isEmpty == true { settings.watch = nil }
        settings.save()
        light = computeLight()
    }

    /// Forget a platform's projects from the watch list (scope change, disconnect).
    private func unwatch(_ id: ProviderID) {
        guard let watch = settings.watch else { return }
        let rest = watch.filter { !$0.hasPrefix(id.rawValue + ":") }
        settings.watch = rest.isEmpty ? nil : rest
    }

    // MARK: - Labels

    func label(ofKey key: String) -> String {
        projects.first { $0.watchKey == key }?.project
            ?? key.split(separator: ":", maxSplits: 1).dropFirst().joined()
    }

    /// "saturn-app: ready" when the light follows one project, else the roll-up.
    var summary: String {
        if let watch = settings.watch, watch.count == 1 {
            let single: [Light: String] = [.green: "ready", .yellow: "building…", .red: "failed", .gray: "no deployments"]
            return label(ofKey: watch[0]) + ": " + single[light]!
        }
        switch light {
        case .green: return "All deployments ready"
        case .yellow: return "Deployment in progress…"
        case .red: return "A deployment failed"
        case .gray: return "No deployments"
        }
    }

    var followsLabel: String {
        guard let watch = settings.watch else { return "All projects" }
        return watch.count == 1 ? label(ofKey: watch[0]) : "\(watch.count) projects"
    }

    func scopeName(_ id: ProviderID) -> String {
        let account = conns[id]?.account
        return account?.scopes.first { $0.id == scope(of: id) }?.name ?? account?.name ?? ""
    }

    func dashboardURL(_ id: ProviderID) -> URL {
        id.provider.dashboardURL(account: conns[id]?.account, scope: scope(of: id))
    }
}

extension Deployment {
    /// "saturn-app (staging)": the environment, when it isn't the obvious one.
    var displayName: String {
        let obvious = target.range(of: #"^(production|preview|v\d+)$"#, options: .regularExpression) != nil
        return project + (target.isEmpty || obvious ? "" : " (\(target))")
    }
}

func ago(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date).rounded()))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}
