package com.sepahi.ghostlark.model

data class Assessment(val tier: Tier, val score: Int, val stealth: Int, val notes: List<String>, val supported: Boolean)

/** Offline assessment of a node's protocol stack: what an operator/middlebox can see, and how it looks to DPI. */
object SafetyScorer {
    private val aead = setOf("aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305")
    private val ss2022 = setOf("2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305")
    private val legacy = setOf("aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
        "rc4-md5", "chacha20-ietf", "chacha20", "xchacha20", "none", "plain")
    private val tlsPorts = setOf(443, 2053, 2083, 2087, 2096, 8443)

    fun assess(n: ProxyNode): Assessment {
        var score = 0
        var stealth = 0
        val notes = mutableListOf<String>()
        var supported = true
        if (!n.transport.supported) { supported = false; notes += "${n.transport.name} transport is not supported by the sing-box core" }
        val tlsVerified = n.security == TlsMode.TLS && !n.insecure
        val tlsUnverified = n.security == TlsMode.TLS && n.insecure
        val web = n.transport in setOf(Transport.WS, Transport.GRPC, Transport.HTTP, Transport.HTTPUPGRADE)

        when (n.proto) {
            Proto.WIREGUARD -> { score = 92; stealth = 35; notes += "WireGuard to Cloudflare: strong encryption, but easy to fingerprint and often throttled" }
            Proto.VLESS -> when (n.security) {
                TlsMode.REALITY -> {
                    score = 90; stealth = 95
                    notes += "Reality: TLS 1.3 handshake is indistinguishable from a visit to the decoy site"
                    if (n.flow?.contains("vision") == true) { score += 5; notes += "XTLS-Vision hides inner TLS-in-TLS patterns" }
                    if (n.realityPublicKey == null) { supported = false; notes += "Reality public key missing" }
                }
                TlsMode.TLS -> {
                    score = if (tlsVerified) 76 else 55; stealth = if (web) 78 else 58
                    if (tlsUnverified) notes += "Certificate is not verified: the operator or a middlebox could impersonate the server"
                    if (n.flow?.contains("vision") == true) stealth += 7
                }
                TlsMode.NONE -> {
                    score = 12; stealth = if (n.transport == Transport.WS || n.transport == Transport.HTTPUPGRADE) 40 else 10
                    notes += "VLESS without TLS carries your traffic unencrypted between you and the proxy"
                }
            }
            Proto.VMESS -> {
                when (n.security) {
                    TlsMode.REALITY -> { score = 86; stealth = 90 }
                    TlsMode.TLS -> { score = if (tlsVerified) 78 else 58; stealth = if (web) 76 else 55; if (tlsUnverified) notes += "Certificate is not verified" }
                    TlsMode.NONE -> { score = 45; stealth = if (web) 38 else 15; notes += "Only VMess's own AEAD layer protects this link; fingerprintable, no forward secrecy" }
                }
                if (n.alterId > 0) { score -= 15; notes += "Legacy non-AEAD VMess (alterId > 0)" }
                val sec = (n.vmessSecurity ?: "auto").lowercase()
                if (sec == "none" || sec == "zero") { score -= 25; notes += "VMess inner encryption disabled" }
            }
            Proto.TROJAN -> when (n.security) {
                TlsMode.REALITY -> { score = 88; stealth = 92 }
                TlsMode.TLS -> { score = if (tlsVerified) 76 else 55; stealth = if (web) 78 else 62; if (tlsUnverified) notes += "Certificate is not verified" }
                TlsMode.NONE -> { score = 10; stealth = 10; notes += "Trojan without TLS is plaintext" }
            }
            Proto.SHADOWSOCKS -> {
                val m = (n.method ?: "").lowercase()
                when {
                    m in ss2022 -> { score = 82; stealth = 48; notes += "Shadowsocks 2022: AEAD with replay protection" }
                    m in aead -> { score = 70; stealth = 40; notes += "Shadowsocks AEAD: encrypted, but the protocol is well known to DPI" }
                    m in legacy -> { score = 12; stealth = 15; notes += "Legacy stream cipher ($m): no integrity protection, considered broken" }
                    else -> { score = 20; stealth = 20; supported = false; notes += "Unknown cipher $m" }
                }
                val p = n.plugin
                if (!p.isNullOrEmpty()) {
                    if (p.contains("obfs") || p.contains("v2ray")) stealth += 15 else { supported = false; notes += "Unsupported plugin $p" }
                }
            }
            Proto.HYSTERIA2 -> {
                score = if (n.insecure) 62 else 82; stealth = 62
                notes += "QUIC-based: strong TLS 1.3 encryption, fast, but UDP is often throttled on restricted networks"
                if (n.insecure) notes += "Certificate is not verified"
                if (n.obfsType == "salamander") { stealth += 12; notes += "Salamander obfuscation hides the QUIC signature" }
            }
            Proto.TUIC -> { score = if (n.insecure) 62 else 80; stealth = 58; notes += "QUIC-based (TUIC); UDP is often throttled on restricted networks" }
        }
        if (n.security != TlsMode.NONE && n.port in tlsPorts) stealth += 5
        val h = n.host ?: n.sni
        if (web && n.security != TlsMode.NONE && !h.isNullOrEmpty() && !h.equals(n.server, true) && n.serverIsIp) {
            stealth += 5; notes += "Likely CDN-fronted: blocking it means blocking the CDN"
        }
        score = score.coerceIn(0, 100); stealth = stealth.coerceIn(0, 100)
        val tier = when { score >= 85 -> Tier.STRONG; score >= 65 -> Tier.GOOD; score >= 40 -> Tier.WEAK; else -> Tier.UNSAFE }
        return Assessment(tier, score, stealth, notes, supported)
    }
}
