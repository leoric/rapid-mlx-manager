import Foundation

/// Endpoint of the managed server. Defaults to http://127.0.0.1:8000 and can be
/// changed in Settings (passed to rapid-mlx as --host / --port).
enum Config {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8000

    static var host: String {
        let h = (UserDefaults.standard.string(forKey: "host") ?? "").trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? defaultHost : h
    }

    static var port: Int {
        if let s = UserDefaults.standard.string(forKey: "port"),
           let n = Int(s.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) { return n }
        return defaultPort
    }

    /// Address to connect to when checking whether the server is up.
    static var probeHost: String {
        switch host {
        case "0.0.0.0": return "127.0.0.1"
        case "::", "[::]": return "::1"
        default: return host
        }
    }

    static var endpoint: String { "http://\(host):\(port)" }
}
