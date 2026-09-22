package com.sepahi.ghostlark.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.net.URLEncoder

/** Minimal client for sing-box's Clash-compatible control API on loopback. */
class ClashApi(private val port: Int, private val secret: String) {

    private fun open(path: String, timeoutMs: Int): HttpURLConnection {
        val c = URL("http://127.0.0.1:$port$path").openConnection(Proxy.NO_PROXY) as HttpURLConnection
        c.setRequestProperty("Authorization", "Bearer $secret")
        c.connectTimeout = 2000
        c.readTimeout = timeoutMs
        return c
    }

    suspend fun waitReady(timeoutMs: Long): Boolean = withContext(Dispatchers.IO) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                val c = open("/version", 2000)
                if (c.responseCode == 200) { c.disconnect(); return@withContext true }
                c.disconnect()
            } catch (_: Exception) { }
            delay(150)
        }
        false
    }

    /** Connectivity test through one outbound; returns latency in ms or throws. */
    suspend fun delay(tag: String, url: String, timeoutMs: Int): Int = withContext(Dispatchers.IO) {
        val c = open("/proxies/$tag/delay?timeout=$timeoutMs&url=${URLEncoder.encode(url, "UTF-8")}", timeoutMs + 5000)
        try {
            val code = c.responseCode
            val body = (if (code == 200) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
            if (code == 200) JSONObject(body).getInt("delay")
            else throw IOException(if (code == 504) "timeout" else runCatching { JSONObject(body).getString("message") }.getOrDefault("HTTP $code"))
        } finally { c.disconnect() }
    }

    /** Streams (upBytesPerSec, downBytesPerSec). */
    fun traffic(): Flow<Pair<Long, Long>> = flow {
        val c = open("/traffic", 0)
        try {
            c.inputStream.bufferedReader().useLines { lines ->
                for (line in lines) {
                    val o = runCatching { JSONObject(line) }.getOrNull() ?: continue
                    emit(o.optLong("up") to o.optLong("down"))
                }
            }
        } finally { c.disconnect() }
    }.flowOn(Dispatchers.IO)
}
