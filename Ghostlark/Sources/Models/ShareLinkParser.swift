import Foundation

/// Parses subscription payloads and individual share links (vless://, vmess://, trojan://,
/// ss://, hysteria2://, hy2://, tuic://) into ProxyNode values.
enum ShareLinkParser {

    static func parseSubscription(_ raw: String, source: String) -> [ProxyNode] {
        var lines = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }

        if !lines.contains(where: { $0.contains("://") }) {
            // Whole payload is probably base64.
            if let decoded = decodeBase64Lenient(lines.joined()) {
                lines = decoded.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                return []
            }
        }

        var out: [ProxyNode] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if let node = parseLink(line, source: source) { out.append(node) }
        }
        return out
    }

    static func parseLink(_ line: String, source: String) -> ProxyNode? {
        guard let schemeRange = line.range(of: "://") else { return nil }
        let scheme = line[..<schemeRange.lowerBound].lowercased()
        let rest = String(line[schemeRange.upperBound...])
        var body = rest
        var fragment = ""
        if let hash = rest.firstIndex(of: "#") {
            body = String(rest[..<hash])
            fragment = String(rest[rest.index(after: hash)...])
        }
        let name = cleanName(percentDecode(fragment))

        switch scheme {
        case "vmess": return parseVMess(body: body, fallbackName: name, source: source, raw: line)
        case "vless": return parseVLESS(body: body, name: name, source: source, raw: line)
        case "trojan": return parseTrojan(body: body, name: name, source: source, raw: line)
        case "ss": return parseShadowsocks(body: body, name: name, source: source, raw: line)
        case "hysteria2", "hy2": return parseHysteria2(body: body, name: name, source: source, raw: line)
        case "tuic": return parseTUIC(body: body, name: name, source: source, raw: line)
        default: return nil
        }
    }

    // MARK: - Generic URL pieces

    struct URLParts {
        var userinfo: String
        var host: String
        var port: Int
        var query: [String: String]
    }

    static func splitURL(_ body: String) -> URLParts? {
        var left = body
        var queryString = ""
        if let q = body.firstIndex(of: "?") {
            left = String(body[..<q])
            queryString = String(body[body.index(after: q)...])
        }
        while left.hasSuffix("/") { left.removeLast() }
        guard let at = left.lastIndex(of: "@") else { return nil }
        let userinfo = String(left[..<at])
        let hostport = String(left[left.index(after: at)...])
        guard let (host, port) = splitHostPort(hostport) else { return nil }
        return URLParts(userinfo: userinfo, host: host, port: port, query: parseQuery(queryString))
    }

    static func splitHostPort(_ s: String) -> (String, Int)? {
        var host = ""
        var portStr = ""
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            portStr = String(after.dropFirst())
        } else {
            guard let colon = s.lastIndex(of: ":") else { return nil }
            host = String(s[..<colon])
            portStr = String(s[s.index(after: colon)...])
        }
        host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(portStr.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    static func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            let key = percentDecode(String(k)).lowercased()
            let value = kv.count > 1 ? percentDecode(String(kv[1])) : ""
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    static func cleanName(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeBase64Lenient(_ s: String) -> String? {
        var t = s.filter { !$0.isWhitespace }
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let pad = (4 - t.count % 4) % 4
        t += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func flag(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }

    static func transportKind(_ raw: String?) -> TransportKind {
        switch (raw ?? "tcp").lowercased() {
        case "", "tcp", "raw": return .tcp
        case "ws", "websocket": return .ws
        case "grpc", "gun": return .grpc
        case "h2", "http": return .http
        case "httpupgrade": return .httpupgrade
        case "xhttp", "splithttp": return .xhttp
        case "kcp", "mkcp": return .kcp
        case "quic": return .quic
        default: return .tcp
        }
    }

    static func alpnList(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func tlsMode(_ raw: String?) -> TLSMode {
        switch (raw ?? "").lowercased() {
        case "tls", "xtls": return .tls
        case "reality": return .reality
        default: return .none
        }
    }

    // MARK: - Protocol parsers

    static func parseVLESS(body: String, name: String, source: String, raw: String) -> ProxyNode? {
        guard let p = splitURL(body) else { return nil }
        let uuid = percentDecode(p.userinfo)
        guard uuid.count >= 8 else { return nil }
        let q = p.query
        // Xray's tcp+http header obfuscation has no sing-box equivalent.
        if (q["headertype"] ?? "none").lowercased() == "http" { return nil }
        let transport = transportKind(q["type"])
        let flow = q["flow"].flatMap { $0.isEmpty ? nil : $0 }
        var node = ProxyNode(
            name: name.isEmpty ? "\(p.host):\(p.port)" : name,
            proto: .vless, server: p.host, port: p.port, uuid: uuid, flow: flow,
            security: tlsMode(q["security"]), sni: q["sni"].flatMap { $0.isEmpty ? nil : $0 },
            alpn: alpnList(q["alpn"]), fingerprint: q["fp"].flatMap { $0.isEmpty ? nil : $0 },
            insecure: flag(q["allowinsecure"]) || flag(q["insecure"]),
            realityPublicKey: q["pbk"].flatMap { $0.isEmpty ? nil : $0 }, realityShortId: q["sid"],
            transport: transport, path: q["path"], host: q["host"].flatMap { $0.isEmpty ? nil : $0 },
            serviceName: q["servicename"] ?? (transport == .grpc ? q["path"] : nil),
            sourceName: source, rawLink: raw)
        node.lastSeen = Date()
        return node
    }

    static func parseTrojan(body: String, name: String, source: String, raw: String) -> ProxyNode? {
        guard let p = splitURL(body) else { return nil }
        let password = percentDecode(p.userinfo)
        guard !password.isEmpty else { return nil }
        let q = p.query
        let security: TLSMode = q["security"] == nil ? .tls : tlsMode(q["security"])
        let transport = transportKind(q["type"])
        return ProxyNode(
            name: name.isEmpty ? "\(p.host):\(p.port)" : name,
            proto: .trojan, server: p.host, port: p.port, password: password,
            security: security, sni: q["sni"].flatMap { $0.isEmpty ? nil : $0 }, alpn: alpnList(q["alpn"]),
            fingerprint: q["fp"].flatMap { $0.isEmpty ? nil : $0 },
            insecure: flag(q["allowinsecure"]) || flag(q["insecure"]),
            realityPublicKey: q["pbk"].flatMap { $0.isEmpty ? nil : $0 }, realityShortId: q["sid"],
            transport: transport, path: q["path"], host: q["host"].flatMap { $0.isEmpty ? nil : $0 },
            serviceName: q["servicename"] ?? (transport == .grpc ? q["path"] : nil),
            sourceName: source, rawLink: raw)
    }

    static func parseHysteria2(body: String, name: String, source: String, raw: String) -> ProxyNode? {
        guard let p = splitURL(body) else { return nil }
        let q = p.query
        return ProxyNode(
            name: name.isEmpty ? "\(p.host):\(p.port)" : name,
            proto: .hysteria2, server: p.host, port: p.port, password: percentDecode(p.userinfo),
            security: .tls, sni: q["sni"].flatMap { $0.isEmpty ? nil : $0 }, alpn: alpnList(q["alpn"]),
            insecure: flag(q["insecure"]) || flag(q["allowinsecure"]),
            obfsType: q["obfs"].flatMap { $0.isEmpty || $0 == "none" ? nil : $0 },
            obfsPassword: q["obfs-password"],
            sourceName: source, rawLink: raw)
    }

    static func parseTUIC(body: String, name: String, source: String, raw: String) -> ProxyNode? {
        guard let p = splitURL(body) else { return nil }
        let creds = percentDecode(p.userinfo).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard creds.count == 2 else { return nil }
        let q = p.query
        return ProxyNode(
            name: name.isEmpty ? "\(p.host):\(p.port)" : name,
            proto: .tuic, server: p.host, port: p.port, uuid: String(creds[0]), password: String(creds[1]),
            security: .tls, sni: q["sni"].flatMap { $0.isEmpty ? nil : $0 },
            alpn: alpnList(q["alpn"]).isEmpty ? ["h3"] : alpnList(q["alpn"]),
            insecure: flag(q["allow_insecure"]) || flag(q["insecure"]) || flag(q["allowinsecure"]),
            congestionControl: q["congestion_control"] ?? "bbr", udpRelayMode: q["udp_relay_mode"],
            sourceName: source, rawLink: raw)
    }

    static func parseShadowsocks(body: String, name: String, source: String, raw: String) -> ProxyNode? {
        var main = body
        var queryString = ""
        if let q = body.firstIndex(of: "?") {
            main = String(body[..<q])
            queryString = String(body[body.index(after: q)...])
        }
        while main.hasSuffix("/") { main.removeLast() }
        let query = parseQuery(queryString)

        var method = ""
        var password = ""
        var host = ""
        var port = 0

        if let at = main.lastIndex(of: "@") {
            var userinfo = String(main[..<at])
            let hostport = String(main[main.index(after: at)...])
            guard let hp = splitHostPort(hostport) else { return nil }
            host = hp.0; port = hp.1
            userinfo = percentDecode(userinfo)
            if !userinfo.contains(":"), let decoded = decodeBase64Lenient(userinfo) { userinfo = decoded }
            let mp = userinfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard mp.count == 2 else { return nil }
            method = String(mp[0]); password = String(mp[1])
        } else {
            guard let decoded = decodeBase64Lenient(main), let at = decoded.lastIndex(of: "@") else { return nil }
            let userinfo = String(decoded[..<at])
            guard let hp = splitHostPort(String(decoded[decoded.index(after: at)...])) else { return nil }
            host = hp.0; port = hp.1
            let mp = userinfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard mp.count == 2 else { return nil }
            method = String(mp[0]); password = String(mp[1])
        }
        guard !method.isEmpty else { return nil }

        var plugin: String? = nil
        var pluginOpts: String? = nil
        if let p = query["plugin"], !p.isEmpty {
            let parts = p.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            plugin = String(parts[0])
            if plugin == "simple-obfs" { plugin = "obfs-local" }
            pluginOpts = parts.count > 1 ? String(parts[1]) : nil
        }
        return ProxyNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            proto: .shadowsocks, server: host, port: port, password: password, method: method.lowercased(),
            plugin: plugin, pluginOpts: pluginOpts, sourceName: source, rawLink: raw)
    }

    static func parseVMess(body: String, fallbackName: String, source: String, raw: String) -> ProxyNode? {
        guard let json = decodeBase64Lenient(body), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            if let s = obj[k] as? String { return s.isEmpty ? nil : s }
            if let n = obj[k] as? NSNumber { return n.stringValue }
            return nil
        }
        guard let server = str("add"), let portStr = str("port"), let port = Int(portStr), (1...65535).contains(port),
              let uuid = str("id") else { return nil }
        let headerType = (str("type") ?? "none").lowercased()
        let netRaw = (str("net") ?? "tcp").lowercased()
        if netRaw == "tcp" && headerType == "http" { return nil }
        let transport = transportKind(netRaw)
        var security: TLSMode = tlsMode(str("tls"))
        if str("tls")?.lowercased() == "true" { security = .tls }
        let name = cleanName(str("ps") ?? fallbackName)
        var scy = (str("scy") ?? "auto").lowercased()
        if !["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305", "aes-128-ctr"].contains(scy) { scy = "auto" }
        let node = ProxyNode(
            name: name.isEmpty ? "\(server):\(port)" : name,
            proto: .vmess, server: server, port: port, uuid: uuid,
            security: security, sni: str("sni"), alpn: alpnList(str("alpn")), fingerprint: str("fp"),
            insecure: flag(str("insecure")) || flag(str("allowinsecure")) || flag(str("skip-cert-verify")),
            realityPublicKey: str("pbk"), realityShortId: str("sid"),
            transport: transport, path: str("path"), host: str("host"),
            serviceName: transport == .grpc ? (str("servicename") ?? str("path")) : nil,
            alterId: Int(str("aid") ?? "0") ?? 0, vmessSecurity: scy,
            sourceName: source, rawLink: raw)
        return node
    }
}
