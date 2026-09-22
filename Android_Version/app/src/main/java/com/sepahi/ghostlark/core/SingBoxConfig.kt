package com.sepahi.ghostlark.core

import com.sepahi.ghostlark.model.AppSettings
import com.sepahi.ghostlark.model.Proto
import com.sepahi.ghostlark.model.ProxyNode
import com.sepahi.ghostlark.model.TlsMode
import com.sepahi.ghostlark.model.Transport
import com.sepahi.ghostlark.model.WarpAccount
import org.json.JSONArray
import org.json.JSONObject

/** Builds sing-box 1.14 JSON configurations. Mirrors the macOS builder, with a TUN inbound for Android. */
object SingBoxConfig {
    const val WARP_PEER_PUBLIC_KEY = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    class Options(val fragment: Boolean, val fragmentReality: Boolean, val fingerprint: String)

    private fun opts(s: AppSettings) = Options(s.stealthMode && s.tlsFragment, s.fragmentReality, s.utlsFingerprint)

    private fun jo(vararg pairs: Pair<String, Any?>): JSONObject = JSONObject().also { o -> pairs.forEach { (k, v) -> if (v != null) o.put(k, v) } }
    private fun ja(items: List<Any>): JSONArray = JSONArray().also { a -> items.forEach { a.put(it) } }

    private val knownFingerprints = setOf("chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized")

    fun outbound(n: ProxyNode, tag: String, o: Options): JSONObject {
        val out = jo("tag" to tag, "server" to n.server, "server_port" to n.port)
        when (n.proto) {
            Proto.VLESS -> { out.put("type", "vless"); out.put("uuid", n.uuid ?: ""); n.flow?.takeIf { it.isNotEmpty() }?.let { out.put("flow", it) }; out.put("packet_encoding", "xudp") }
            Proto.VMESS -> { out.put("type", "vmess"); out.put("uuid", n.uuid ?: ""); out.put("security", n.vmessSecurity ?: "auto"); out.put("alter_id", n.alterId); out.put("packet_encoding", "xudp") }
            Proto.TROJAN -> { out.put("type", "trojan"); out.put("password", n.password ?: "") }
            Proto.SHADOWSOCKS -> {
                out.put("type", "shadowsocks"); out.put("method", n.method ?: "aes-256-gcm"); out.put("password", n.password ?: "")
                n.plugin?.let { out.put("plugin", it); out.put("plugin_opts", n.pluginOpts ?: "") }
            }
            Proto.HYSTERIA2 -> {
                out.put("type", "hysteria2"); out.put("password", n.password ?: "")
                n.obfsType?.let { out.put("obfs", jo("type" to it, "password" to (n.obfsPassword ?: ""))) }
            }
            Proto.TUIC -> {
                out.put("type", "tuic"); out.put("uuid", n.uuid ?: ""); out.put("password", n.password ?: "")
                out.put("congestion_control", n.congestionControl ?: "bbr"); out.put("udp_relay_mode", n.udpRelayMode ?: "native")
            }
            Proto.WIREGUARD -> { out.put("type", "direct"); return out }
        }
        val isQuic = n.proto == Proto.HYSTERIA2 || n.proto == Proto.TUIC
        if (n.security != TlsMode.NONE || isQuic) {
            val tls = jo("enabled" to true)
            n.effectiveSni?.let { tls.put("server_name", it) }
            if (n.insecure) tls.put("insecure", true)
            if (n.alpn.isNotEmpty()) tls.put("alpn", ja(n.alpn))
            if (!isQuic) {
                val fp = n.fingerprint?.lowercase()?.takeIf { it in knownFingerprints } ?: o.fingerprint
                tls.put("utls", jo("enabled" to true, "fingerprint" to fp))
            }
            if (n.security == TlsMode.REALITY && n.realityPublicKey != null) {
                val r = jo("enabled" to true, "public_key" to n.realityPublicKey)
                n.realityShortId?.takeIf { it.isNotEmpty() }?.let { r.put("short_id", it) }
                tls.put("reality", r)
            }
            if (o.fragment && !isQuic && (n.security != TlsMode.REALITY || o.fragmentReality)) {
                tls.put("fragment", true); tls.put("record_fragment", true)
            }
            out.put("tls", tls)
        }
        when (n.transport) {
            Transport.WS -> {
                val t = jo("type" to "ws")
                var path = n.path ?: "/"
                val ed = path.indexOf("?ed=")
                if (ed >= 0) {
                    val num = path.substring(ed + 4).takeWhile { it.isDigit() }.toIntOrNull() ?: 2048
                    path = path.substring(0, ed)
                    t.put("max_early_data", num); t.put("early_data_header_name", "Sec-WebSocket-Protocol")
                }
                t.put("path", path.ifEmpty { "/" })
                n.host?.takeIf { it.isNotEmpty() }?.let { t.put("headers", jo("Host" to it)) }
                out.put("transport", t)
            }
            Transport.GRPC -> out.put("transport", jo("type" to "grpc", "service_name" to (n.serviceName ?: n.path ?: "")))
            Transport.HTTP -> {
                val t = jo("type" to "http", "path" to (n.path ?: "/"))
                n.host?.takeIf { it.isNotEmpty() }?.let { t.put("host", ja(it.split(','))) }
                out.put("transport", t)
            }
            Transport.HTTPUPGRADE -> {
                val t = jo("type" to "httpupgrade", "path" to (n.path ?: "/"))
                n.host?.takeIf { it.isNotEmpty() }?.let { t.put("host", it) }
                out.put("transport", t)
            }
            else -> {}
        }
        return out
    }

