package com.sepahi.ghostlark.model

import org.json.JSONObject
import java.net.URLDecoder
import java.util.Base64

/** Parses subscription payloads and share links (vless, vmess, trojan, ss, hysteria2/hy2, tuic). */
object ShareLinkParser {

    fun parseSubscription(raw: String, source: String): List<ProxyNode> {
        var lines = raw.replace("﻿", "").lines().map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && !it.startsWith("//") }
        if (lines.none { it.contains("://") }) {
            val decoded = decodeBase64Lenient(lines.joinToString("")) ?: return emptyList()
            lines = decoded.lines().map { it.trim() }.filter { it.isNotEmpty() }
        }
        return lines.mapNotNull { runCatching { parseLink(it, source) }.getOrNull() }
    }

    fun parseLink(line: String, source: String): ProxyNode? {
        val idx = line.indexOf("://")
        if (idx <= 0) return null
        val scheme = line.substring(0, idx).lowercase()
        val rest = line.substring(idx + 3)
        val hash = rest.indexOf('#')
        val body = if (hash >= 0) rest.substring(0, hash) else rest
        val name = cleanName(percentDecode(if (hash >= 0) rest.substring(hash + 1) else ""))
        return when (scheme) {
            "vmess" -> parseVmess(body, name, source, line)
            "vless" -> parseVless(body, name, source, line)
            "trojan" -> parseTrojan(body, name, source, line)
            "ss" -> parseSs(body, name, source, line)
            "hysteria2", "hy2" -> parseHy2(body, name, source, line)
            "tuic" -> parseTuic(body, name, source, line)
            else -> null
        }
    }

    private class Parts(val userinfo: String, val host: String, val port: Int, val query: Map<String, String>)

    private fun splitUrl(body: String): Parts? {
        var left = body
        var qs = ""
        val q = body.indexOf('?')
        if (q >= 0) { left = body.substring(0, q); qs = body.substring(q + 1) }
        left = left.trimEnd('/')
        val at = left.lastIndexOf('@')
        if (at < 0) return null
        val (host, port) = splitHostPort(left.substring(at + 1)) ?: return null
        return Parts(left.substring(0, at), host, port, parseQuery(qs))
    }

    private fun splitHostPort(s: String): Pair<String, Int>? {
        val host: String
        val portStr: String
        if (s.startsWith("[")) {
            val close = s.indexOf(']'); if (close < 0) return null
            host = s.substring(1, close)
            val after = s.substring(close + 1); if (!after.startsWith(":")) return null
            portStr = after.substring(1)
        } else {
            val colon = s.lastIndexOf(':'); if (colon < 0) return null
            host = s.substring(0, colon); portStr = s.substring(colon + 1)
        }
        val port = portStr.trim().toIntOrNull() ?: return null
        if (host.isBlank() || port !in 1..65535) return null
        return host.trim() to port
    }

    private fun parseQuery(q: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (pair in q.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val k = percentDecode(if (eq >= 0) pair.substring(0, eq) else pair).lowercase()
            val v = if (eq >= 0) percentDecode(pair.substring(eq + 1)) else ""
            if (k !in out) out[k] = v
        }
        return out
    }

    fun percentDecode(s: String): String = try { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (e: Exception) { s }

    private fun cleanName(s: String) = s.replace("\n", " ").split(" ").filter { it.isNotEmpty() }.joinToString(" ").trim()

    fun decodeBase64Lenient(s: String): String? {
        var t = s.filter { !it.isWhitespace() }.replace('-', '+').replace('_', '/').trimEnd('=')
        t += "=".repeat((4 - t.length % 4) % 4)
        return try { String(Base64.getDecoder().decode(t), Charsets.UTF_8) } catch (e: Exception) { null }
    }

    private fun flag(v: String?) = v?.lowercase().let { it == "1" || it == "true" || it == "yes" }
    private fun nz(v: String?) = v?.takeIf { it.isNotEmpty() }

    private fun transportKind(raw: String?): Transport = when ((raw ?: "tcp").lowercase()) {
        "", "tcp", "raw" -> Transport.TCP
        "ws", "websocket" -> Transport.WS
        "grpc", "gun" -> Transport.GRPC
        "h2", "http" -> Transport.HTTP
        "httpupgrade" -> Transport.HTTPUPGRADE
        "xhttp", "splithttp" -> Transport.XHTTP
        "kcp", "mkcp" -> Transport.KCP
        "quic" -> Transport.QUIC
        else -> Transport.TCP
    }

    private fun alpnList(raw: String?) = (raw ?: "").split(',').map { it.trim() }.filter { it.isNotEmpty() }

    private fun tlsMode(raw: String?) = when ((raw ?: "").lowercase()) { "tls", "xtls" -> TlsMode.TLS; "reality" -> TlsMode.REALITY; else -> TlsMode.NONE }

    private fun parseVless(body: String, name: String, source: String, raw: String): ProxyNode? {
        val p = splitUrl(body) ?: return null
        val uuid = percentDecode(p.userinfo); if (uuid.length < 8) return null
        val q = p.query
        if ((q["headertype"] ?: "none").lowercase() == "http") return null
        val transport = transportKind(q["type"])
        return ProxyNode(
            id = "", name = name.ifEmpty { "${p.host}:${p.port}" }, proto = Proto.VLESS, server = p.host, port = p.port,
            uuid = uuid, flow = nz(q["flow"]), security = tlsMode(q["security"]), sni = nz(q["sni"]), alpn = alpnList(q["alpn"]),
            fingerprint = nz(q["fp"]), insecure = flag(q["allowinsecure"]) || flag(q["insecure"]),
            realityPublicKey = nz(q["pbk"]), realityShortId = q["sid"], transport = transport, path = q["path"], host = nz(q["host"]),
            serviceName = q["servicename"] ?: if (transport == Transport.GRPC) q["path"] else null,
            sourceName = source, rawLink = raw,
        ).assessed()
    }

    private fun parseTrojan(body: String, name: String, source: String, raw: String): ProxyNode? {
        val p = splitUrl(body) ?: return null
        val password = percentDecode(p.userinfo); if (password.isEmpty()) return null
        val q = p.query
        val security = if (q["security"] == null) TlsMode.TLS else tlsMode(q["security"])
        val transport = transportKind(q["type"])
        return ProxyNode(
            id = "", name = name.ifEmpty { "${p.host}:${p.port}" }, proto = Proto.TROJAN, server = p.host, port = p.port,
            password = password, security = security, sni = nz(q["sni"]), alpn = alpnList(q["alpn"]), fingerprint = nz(q["fp"]),
            insecure = flag(q["allowinsecure"]) || flag(q["insecure"]), realityPublicKey = nz(q["pbk"]), realityShortId = q["sid"],
            transport = transport, path = q["path"], host = nz(q["host"]),
            serviceName = q["servicename"] ?: if (transport == Transport.GRPC) q["path"] else null,
            sourceName = source, rawLink = raw,
        ).assessed()
    }

    private fun parseHy2(body: String, name: String, source: String, raw: String): ProxyNode? {
        val p = splitUrl(body) ?: return null
        val q = p.query
        return ProxyNode(
            id = "", name = name.ifEmpty { "${p.host}:${p.port}" }, proto = Proto.HYSTERIA2, server = p.host, port = p.port,
            password = percentDecode(p.userinfo), security = TlsMode.TLS, sni = nz(q["sni"]), alpn = alpnList(q["alpn"]),
            insecure = flag(q["insecure"]) || flag(q["allowinsecure"]),
            obfsType = q["obfs"]?.takeIf { it.isNotEmpty() && it != "none" }, obfsPassword = q["obfs-password"],
            sourceName = source, rawLink = raw,
        ).assessed()
    }

    private fun parseTuic(body: String, name: String, source: String, raw: String): ProxyNode? {
        val p = splitUrl(body) ?: return null
        val creds = percentDecode(p.userinfo).split(':', limit = 2); if (creds.size != 2) return null
        val q = p.query
        return ProxyNode(
            id = "", name = name.ifEmpty { "${p.host}:${p.port}" }, proto = Proto.TUIC, server = p.host, port = p.port,
            uuid = creds[0], password = creds[1], security = TlsMode.TLS, sni = nz(q["sni"]),
            alpn = alpnList(q["alpn"]).ifEmpty { listOf("h3") },
            insecure = flag(q["allow_insecure"]) || flag(q["insecure"]) || flag(q["allowinsecure"]),
            congestionControl = q["congestion_control"] ?: "bbr", udpRelayMode = q["udp_relay_mode"],
            sourceName = source, rawLink = raw,
        ).assessed()
    }

    private fun parseSs(body: String, name: String, source: String, raw: String): ProxyNode? {
        var main = body
        var qs = ""
        val q = body.indexOf('?')
        if (q >= 0) { main = body.substring(0, q); qs = body.substring(q + 1) }
        main = main.trimEnd('/')
        val query = parseQuery(qs)
        val method: String; val password: String; val host: String; val port: Int
        val at = main.lastIndexOf('@')
        if (at >= 0) {
            var userinfo = percentDecode(main.substring(0, at))
            val hp = splitHostPort(main.substring(at + 1)) ?: return null
            host = hp.first; port = hp.second
            if (!userinfo.contains(':')) userinfo = decodeBase64Lenient(userinfo) ?: userinfo
            val mp = userinfo.split(':', limit = 2); if (mp.size != 2) return null
            method = mp[0]; password = mp[1]
        } else {
            val decoded = decodeBase64Lenient(main) ?: return null
            val at2 = decoded.lastIndexOf('@'); if (at2 < 0) return null
            val hp = splitHostPort(decoded.substring(at2 + 1)) ?: return null
            host = hp.first; port = hp.second
            val mp = decoded.substring(0, at2).split(':', limit = 2); if (mp.size != 2) return null
            method = mp[0]; password = mp[1]
        }
        if (method.isEmpty()) return null
        var plugin: String? = null
        var pluginOpts: String? = null
        query["plugin"]?.takeIf { it.isNotEmpty() }?.let { p ->
            val parts = p.split(';', limit = 2)
            plugin = if (parts[0] == "simple-obfs") "obfs-local" else parts[0]
            pluginOpts = parts.getOrNull(1)
        }
        return ProxyNode(
            id = "", name = name.ifEmpty { "$host:$port" }, proto = Proto.SHADOWSOCKS, server = host, port = port,
            password = password, method = method.lowercase(), plugin = plugin, pluginOpts = pluginOpts,
            sourceName = source, rawLink = raw,
        ).assessed()
    }

    private fun parseVmess(body: String, fallbackName: String, source: String, raw: String): ProxyNode? {
        val json = decodeBase64Lenient(body) ?: return null
        val obj = runCatching { JSONObject(json) }.getOrNull() ?: return null
        fun str(k: String): String? = if (obj.has(k) && !obj.isNull(k)) obj.get(k).toString().takeIf { it.isNotEmpty() } else null
        val server = str("add") ?: return null
        val port = str("port")?.toIntOrNull() ?: return null
        if (port !in 1..65535) return null
        val uuid = str("id") ?: return null
        val headerType = (str("type") ?: "none").lowercase()
        val net = (str("net") ?: "tcp").lowercase()
        if (net == "tcp" && headerType == "http") return null
        val transport = transportKind(net)
        var security = tlsMode(str("tls"))
        if (str("tls")?.lowercase() == "true") security = TlsMode.TLS
        val name = cleanName(str("ps") ?: fallbackName)
        var scy = (str("scy") ?: "auto").lowercase()
        if (scy !in setOf("auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305", "aes-128-ctr")) scy = "auto"
        return ProxyNode(
            id = "", name = name.ifEmpty { "$server:$port" }, proto = Proto.VMESS, server = server, port = port, uuid = uuid,
            security = security, sni = str("sni"), alpn = alpnList(str("alpn")), fingerprint = str("fp"),
            insecure = flag(str("insecure")) || flag(str("allowinsecure")) || flag(str("skip-cert-verify")),
            realityPublicKey = str("pbk"), realityShortId = str("sid"), transport = transport, path = str("path"), host = str("host"),
            serviceName = if (transport == Transport.GRPC) (str("servicename") ?: str("path")) else null,
            alterId = str("aid")?.toIntOrNull() ?: 0, vmessSecurity = scy, sourceName = source, rawLink = raw,
        ).assessed()
    }
}
