import Foundation

/// Minimal client for sing-box's Clash-compatible control API.
struct ClashAPI {
    let port: Int
    let secret: String

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A session that ignores the system proxy so control traffic never loops through the tunnel.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = timeout
        return r
    }

    func waitReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, resp) = try? await ClashAPI.session.data(for: request("/version", timeout: 2)),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    /// Runs a connectivity test through one outbound. Returns latency in ms.
    func delay(tag: String, url: String, timeoutMs: Int) async throws -> Int {
        var comps = URLComponents(string: "http://127.0.0.1:\(port)/proxies/\(tag)/delay")!
        comps.queryItems = [URLQueryItem(name: "timeout", value: String(timeoutMs)), URLQueryItem(name: "url", value: url)]
        var r = URLRequest(url: comps.url!)
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = TimeInterval(timeoutMs) / 1000 + 5
        let (data, resp) = try await ClashAPI.session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["delay"] as? Int else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw APIError(message: code == 504 ? "timeout" : (msg ?? "HTTP \(code)"))
        }
        return d
    }

    /// The member a urltest/selector group is currently using.
    func groupNow(tag: String) async -> String? {
        guard let (data, _) = try? await ClashAPI.session.data(for: request("/proxies/\(tag)", timeout: 5)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o["now"] as? String
    }

    /// Streams (upBytesPerSec, downBytesPerSec) samples.
    func trafficStream() -> AsyncThrowingStream<(Int, Int), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await ClashAPI.session.bytes(for: request("/traffic", timeout: 3600 * 24))
                    for try await line in bytes.lines {
                        if let d = line.data(using: .utf8),
                           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            continuation.yield((o["up"] as? Int ?? 0, o["down"] as? Int ?? 0))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
