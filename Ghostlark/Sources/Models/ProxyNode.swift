import Foundation
import CryptoKit

enum ProxyProtocol: String, Codable, CaseIterable, Hashable {
    case vless, vmess, trojan, shadowsocks, hysteria2, tuic, wireguard

    var label: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        case .hysteria2: return "Hysteria2"
        case .tuic: return "TUIC"
        case .wireguard: return "WireGuard"
        }
    }
}

enum TLSMode: String, Codable, Hashable {
    case none, tls, reality
    var label: String {
        switch self {
        case .none: return "No TLS"
        case .tls: return "TLS"
        case .reality: return "Reality"
        }
    }
}

enum TransportKind: String, Codable, Hashable {
    case tcp, ws, grpc, http, httpupgrade, xhttp, kcp, quic

    /// sing-box does not implement Xray-only transports.
    var supportedBySingBox: Bool {
        switch self {
        case .xhttp, .kcp, .quic: return false
        default: return true
        }
    }
    var label: String { rawValue.uppercased() }
}

enum TestOutcome: Codable, Hashable {
    case untested
    case ok(Int)
    case failed(String)

    var latency: Int? { if case .ok(let ms) = self { return ms }; return nil }
    var isOK: Bool { latency != nil }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

enum SafetyTier: String, Codable, Hashable, Comparable, CaseIterable {
    case unsafe, weak, good, strong

    var order: Int {
        switch self {
        case .unsafe: return 0
        case .weak: return 1
        case .good: return 2
        case .strong: return 3
        }
    }
    static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool { lhs.order < rhs.order }

    var label: String {
        switch self {
        case .unsafe: return "Unsafe"
        case .weak: return "Weak"
        case .good: return "Good"
        case .strong: return "Strong"
        }
    }
}

struct ProxyNode: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var proto: ProxyProtocol
    var server: String
    var port: Int

    // Credentials
    var uuid: String?
    var password: String?
    var method: String?
    var flow: String?

    // TLS
    var security: TLSMode
    var sni: String?
    var alpn: [String]
    var fingerprint: String?
    var insecure: Bool
    var realityPublicKey: String?
    var realityShortId: String?

    // Transport
    var transport: TransportKind
    var path: String?
    var host: String?
    var serviceName: String?

    // Protocol specifics
    var obfsType: String?
    var obfsPassword: String?
    var congestionControl: String?
    var udpRelayMode: String?
    var alterId: Int
    var vmessSecurity: String?
    var plugin: String?
    var pluginOpts: String?

    // Provenance
    var sourceName: String
    var rawLink: String
    var firstSeen: Date
    var lastSeen: Date

    // Static assessment (filled by SafetyScorer at parse time)
    var tier: SafetyTier
    var safetyScore: Int
    var stealthScore: Int
    var notes: [String]
    var supported: Bool

    // Runtime / history
    var test: TestOutcome
    var lastTested: Date?
    var okCount: Int
    var failCount: Int
    /// Whether WARP-over-proxy (Shield) has been verified to work through this server.
    var shieldCapable: Bool?

    init(name: String, proto: ProxyProtocol, server: String, port: Int,
         uuid: String? = nil, password: String? = nil, method: String? = nil, flow: String? = nil,
         security: TLSMode = .none, sni: String? = nil, alpn: [String] = [], fingerprint: String? = nil,
         insecure: Bool = false, realityPublicKey: String? = nil, realityShortId: String? = nil,
         transport: TransportKind = .tcp, path: String? = nil, host: String? = nil, serviceName: String? = nil,
         obfsType: String? = nil, obfsPassword: String? = nil, congestionControl: String? = nil,
         udpRelayMode: String? = nil, alterId: Int = 0, vmessSecurity: String? = nil,
         plugin: String? = nil, pluginOpts: String? = nil,
         sourceName: String, rawLink: String) {
        self.name = name
        self.proto = proto
        self.server = server
        self.port = port
        self.uuid = uuid
        self.password = password
        self.method = method
        self.flow = flow
        self.security = security
        self.sni = sni
        self.alpn = alpn
        self.fingerprint = fingerprint
        self.insecure = insecure
        self.realityPublicKey = realityPublicKey
        self.realityShortId = realityShortId
        self.transport = transport
        self.path = path
        self.host = host
        self.serviceName = serviceName
        self.obfsType = obfsType
        self.obfsPassword = obfsPassword
        self.congestionControl = congestionControl
        self.udpRelayMode = udpRelayMode
        self.alterId = alterId
        self.vmessSecurity = vmessSecurity
        self.plugin = plugin
        self.pluginOpts = pluginOpts
        self.sourceName = sourceName
        self.rawLink = rawLink
        let now = Date()
        self.firstSeen = now
        self.lastSeen = now
        self.tier = .weak
        self.safetyScore = 0
        self.stealthScore = 0
        self.notes = []
        self.supported = true
        self.test = .untested
        self.lastTested = nil
        self.okCount = 0
        self.failCount = 0
        self.id = ProxyNode.makeID(proto: proto, server: server, port: port,
                                   credential: uuid ?? password ?? "", transport: transport,
                                   path: path ?? serviceName ?? "", sni: sni ?? host ?? "")
        let a = SafetyScorer.assess(self)
        self.tier = a.tier
        self.safetyScore = a.score
        self.stealthScore = a.stealth
        self.notes = a.notes
        self.supported = a.supported
    }

