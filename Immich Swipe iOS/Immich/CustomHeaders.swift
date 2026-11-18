import Foundation

/// Extra request headers a user can add to an account, for servers behind a proxy that wants its own, such as
/// Cloudflare Access. Stored as "Name: value" lines.
nonisolated enum CustomHeaders {
    /// Set by the app or the HTTP stack itself, so a value from the user would only break requests.
    private static let reserved: Set<String> = [
        "x-api-key", "host", "content-length", "connection", "transfer-encoding", "upgrade", "te", "trailer",
    ]

    /// The characters an HTTP header name may use (a "token").
    private static let nameCharacters = Set("!#$%&'*+.^_`|~-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy(nameCharacters.contains) && !reserved.contains(name.lowercased())
    }

    /// Visible ASCII, space and tab only: anything else can't be sent in a header value.
    static func isValidValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0 == "\t" || ($0.value >= 0x20 && $0.value <= 0x7E) }
    }

    /// The headers for these name and value pairs, or nil when one is invalid or a name repeats. A row with
    /// both parts blank is skipped, so an untouched row is not an error.
    static func fromEntries(_ entries: [(name: String, value: String)]) -> [String: String]? {
        var result: [String: String] = [:]
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            let value = entry.value.trimmingCharacters(in: .whitespaces)
            if name.isEmpty && value.isEmpty { continue }
            guard isValidName(name), isValidValue(value) else { return nil }
            guard !result.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            result[name] = value
        }
        return result
    }

    /// The stored form, or nil when there are no headers.
    static func encode(_ headers: [String: String]) -> String? {
        let text = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// The headers in a stored value; a line that is not a valid header is dropped.
    static func parse(_ stored: String?) -> [String: String] {
        var result: [String: String] = [:]
        for line in (stored ?? "").split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if isValidName(name), isValidValue(value) { result[name] = value }
        }
        return result
    }
}
