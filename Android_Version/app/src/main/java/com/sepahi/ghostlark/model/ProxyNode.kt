package com.sepahi.ghostlark.model

import kotlinx.serialization.Serializable
import java.security.MessageDigest

@Serializable
enum class Proto(val label: String) {
    VLESS("VLESS"), VMESS("VMess"), TROJAN("Trojan"), SHADOWSOCKS("Shadowsocks"),
    HYSTERIA2("Hysteria2"), TUIC("TUIC"), WIREGUARD("WireGuard")
}

@Serializable
enum class TlsMode { NONE, TLS, REALITY }

@Serializable
enum class Transport(val supported: Boolean = true) {
    TCP, WS, GRPC, HTTP, HTTPUPGRADE, XHTTP(false), KCP(false), QUIC(false)
}

@Serializable
enum class Tier(val label: String) { UNSAFE("Unsafe"), WEAK("Weak"), GOOD("Good"), STRONG("Strong") }

/** One proxy server. Immutable; use copy() for updates. */
@Serializable
data class ProxyNode(
    val id: String,
    val name: String,
    val proto: Proto,
    val server: String,
    val port: Int,
    val uuid: String? = null,
    val password: String? = null,
    val method: String? = null,
    val flow: String? = null,
    val security: TlsMode = TlsMode.NONE,
    val sni: String? = null,
    val alpn: List<String> = emptyList(),
    val fingerprint: String? = null,
    val insecure: Boolean = false,
    val realityPublicKey: String? = null,
    val realityShortId: String? = null,
    val transport: Transport = Transport.TCP,
    val path: String? = null,
    val host: String? = null,
    val serviceName: String? = null,
    val obfsType: String? = null,
    val obfsPassword: String? = null,
    val congestionControl: String? = null,
    val udpRelayMode: String? = null,
    val alterId: Int = 0,
    val vmessSecurity: String? = null,
    val plugin: String? = null,
    val pluginOpts: String? = null,
    val sourceName: String,
    val rawLink: String,
    val firstSeen: Long = System.currentTimeMillis(),
    val lastSeen: Long = System.currentTimeMillis(),
    val tier: Tier = Tier.WEAK,
    val safetyScore: Int = 0,
    val stealthScore: Int = 0,
    val notes: List<String> = emptyList(),
    val supported: Boolean = true,
    val latencyMs: Int? = null,
    val lastError: String? = null,
    val lastTested: Long? = null,
    val okCount: Int = 0,
    val failCount: Int = 0,
    val shieldCapable: Boolean? = null,
) {
    val tag: String get() = "n$id"
    val isWarp: Boolean get() = proto == Proto.WIREGUARD
    val testedOk: Boolean get() = latencyMs != null

    val serverIsIp: Boolean
        get() = server.contains(":") || server.split(".").let { it.size == 4 && it.all { p -> p.toIntOrNull() != null } }

    val effectiveSni: String?
        get() = sni?.takeIf { it.isNotEmpty() } ?: host?.takeIf { it.isNotEmpty() } ?: if (serverIsIp) null else server

    val countryFlag: String?
        get() {
            val cps = name.codePoints().toArray()
            for (i in 0 until cps.size - 1) {
                if (cps[i] in 0x1F1E6..0x1F1FF && cps[i + 1] in 0x1F1E6..0x1F1FF) {
                    return String(intArrayOf(cps[i], cps[i + 1]), 0, 2)
                }
            }
            return null
        }

    val countryCode: String?
        get() = countryFlag?.codePoints()?.toArray()?.map { (it - 0x1F1E6 + 'A'.code).toChar() }?.joinToString("")

    val reliability: Double
        get() = if (okCount + failCount == 0) 0.5 else okCount.toDouble() / (okCount + failCount)

    /** A Reality decoy naming a site that serves from its own IP ranges is an SNI/IP mismatch a censor can check. */
    val decoyMismatchRisk: Boolean
        get() {
            if (security != TlsMode.REALITY) return false
            val s = (sni ?: host)?.lowercase() ?: return false
            return selfHostedDecoys.any { s == it || s.endsWith(".$it") }
        }

    val isWebTransport: Boolean get() = transport in setOf(Transport.WS, Transport.GRPC, Transport.HTTP, Transport.HTTPUPGRADE)

    val cdnFronted: Boolean
        get() {
            val h = host ?: sni
            return isWebTransport && security != TlsMode.NONE && serverIsIp && !h.isNullOrEmpty() && !h.equals(server, true)
        }

    /** Extra Stealth: Reality, or verified TLS carrying WebSocket/gRPC/HTTPUpgrade (or Vision) on an HTTPS port. */
    val extraStealthEligible: Boolean
        get() {
            if (!supported || isWarp) return false
            if (proto != Proto.VLESS && proto != Proto.TROJAN && proto != Proto.VMESS) return false
            if (security == TlsMode.REALITY) return realityPublicKey != null
            if (security != TlsMode.TLS || insecure || port !in tlsPorts) return false
            return isWebTransport || flow?.contains("vision") == true
        }

    val extraStealthScore: Int
        get() {
            var s = stealthScore
            if (decoyMismatchRisk) s -= 12
            if (cdnFronted) s += 4
            if (!serverIsIp) s -= 4
            if (flow?.contains("vision") == true) s += 3
            return s.coerceIn(0, 100)
        }

    fun rank(stealthWeighted: Boolean, shield: Boolean = false, extra: Boolean = false): Double {
        var r = safetyScore * 3.0 + (if (extra) extraStealthScore else stealthScore) * (if (stealthWeighted) 2.5 else 1.0)
        r += reliability * 120
        if (shield && shieldCapable != null) r += if (shieldCapable) 300 else -300
        val ms = latencyMs
        if (ms != null) r += 1000 - minOf(ms, 3000) / 6.0
        else if (lastError != null) r -= 800
        return r
    }

    val securityBadge: String
        get() = when (security) {
            TlsMode.REALITY -> "Reality"
            TlsMode.TLS -> if (insecure) "TLS (unverified)" else "TLS"
            TlsMode.NONE -> if (proto == Proto.HYSTERIA2 || proto == Proto.TUIC || proto == Proto.WIREGUARD) "Encrypted" else "Plain"
        }

    /** Returns a copy with the static safety/stealth assessment filled in and a stable id. */
    fun assessed(): ProxyNode {
        val a = SafetyScorer.assess(this)
        return copy(
            id = makeId(proto, server, port, uuid ?: password ?: "", transport, path ?: serviceName ?: "", sni ?: host ?: ""),
            tier = a.tier, safetyScore = a.score, stealthScore = a.stealth, notes = a.notes, supported = a.supported,
        )
    }

    companion object {
        const val WARP_ID = "warp0000000000000000"
        val tlsPorts = setOf(443, 2053, 2083, 2087, 2096, 8443)
        val selfHostedDecoys = listOf("apple.com", "icloud.com", "microsoft.com", "live.com", "bing.com", "google.com",
            "gstatic.com", "youtube.com", "amazon.com", "cloudflare.com", "facebook.com", "instagram.com",
            "whatsapp.com", "yahoo.com", "samsung.com", "speedtest.net", "twitter.com", "x.com")

        fun makeId(proto: Proto, server: String, port: Int, credential: String, transport: Transport, path: String, sni: String): String {
            val key = "${proto.name.lowercase()}|${server.lowercase()}|$port|$credential|${transport.name.lowercase()}|$path|${sni.lowercase()}"
            val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
            return digest.take(10).joinToString("") { "%02x".format(it) }
        }

        fun warpNode(): ProxyNode = ProxyNode(
            id = WARP_ID, name = "🌐 Cloudflare WARP (free, direct)", proto = Proto.WIREGUARD,
            server = "engage.cloudflareclient.com", port = 2408, sourceName = "Cloudflare WARP", rawLink = "warp://cloudflare",
        ).let { n -> val a = SafetyScorer.assess(n); n.copy(tier = a.tier, safetyScore = a.score, stealthScore = a.stealth, notes = a.notes) }
    }
}
