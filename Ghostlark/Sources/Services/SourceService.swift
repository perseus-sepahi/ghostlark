import Foundation

enum SourceService {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Fetches a subscription, racing the original URL against CDN mirrors and taking the
    /// first success. When `proxyPort` is set the request goes through the local tunnel.
    static func fetch(_ src: SubscriptionSource, proxyPort: Int?) async throws -> String {
        let urls = src.mirrorURLs.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { throw FetchError(message: "Invalid URL") }
        let session = ProxiedSession.make(port: proxyPort, timeout: 30)

        return try await withThrowingTaskGroup(of: String?.self) { group in
            for u in urls {
                group.addTask {
                    var req = URLRequest(url: u)
                    req.setValue("Ghostlark/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
                    req.cachePolicy = .reloadIgnoringLocalCacheData
                    guard let (data, resp) = try? await session.data(for: req),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200,
                          let text = String(data: data, encoding: .utf8), text.count > 20 else { return nil }
                    return text
                }
            }
            var lastError = "All mirrors failed"
            while let r = try await group.next() {
                if let text = r {
                    group.cancelAll()
                    return text
                }
            }
            _ = lastError
            lastError = "All mirrors failed or returned empty"
            throw FetchError(message: lastError)
        }
    }
}
