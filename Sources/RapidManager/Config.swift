import Foundation

/// The endpoint is intentionally hard-coded so other tools that point at
/// http://127.0.0.1:8000 keep working no matter which model is active.
enum Config {
    static let host = "127.0.0.1"
    static let port = 8000
    static var endpoint: String { "http://\(host):\(port)" }
}
