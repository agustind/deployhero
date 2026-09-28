// Every platform the app can watch. A provider knows its identity (and the
// only host its token is sent to), where to create a token, how to read the
// account behind a token, and how to fetch the latest deployment per project.
//
// Errors with `auth == true` mean the token is dead and the platform gets
// disconnected.

import Foundation

enum ProviderID: String, CaseIterable, Codable, Sendable {
    case vercel, railway, laravel, fly

    var provider: any Provider {
        switch self {
        case .vercel: Vercel()
        case .railway: Railway()
        case .laravel: Laravel()
        case .fly: Fly()
        }
    }
}

enum DeployState: Sendable {
    case ready, error, building
}

struct Scope: Hashable, Sendable {
    var id: String
    var name: String
    var slug: String?
}

struct Account: Sendable {
    var name: String
    var detail: String
    var scopes: [Scope]
    var defaultScope: String
}

/// The latest deployment of one project (or service × environment, …).
struct Deployment: Hashable, Sendable {
    var provider: ProviderID
    var key: String          // stable per project within the provider
    var uid: String          // this deployment
    var project: String
    var state: DeployState
    var status: String
    var target: String
    var created: Date
    var url: URL?
    var message: String?

    /// "<provider>:<key>", what the watch list stores.
    var watchKey: String { provider.rawValue + ":" + key }
    var uniqueID: String { provider.rawValue + ":" + uid }
}

protocol Provider: Sendable {
    var id: ProviderID { get }
    var name: String { get }
    var host: String { get }
    /// What its scopes are called; nil: no picker.
    var scopeLabel: String? { get }
    var tokenURL: URL { get }
    var tokenHelp: String { get }
    var dashboard: URL { get }

    func account(token: String) async throws -> Account
    func deployments(token: String, scope: String, productionOnly: Bool) async throws -> [Deployment]
    func dashboardURL(account: Account?, scope: String) -> URL
}

extension Provider {
    func dashboardURL(account: Account?, scope: String) -> URL { dashboard }
}