    fun warpEndpoint(a: WarpAccount, tag: String, detour: String?): JSONObject {
        val e = jo(
            "type" to "wireguard", "tag" to tag, "address" to ja(listOf("${a.v4}/32", "${a.v6}/128")),
            "private_key" to a.privateKey, "mtu" to 1280,
            "peers" to ja(listOf(jo(
                "address" to a.endpointHost, "port" to a.endpointPort, "public_key" to a.peerPublicKey,
                "allowed_ips" to ja(listOf("0.0.0.0/0", "::/0")), "reserved" to ja(a.reserved),
            ))),
        )
        detour?.let { e.put("detour", it) }
        return e
    }

    fun mainConfig(node: ProxyNode, s: AppSettings, warp: WarpAccount?, apiSecret: String, backups: List<ProxyNode> = emptyList()): String {
        val o = opts(s)
        val shield = s.shieldMode && warp != null && !node.isWarp
        val exit = if (shield || node.isWarp) "warp" else "proxy"
        val outbounds = mutableListOf<Any>()
        val endpoints = mutableListOf<Any>()
        if (node.isWarp && warp != null) endpoints += warpEndpoint(warp, "warp", null)
        else {
            if (s.extraStealthOn && backups.isNotEmpty()) {
                // Failover pool: a blocked server is replaced by the core itself, never by the bare connection.
                val members = listOf(node) + backups
                members.forEach { outbounds += outbound(it, it.tag, o) }
                outbounds += jo("type" to "urltest", "tag" to "proxy", "outbounds" to ja(members.map { it.tag }),
                    "url" to s.testUrl, "interval" to "5m", "tolerance" to 150, "interrupt_exist_connections" to false)
            } else outbounds += outbound(node, "proxy", o)
            if (shield && warp != null) endpoints += warpEndpoint(warp, "warp", "proxy")
        }
        outbounds += jo("type" to "direct", "tag" to "direct")
        val dnsRules = mutableListOf<Any>()
        val routeRules = mutableListOf<Any>(
            jo("action" to "sniff"),
            jo("protocol" to "dns", "action" to "hijack-dns"),
            jo("ip_is_private" to true, "outbound" to "direct"),
        )
        if (s.extraStealthOn) routeRules.add(2, jo("network" to "udp", "port" to 443, "action" to "reject"))
        if (s.stealthMode && s.domesticDirect) {
            dnsRules += jo("domain_suffix" to ja(listOf(".ir")), "server" to "dns-local")
            routeRules += jo("domain_suffix" to ja(listOf(".ir")), "outbound" to "direct")
        }
        val cfg = jo(
            "log" to jo("level" to "info", "timestamp" to true),
            "dns" to jo(
                "servers" to ja(listOf(
                    jo("type" to "https", "tag" to "dns-remote", "server" to "1.1.1.1", "detour" to exit),
                    jo("type" to "local", "tag" to "dns-local"),
                )),
                "rules" to ja(dnsRules), "final" to "dns-remote", "strategy" to "prefer_ipv4",
            ),
            "inbounds" to ja(listOf(jo(
                "type" to "tun", "tag" to "tun-in", "address" to ja(listOf("172.19.0.1/30", "fdfe:dcba:9876::1/126")),
                "mtu" to 1500, "auto_route" to true, "strict_route" to true, "stack" to "mixed",
            ))),
            "outbounds" to ja(outbounds),
            "route" to jo("rules" to ja(routeRules), "final" to exit, "auto_detect_interface" to true, "default_domain_resolver" to "dns-local"),
            "experimental" to jo("clash_api" to jo("external_controller" to "127.0.0.1:${s.apiPort}", "secret" to apiSecret)),
        )
        if (endpoints.isNotEmpty()) cfg.put("endpoints", ja(endpoints))
        return cfg.toString(2)
    }

    /** Many outbounds, no inbound: used for batch latency tests without touching the VPN. */
    fun testerConfig(nodes: List<ProxyNode>, s: AppSettings, warp: WarpAccount?, apiSecret: String): String {
        val o = opts(s)
        val outbounds = mutableListOf<Any>()
        val endpoints = mutableListOf<Any>()
        for (n in nodes) {
            if (n.isWarp) { if (warp != null) endpoints += warpEndpoint(warp, n.tag, null) } else outbounds += outbound(n, n.tag, o)
        }
        outbounds += jo("type" to "direct", "tag" to "direct")
        val cfg = jo(
            "log" to jo("level" to "error"),
            "dns" to jo("servers" to ja(listOf(jo("type" to "local", "tag" to "dns-local"))), "final" to "dns-local", "strategy" to "prefer_ipv4"),
            "outbounds" to ja(outbounds),
            "route" to jo("final" to "direct", "auto_detect_interface" to true, "default_domain_resolver" to "dns-local"),
            "experimental" to jo("clash_api" to jo("external_controller" to "127.0.0.1:${s.testerApiPort}", "secret" to apiSecret)),
        )
        if (endpoints.isNotEmpty()) cfg.put("endpoints", ja(endpoints))
        return cfg.toString(2)
    }
}
