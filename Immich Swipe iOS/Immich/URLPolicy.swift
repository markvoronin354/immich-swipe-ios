import Foundation

/// Decides whether a server URL needs a warning before the API key is sent to it.
///
/// Plain HTTP is fine on a private network, the main self-hosting case. HTTP to a host on the
/// public internet sends the API key unencrypted, so the user has to confirm it first.
nonisolated enum URLPolicy {
    /// Names that only resolve inside a private network or an encrypted tailnet.
    private static let privateSuffixes = [".local", ".lan", ".home.arpa", ".internal", ".localdomain", ".ts.net"]

    /// True when `url` uses plain HTTP to a host that isn't recognisably on a private network.
    static func isInsecureRemote(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false) else { return false }
        return !isPrivateHost(host)
    }

    static func isPrivateHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }

        if h == "localhost" || (!h.contains(".") && !h.contains(":")) { return true }
        if privateSuffixes.contains(where: h.hasSuffix) { return true }

        let octets = h.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        if octets.count == 4, h.split(separator: ".").count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            let (a, b) = (octets[0], octets[1])
            return a == 10
                || a == 127
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
                || (a == 100 && (64...127).contains(b)) // carrier-grade NAT, also used by Tailscale
        }

        // IPv6 literal: loopback, unique local (fc00::/7) and link local (fe80::/10).
        guard h.contains(":") else { return false }
        return h == "::1" || h.hasPrefix("fc") || h.hasPrefix("fd")
            || ["fe8", "fe9", "fea", "feb"].contains(where: h.hasPrefix)
    }
}
