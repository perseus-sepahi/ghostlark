import Foundation

/// Builds sing-box 1.14 JSON configurations from ProxyNodes and settings.
///
/// `auto_detect_interface` stays off on macOS: Ghostlark runs as a system proxy, not a TUN, so the core's own
/// connections can never loop back into it. Binding to the physical interface would only break Ghostlark when
/// another VPN (Cloudflare WARP, Proton, …) owns the default route and drops traffic that bypasses it.
enum SingBoxConfig {

    static let warpPeerPublicKey = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    struct Options {
        var stealth: Bool
        var fragment: Bool
        var fragmentReality: Bool
        var fingerprint: String
    }

    // MARK: Outbound for one node

    static func outbound(for node: ProxyNode, tag: String, opts: Options) -> [String: Any] {
        var o: [String: Any] = ["tag": tag, "server": node.server, "server_port": node.port]

        switch node.proto {
        case .vless:
            o["type"] = "vless"
            o["uuid"] = node.uuid ?? ""
            if let f = node.flow, !f.isEmpty { o["flow"] = f }
            o["packet_encoding"] = "xudp"
        case .vmess:
            o["type"] = "vmess"
            o["uuid"] = node.uuid ?? ""
            o["security"] = node.vmessSecurity ?? "auto"
            o["alter_id"] = node.alterId
            o["packet_encoding"] = "xudp"
        case .trojan:
            o["type"] = "trojan"
            o["password"] = node.password ?? ""
        case .shadowsocks:
            o["type"] = "shadowsocks"
            o["method"] = node.method ?? "aes-256-gcm"
            o["password"] = node.password ?? ""
            if let p = node.plugin { o["plugin"] = p; o["plugin_opts"] = node.pluginOpts ?? "" }
        case .hysteria2:
            o["type"] = "hysteria2"
            o["password"] = node.password ?? ""
            if let t = node.obfsType { o["obfs"] = ["type": t, "password": node.obfsPassword ?? ""] }
        case .tuic:
            o["type"] = "tuic"
            o["uuid"] = node.uuid ?? ""
            o["password"] = node.password ?? ""
            o["congestion_control"] = node.congestionControl ?? "bbr"
            o["udp_relay_mode"] = node.udpRelayMode ?? "native"
        case .wireguard:
            // WireGuard is an endpoint, not an outbound; handled by warpEndpoint().
            o["type"] = "direct"
            return o
        }

        // TLS
        let needsTLS = node.security != .none || node.proto == .hysteria2 || node.proto == .tuic
        if needsTLS {
            var tls: [String: Any] = ["enabled": true]
            if let sni = node.effectiveSNI { tls["server_name"] = sni }
            if node.insecure { tls["insecure"] = true }
            if !node.alpn.isEmpty { tls["alpn"] = node.alpn }
            let isQUIC = node.proto == .hysteria2 || node.proto == .tuic
            if !isQUIC {
                tls["utls"] = ["enabled": true, "fingerprint": normalizeFingerprint(node.fingerprint) ?? opts.fingerprint]
            }
            if node.security == .reality, let pbk = node.realityPublicKey {
                var r: [String: Any] = ["enabled": true, "public_key": pbk]
                if let sid = node.realityShortId, !sid.isEmpty { r["short_id"] = sid }
                tls["reality"] = r
            }
            // TLS ClientHello fragmentation defeats SNI-based blocking of the *proxy server itself*.
            if opts.fragment && !isQUIC && (node.security != .reality || opts.fragmentReality) {
                tls["fragment"] = true
                tls["record_fragment"] = true
            }
            o["tls"] = tls
        }

        // Transport
        switch node.transport {
        case .ws:
            var t: [String: Any] = ["type": "ws"]
            var path = node.path ?? "/"
            if let q = path.range(of: "?ed=") {
                let ed = Int(path[q.upperBound...].prefix { $0.isNumber }) ?? 2048
                path = String(path[..<q.lowerBound])
                t["max_early_data"] = ed
                t["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            t["path"] = path.isEmpty ? "/" : path
            if let h = node.host, !h.isEmpty { t["headers"] = ["Host": h] }
            o["transport"] = t
        case .grpc:
            o["transport"] = ["type": "grpc", "service_name": node.serviceName ?? node.path ?? ""]
        case .http:
            var t: [String: Any] = ["type": "http", "path": node.path ?? "/"]
            if let h = node.host, !h.isEmpty { t["host"] = h.split(separator: ",").map { String($0) } }
            o["transport"] = t
        case .httpupgrade:
            var t: [String: Any] = ["type": "httpupgrade", "path": node.path ?? "/"]
            if let h = node.host, !h.isEmpty { t["host"] = h }
            o["transport"] = t
        case .tcp, .xhttp, .kcp, .quic:
            break
        }
        return o
    }

    static func normalizeFingerprint(_ fp: String?) -> String? {
        guard let fp = fp?.lowercased(), !fp.isEmpty else { return nil }
        let known = ["chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized"]
        return known.contains(fp) ? fp : nil
    }

    static func warpEndpoint(account: WARPAccount, tag: String, detour: String?) -> [String: Any] {
        var e: [String: Any] = [
            "type": "wireguard",
            "tag": tag,
            "address": ["\(account.v4)/32", "\(account.v6)/128"],
            "private_key": account.privateKey,
            "mtu": 1280,
            "peers": [[
                "address": account.endpointHost,
                "port": account.endpointPort,
                "public_key": account.peerPublicKey,
                "allowed_ips": ["0.0.0.0/0", "::/0"],
                "reserved": account.reserved,
            ] as [String: Any]],
        ]
        if let d = detour { e["detour"] = d }
        return e
    }

    // MARK: Main (connection) config

    static func mainConfig(node: ProxyNode, backups: [ProxyNode] = [], settings: AppSettings, warp: WARPAccount?, apiSecret: String) -> [String: Any] {
        let opts = Options(stealth: settings.stealthMode, fragment: settings.stealthMode && settings.tlsFragment,
                           fragmentReality: settings.fragmentReality, fingerprint: settings.utlsFingerprint)
        let shield = settings.shieldMode && warp != nil && !node.isWARP
        let exitTag = (shield || node.isWARP) ? "warp" : "proxy"

        var outbounds: [[String: Any]] = []
        var endpoints: [[String: Any]] = []
        if node.isWARP, let w = warp {
            endpoints.append(warpEndpoint(account: w, tag: "warp", detour: nil))
        } else {
            if settings.extraStealthOn && !backups.isEmpty {
                // Failover pool: if the active server is blocked mid-session the core moves to the next
                // verified one by itself, so traffic never falls back to the bare connection.
                let members = [node] + backups
                for m in members { outbounds.append(outbound(for: m, tag: m.tag, opts: opts)) }
                outbounds.append([
                    "type": "urltest", "tag": "proxy", "outbounds": members.map { $0.tag },
                    "url": settings.testURL, "interval": "5m", "tolerance": 150, "interrupt_exist_connections": false,
                ])
            } else {
                outbounds.append(outbound(for: node, tag: "proxy", opts: opts))
            }
            if shield, let w = warp {
                endpoints.append(warpEndpoint(account: w, tag: "warp", detour: "proxy"))
            }
        }
        outbounds.append(["type": "direct", "tag": "direct"])

        var dnsRules: [[String: Any]] = []
        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"],
        ]
        if settings.extraStealthOn {
            // QUIC relayed through a TCP proxy is a distinctive pattern and most free servers drop UDP anyway;
            // rejecting it makes browsers fall back to ordinary HTTPS over TCP at once.
            routeRules.insert(["network": "udp", "port": 443, "action": "reject"], at: 2)
        }
        if settings.stealthMode && settings.domesticDirect {
            dnsRules.append(["domain_suffix": [".ir"], "server": "dns-local"])
            routeRules.append(["domain_suffix": [".ir"], "outbound": "direct"])
        }

        var config: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": [
                "servers": [
                    ["type": "https", "tag": "dns-remote", "server": "1.1.1.1", "detour": exitTag],
                    ["type": "local", "tag": "dns-local"],
                ],
                "rules": dnsRules,
                "final": "dns-remote",
                "strategy": "prefer_ipv4",
            ] as [String: Any],
            "inbounds": [[
                "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": settings.localPort,
            ] as [String: Any]],
            "outbounds": outbounds,
            "route": [
                "rules": routeRules,
                "final": exitTag,
                "auto_detect_interface": false,
                "default_domain_resolver": "dns-local",
            ] as [String: Any],
            "experimental": [
                "clash_api": ["external_controller": "127.0.0.1:\(settings.apiPort)", "secret": apiSecret],
            ],
        ]
        if !endpoints.isEmpty { config["endpoints"] = endpoints }
        return config
    }

    // MARK: Tester config (many outbounds, no inbound)

    static func testerConfig(nodes: [ProxyNode], settings: AppSettings, warp: WARPAccount?, apiSecret: String) -> [String: Any] {
        let opts = Options(stealth: settings.stealthMode, fragment: settings.stealthMode && settings.tlsFragment,
                           fragmentReality: settings.fragmentReality, fingerprint: settings.utlsFingerprint)
        var outbounds: [[String: Any]] = []
        var endpoints: [[String: Any]] = []
        for n in nodes {
            if n.isWARP {
                if let w = warp { endpoints.append(warpEndpoint(account: w, tag: n.tag, detour: nil)) }
            } else {
                outbounds.append(outbound(for: n, tag: n.tag, opts: opts))
            }
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        var config: [String: Any] = [
            "log": ["level": "error"],
            "dns": [
                "servers": [["type": "local", "tag": "dns-local"]],
                "final": "dns-local",
                "strategy": "prefer_ipv4",
            ] as [String: Any],
            "outbounds": outbounds,
            "route": ["final": "direct", "auto_detect_interface": false, "default_domain_resolver": "dns-local"] as [String: Any],
            "experimental": [
                "clash_api": ["external_controller": "127.0.0.1:\(settings.testerApiPort)", "secret": apiSecret],
            ],
        ]
        if !endpoints.isEmpty { config["endpoints"] = endpoints }
        return config
    }

    static func write(_ config: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