    static func makeID(proto: ProxyProtocol, server: String, port: Int, credential: String,
                       transport: TransportKind, path: String, sni: String) -> String {
        let key = "\(proto.rawValue)|\(server.lowercased())|\(port)|\(credential)|\(transport.rawValue)|\(path)|\(sni.lowercased())"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Outbound tag used inside sing-box configs.
    var tag: String { "n" + id }
    var isWARP: Bool { proto == .wireguard }

    var serverIsIP: Bool {
        if server.contains(":") { return true }
        let parts = server.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    /// The SNI sing-box should present, following the usual client precedence.
    var effectiveSNI: String? {
        if let s = sni, !s.isEmpty { return s }
        if let h = host, !h.isEmpty { return h }
        return serverIsIP ? nil : server
    }

    var countryFlag: String? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        for i in 0..<(scalars.count - 1) {
            let a = scalars[i].value, b = scalars[i + 1].value
            if (0x1F1E6...0x1F1FF).contains(a) && (0x1F1E6...0x1F1FF).contains(b) {
                var s = String.UnicodeScalarView()
                s.append(scalars[i]); s.append(scalars[i + 1])
                return String(s)
            }
        }
        return nil
    }

    var countryCode: String? {
        guard let flag = countryFlag else { return nil }
        let letters = flag.unicodeScalars.map { Character(UnicodeScalar($0.value - 0x1F1E6 + 65)!) }
        return String(letters)
    }

    var reliability: Double {
        let total = okCount + failCount
        return total == 0 ? 0.5 : Double(okCount) / Double(total)
    }

    /// Composite ranking used to pick the "best" server. Higher is better.
    /// Decoy hostnames of companies that serve from their own IP ranges. A Reality handshake naming one
    /// of these while the server sits on a random VPS IP is an SNI/IP mismatch a censor can check cheaply.
    static let selfHostedDecoys = ["apple.com", "icloud.com", "microsoft.com", "live.com", "bing.com", "google.com",
        "gstatic.com", "youtube.com", "amazon.com", "cloudflare.com", "facebook.com", "instagram.com",
        "whatsapp.com", "yahoo.com", "samsung.com", "speedtest.net", "twitter.com", "x.com"]

    var decoyMismatchRisk: Bool {
        guard security == .reality, let s = (sni ?? host)?.lowercased() else { return false }
        return ProxyNode.selfHostedDecoys.contains { s == $0 || s.hasSuffix("." + $0) }
    }

    var isWebTransport: Bool { [.ws, .grpc, .http, .httpupgrade].contains(transport) }

    var cdnFronted: Bool {
        guard isWebTransport, security != .none, serverIsIP, let h = host ?? sni, !h.isEmpty else { return false }
        return h.lowercased() != server.lowercased()
    }

    /// Extra Stealth only accepts traffic that looks like ordinary HTTPS to a plausible site:
    /// Reality, or verified TLS carrying WebSocket/gRPC/HTTPUpgrade (or XTLS-Vision) on a standard HTTPS port.
    /// Shadowsocks, bare VMess, QUIC protocols, direct WireGuard and unverified certificates are excluded.
    var extraStealthEligible: Bool {
        guard supported, !isWARP else { return false }
        guard proto == .vless || proto == .trojan || proto == .vmess else { return false }
        if security == .reality { return realityPublicKey != nil }
        guard security == .tls, !insecure, SafetyScorer.commonTLSPorts.contains(port) else { return false }
        return isWebTransport || (flow?.contains("vision") ?? false)
    }

    var extraStealthScore: Int {
        var s = stealthScore
        if decoyMismatchRisk { s -= 12 }
        if cdnFronted { s += 4 }
        if !serverIsIP { s -= 4 }          // the proxy's hostname is resolved through the ISP's DNS
        if flow?.contains("vision") ?? false { s += 3 }
        return max(0, min(100, s))
    }

    func rank(stealthWeighted: Bool, shield: Bool = false, extra: Bool = false) -> Double {
        var r = Double(safetyScore) * 3 + Double(extra ? extraStealthScore : stealthScore) * (stealthWeighted ? 2.5 : 1)
        r += reliability * 120
        if shield, let s = shieldCapable { r += s ? 300 : -300 }
        switch test {
        case .ok(let ms): r += 1000 - Double(min(ms, 3000)) / 6
        case .failed: r -= 800
        case .untested: break
        }
        return r
    }

    var securityBadge: String {
        switch security {
        case .reality: return "Reality"
        case .tls: return insecure ? "TLS (unverified)" : "TLS"
        case .none: return proto == .hysteria2 || proto == .tuic || proto == .wireguard ? "Encrypted" : "Plain"
        }
    }
}
