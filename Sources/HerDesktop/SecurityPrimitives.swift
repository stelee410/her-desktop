import Foundation

/// Small shared helpers for the loopback servers' defensive checks.
enum SecurityPrimitives {
    /// Constant-time string equality for token comparison. Swift's `==`
    /// short-circuits on the first differing byte, which leaks timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }

    /// True when an HTTP Host header refers to this machine's loopback.
    /// A DNS-rebinding page (attacker domain resolving to 127.0.0.1) reaches
    /// loopback listeners with the attacker's domain in Host — reject it.
    static func isLoopbackHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        // Strip an optional port ("127.0.0.1:8799", "[::1]:8799"). A bare
        // unbracketed IPv6 ("::1") contains multiple colons and carries no
        // port — stripping at the last colon would mangle it, so only strip
        // when there is exactly one colon.
        if host.hasPrefix("[") {
            host = String(host.dropFirst())
            if let end = host.firstIndex(of: "]") {
                host = String(host[..<end])
            }
        } else if host.filter({ $0 == ":" }).count == 1,
                  let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
