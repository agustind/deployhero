// Shared request helper for the platform APIs. Throws an APIError carrying
// `status` and `auth` (true only for a 401, i.e. a dead token) so callers can
// tell "sign out" apart from "try again later".

import Foundation

struct APIError: LocalizedError, Sendable {
    var message: String
    var status: Int? = nil
    var auth = false
    var body: Data? = nil

    var errorDescription: String? { message }
}

enum HTTP {
    static func request<T: Decodable>(
        _ url: URL,
        auth: String,
        method: String = "GET",
        json body: (any Encodable)? = nil,
        label: String
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError(message: "\(label) API sent an unexpected response", status: status)
            }
        }
        let err = try? JSONDecoder().decode(ErrorBody.self, from: data)
        throw APIError(
            message: err?.error?.message ?? err?.message ?? "\(label) API \(status)",
            status: status,
            auth: status == 401,
            body: data
        )
    }

    static func query(_ params: [String: String?]) -> [URLQueryItem] {
        params.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
            .sorted { $0.name < $1.name }
    }
}

private struct ErrorBody: Decodable {
    struct Inner: Decodable { var message: String? }
    var error: Inner?
    var message: String?
}

// MARK: - GraphQL

struct GraphQLBody<V: Encodable>: Encodable {
    var query: String
    var variables: V
}

struct GraphQLResponse<T: Decodable>: Decodable {
    struct Err: Decodable { var message: String }
    var data: T?
    var errors: [Err]?
}

// MARK: - Dates

enum ISODate {
    /// ISO 8601 with or without fractional seconds (any precision), or
    /// "yyyy-MM-dd HH:mm:ss" in UTC.
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let noFraction = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if let d = try? Date(noFraction, strategy: .iso8601) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: noFraction)
    }
}

extension String {
    /// The first line, for commit messages.
    var firstLine: String { split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? self }
}
