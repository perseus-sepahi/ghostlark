import Foundation

struct SafetyAssessment {
    var tier: SafetyTier
    var score: Int
    var stealth: Int
    var notes: [String]
    var supported: Bool
}

/// Static, offline assessment of how much protection a node's *protocol stack* gives,
/// and how likely it is to survive deep-packet inspection (DPI). Reliability is measured
/// separately by NodeTester; this only looks at the configuration.
enum SafetyScorer {
    static let aeadCiphers: Set<String> = [
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
    ]
    static let ss2022Ciphers: Set<String> = [
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
    ]
    static let legacyStreamCiphers: Set<String> = [
        "aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
        "rc4-md5", "chacha20-ietf", "chacha20", "xchacha20", "none", "plain",
    ]
    static let commonTLSPorts: Set<Int> = [443, 2053, 2083, 2087, 2096, 8443]

    static func assess(_ n: ProxyNode) -> SafetyAssessment {
        var score = 0
        var stealth = 0
        var notes: [String] = []
        var supported = true

        if !n.transport.supportedBySingBox {
            supported = false
            notes.append("\(n.transport.label) transport is not supported by the sing-box core")
        }

        let tlsVerified = n.security == .tls && !n.insecure
        let tlsUnverified = n.security == .tls && n.insecure
        let webTransport = [.ws, .grpc, .http, .httpupgrade].contains(n.transport)

        switch n.proto {
        case .wireguard:
            score = 92
            stealth = 35
            notes.append("WireGuard to Cloudflare: strong encryption, but the protocol is easy to fingerprint and often throttled")

        case .vless:
            switch n.security {
            case .reality:
                score = 90
                stealth = 95
                notes.append("Reality: TLS 1.3 handshake is indistinguishable from a visit to the decoy site")
                if n.flow?.contains("vision") == true { score += 5; notes.append("XTLS-Vision hides inner TLS-in-TLS patterns") }
                if n.realityPublicKey == nil { supported = false; notes.append("Reality public key missing") }
            case .tls:
                score = tlsVerified ? 76 : 55
                stealth = webTransport ? 78 : 58
                if tlsUnverified { notes.append("Certificate is not verified: the operator or a middlebox could impersonate the server") }
                if n.flow?.contains("vision") == true { stealth += 7 }
            case .none:
                score = 12
                stealth = n.transport == .ws || n.transport == .httpupgrade ? 40 : 10
                notes.append("VLESS without TLS carries your traffic unencrypted between you and the proxy")
            }

        case .vmess:
            switch n.security {
            case .reality: score = 86; stealth = 90
            case .tls:
                score = tlsVerified ? 78 : 58
                stealth = webTransport ? 76 : 55
                if tlsUnverified { notes.append("Certificate is not verified") }
            case .none:
                score = 45
                stealth = webTransport ? 38 : 15
                notes.append("Only VMess's own AEAD layer protects this link; it is fingerprintable and offers no forward secrecy")
            }
            if n.alterId > 0 { score -= 15; notes.append("Legacy non-AEAD VMess (alterId > 0)") }
            let sec = (n.vmessSecurity ?? "auto").lowercased()
            if sec == "none" || sec == "zero" { score -= 25; notes.append("VMess inner encryption disabled") }

        case .trojan:
            switch n.security {
            case .reality: score = 88; stealth = 92
            case .tls:
                score = tlsVerified ? 76 : 55
                stealth = webTransport ? 78 : 62
                if tlsUnverified { notes.append("Certificate is not verified") }
            case .none:
                score = 10; stealth = 10
                notes.append("Trojan without TLS is plaintext")
            }

        case .shadowsocks:
            let m = (n.method ?? "").lowercased()
            if ss2022Ciphers.contains(m) {
                score = 82; stealth = 48
                notes.append("Shadowsocks 2022: AEAD with replay protection")
            } else if aeadCiphers.contains(m) {
                score = 70; stealth = 40
                notes.append("Shadowsocks AEAD: encrypted, but the protocol is well known to DPI")
            } else if legacyStreamCiphers.contains(m) {
                score = 12; stealth = 15
                notes.append("Legacy stream cipher (\(m)): no integrity protection, considered broken")
            } else {
                score = 20; stealth = 20; supported = false
                notes.append("Unknown cipher \(m)")
            }
            if let p = n.plugin, !p.isEmpty {
                if p.contains("obfs") || p.contains("v2ray") { stealth += 15 }
                else { supported = false; notes.append("Unsupported plugin \(p)") }
            }

        case .hysteria2:
            score = n.insecure ? 62 : 82
            stealth = 62
            notes.append("QUIC-based: strong TLS 1.3 encryption, fast, but UDP is often throttled on restricted networks")
            if n.insecure { notes.append("Certificate is not verified") }
            if n.obfsType == "salamander" { stealth += 12; notes.append("Salamander obfuscation hides the QUIC signature") }

        case .tuic:
            score = n.insecure ? 62 : 80
            stealth = 58
            notes.append("QUIC-based (TUIC); UDP is often throttled on restricted networks")
        }

        // Port heuristics: 443-family ports blend in with ordinary HTTPS.
        if n.security != .none && commonTLSPorts.contains(n.port) { stealth += 5 }
        // CDN-fronted WebSocket/gRPC: the server IP belongs to a CDN, the Host header names the real site.
        if webTransport, n.security != .none, let h = n.host ?? n.sni, !h.isEmpty, h.lowercased() != n.server.lowercased(), n.serverIsIP {
            stealth += 5
            notes.append("Likely CDN-fronted: blocking it means blocking the CDN")
        }

        score = max(0, min(100, score))
        stealth = max(0, min(100, stealth))
        let tier: SafetyTier = score >= 85 ? .strong : score >= 65 ? .good : score >= 40 ? .weak : .unsafe
        return SafetyAssessment(tier: tier, score: score, stealth: stealth, notes: notes, supported: supported)
    }
}
