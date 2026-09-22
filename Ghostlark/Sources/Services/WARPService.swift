import Foundation
import CryptoKit

/// A free Cloudflare WARP account: a WireGuard keypair registered with Cloudflare's client API.
struct WARPAccount: Codable, Equatable {
    var id: String
    var token: String
    var privateKey: String
    var publicKey: String
    var v4: String
    var v6: String
    var peerPublicKey: String
    var endpointHost: String
    var endpointPort: Int
    var reserved: [Int]
    var created: Date
}

enum WARPService {
    static let keychainAccount = "warp-account"
    static let apiBase = "https://api.cloudflareclient.com/v0a2158"

    struct RegistrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func load() -> WARPAccount? {
        guard let d = Keychain.load(account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(WARPAccount.self, from: d)
    }

    static func save(_ a: WARPAccount) {
        if let d = try? JSONEncoder().encode(a) { Keychain.save(d, account: keychainAccount) }
    }

    static func reset() { Keychain.delete(account: keychainAccount) }

    /// Registers a new WARP device. `proxyPort` routes the registration through the local
    /// tunnel when set, for networks where Cloudflare's API is blocked.
    static func register(proxyPort: Int?) async throws -> WARPAccount {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let priv = key.rawRepresentation.base64EncodedString()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: Any] = [
            "key": pub, "install_id": "", "fcm_token": "", "tos": fmt.string(from: Date()),
            "model": "PC", "type": "Android", "locale": "en_US",
        ]
        var req = URLRequest(url: URL(string: apiBase + "/reg")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("okhttp/3.12.1", forHTTPHeaderField: "User-Agent")
        req.setValue("a-6.10-2158", forHTTPHeaderField: "CF-Client-Version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let cfg = URLSessionConfiguration.ephemeral
        if let p = proxyPort {
            cfg.connectionProxyDictionary = ProxiedSession.proxyDictionary(port: p)
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw RegistrationError(message: "Cloudflare registration failed (HTTP \(code))")
        }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? String, let token = o["token"] as? String,
              let config = o["config"] as? [String: Any],
              let iface = config["interface"] as? [String: Any],
              let addrs = iface["addresses"] as? [String: Any],
              let v4 = addrs["v4"] as? String, let v6 = addrs["v6"] as? String,
              let peers = config["peers"] as? [[String: Any]], let peer = peers.first,
              let peerKey = peer["public_key"] as? String,
              let endpoint = peer["endpoint"] as? [String: Any],
              let host = endpoint["host"] as? String,
              let clientID = config["client_id"] as? String,
              let reservedData = Data(base64Encoded: clientID) else {
            throw RegistrationError(message: "Unexpected registration response")
        }
        let hp = host.split(separator: ":")
        let endpointHost = hp.count == 2 ? String(hp[0]) : "engage.cloudflareclient.com"
        let endpointPort = hp.count == 2 ? Int(hp[1]) ?? 2408 : 2408
        let account = WARPAccount(id: id, token: token, privateKey: priv, publicKey: pub, v4: v4, v6: v6,
                                  peerPublicKey: peerKey, endpointHost: endpointHost, endpointPort: endpointPort,
                                  reserved: reservedData.map { Int($0) }, created: Date())
        save(account)
        return account
    }

    /// A pseudo-node representing the direct WARP tunnel, so it can sit in the server list.
    static func node() -> ProxyNode {
        var n = ProxyNode(name: "🌐 Cloudflare WARP (free, direct)", proto: .wireguard,
                          server: "engage.cloudflareclient.com", port: 2408,
                          sourceName: "Cloudflare WARP", rawLink: "warp://cloudflare")
        n.id = "warp0000000000000000"
        return n
    }
}

enum ProxiedSession {
    static func proxyDictionary(port: Int) -> [String: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }

    /// A session that goes through the local tunnel when `port` is given, and directly (ignoring
    /// any system proxy) otherwise.
    static func make(port: Int?, timeout: TimeInterval = 25) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = port.map { proxyDictionary(port: $0) } ?? [:]
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: c)
    }
}
