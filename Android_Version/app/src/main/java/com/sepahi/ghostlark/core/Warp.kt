package com.sepahi.ghostlark.core

import com.sepahi.ghostlark.model.WarpAccount
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.math.BigInteger
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** X25519 (RFC 7748) with BigInteger: only used once per device to make a WireGuard key pair. */
object X25519 {
    private val P = BigInteger.TWO.pow(255).subtract(BigInteger.valueOf(19))
    private val A24 = BigInteger.valueOf(121665)

    private fun decodeLittleEndian(b: ByteArray): BigInteger {
        val r = ByteArray(b.size + 1)
        for (i in b.indices) r[b.size - i] = b[i]
        return BigInteger(r)
    }

    private fun encodeLittleEndian(x: BigInteger): ByteArray {
        val out = ByteArray(32)
        var v = x
        for (i in 0 until 32) { out[i] = (v and BigInteger.valueOf(255)).toInt().toByte(); v = v.shiftRight(8) }
        return out
    }

    fun clamp(k: ByteArray): ByteArray = k.copyOf().also {
        it[0] = (it[0].toInt() and 248).toByte()
        it[31] = ((it[31].toInt() and 127) or 64).toByte()
    }

    fun scalarMult(scalar: ByteArray, point: ByteArray): ByteArray {
        val k = decodeLittleEndian(clamp(scalar))
        val u = decodeLittleEndian(point.copyOf().also { it[31] = (it[31].toInt() and 127).toByte() })
        var x2 = BigInteger.ONE; var z2 = BigInteger.ZERO; var x3 = u; var z3 = BigInteger.ONE
        var swap = 0
        for (t in 254 downTo 0) {
            val kt = k.shiftRight(t).and(BigInteger.ONE).toInt()
            swap = swap xor kt
            if (swap == 1) { val tx = x2; x2 = x3; x3 = tx; val tz = z2; z2 = z3; z3 = tz }
            swap = kt
            val a = x2.add(z2).mod(P); val aa = a.multiply(a).mod(P)
            val b = x2.subtract(z2).mod(P); val bb = b.multiply(b).mod(P)
            val e = aa.subtract(bb).mod(P)
            val c = x3.add(z3).mod(P); val d = x3.subtract(z3).mod(P)
            val da = d.multiply(a).mod(P); val cb = c.multiply(b).mod(P)
            x3 = da.add(cb).let { it.multiply(it) }.mod(P)
            z3 = u.multiply(da.subtract(cb).let { it.multiply(it) }).mod(P)
            x2 = aa.multiply(bb).mod(P)
            z2 = e.multiply(aa.add(A24.multiply(e))).mod(P)
        }
        if (swap == 1) { val tx = x2; x2 = x3; x3 = tx; val tz = z2; z2 = z3; z3 = tz }
        return encodeLittleEndian(x2.multiply(z2.modPow(P.subtract(BigInteger.TWO), P)).mod(P))
    }

    fun publicKey(privateKey: ByteArray): ByteArray = scalarMult(privateKey, ByteArray(32).also { it[0] = 9 })

    fun generatePrivateKey(): ByteArray = clamp(ByteArray(32).also { SecureRandom().nextBytes(it) })
}

object Warp {
    private const val API = "https://api.cloudflareclient.com/v0a2158"

    suspend fun register(): WarpAccount = withContext(Dispatchers.IO) {
        val priv = X25519.generatePrivateKey()
        val pub = X25519.publicKey(priv)
        val privB64 = Base64.getEncoder().encodeToString(priv)
        val pubB64 = Base64.getEncoder().encodeToString(pub)
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val body = JSONObject().put("key", pubB64).put("install_id", "").put("fcm_token", "").put("tos", fmt.format(Date()))
            .put("model", "PC").put("type", "Android").put("locale", "en_US").toString()
        val c = URL("$API/reg").openConnection(Proxy.NO_PROXY) as HttpURLConnection
        c.requestMethod = "POST"
        c.setRequestProperty("Content-Type", "application/json")
        c.setRequestProperty("User-Agent", "okhttp/3.12.1")
        c.setRequestProperty("CF-Client-Version", "a-6.10-2158")
        c.connectTimeout = 20000; c.readTimeout = 30000
        c.doOutput = true
        c.outputStream.use { it.write(body.toByteArray()) }
        val code = c.responseCode
        if (code !in 200..299) throw IOException("Cloudflare registration failed (HTTP $code)")
        val o = JSONObject(c.inputStream.bufferedReader().readText())
        val cfg = o.getJSONObject("config")
        val addrs = cfg.getJSONObject("interface").getJSONObject("addresses")
        val peer = cfg.getJSONArray("peers").getJSONObject(0)
        val host = peer.getJSONObject("endpoint").getString("host")
        val hp = host.split(':')
        val clientId = Base64.getDecoder().decode(cfg.getString("client_id"))
        WarpAccount(
            id = o.getString("id"), token = o.getString("token"), privateKey = privB64, publicKey = pubB64,
            v4 = addrs.getString("v4"), v6 = addrs.getString("v6"), peerPublicKey = peer.getString("public_key"),
            endpointHost = if (hp.size == 2) hp[0] else "engage.cloudflareclient.com",
            endpointPort = if (hp.size == 2) hp[1].toIntOrNull() ?: 2408 else 2408,
            reserved = clientId.map { it.toInt() and 0xff }, created = System.currentTimeMillis(),
        )
    }
}
