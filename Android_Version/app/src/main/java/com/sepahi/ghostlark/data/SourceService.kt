package com.sepahi.ghostlark.data

import com.sepahi.ghostlark.model.SubscriptionSource
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL

object SourceService {
    private fun fetchOne(url: String): String? {
        val c = URL(url).openConnection(Proxy.NO_PROXY) as HttpURLConnection
        c.connectTimeout = 15000; c.readTimeout = 30000
        c.setRequestProperty("User-Agent", "Ghostlark/0.1 (Android)")
        c.useCaches = false
        return try {
            if (c.responseCode != 200) null
            else c.inputStream.bufferedReader().readText().takeIf { it.length > 20 }
        } catch (e: Exception) { null } finally { c.disconnect() }
    }

    /** Races the original URL against CDN mirrors; first success wins. */
    suspend fun fetch(src: SubscriptionSource): String = coroutineScope {
        val result = CompletableDeferred<String?>()
        val jobs = src.mirrorUrls.map { u ->
            launch(Dispatchers.IO) { val t = fetchOne(u); if (t != null) result.complete(t) }
        }
        launch { jobs.joinAll(); result.complete(null) }
        val text = result.await()
        coroutineContext.cancelChildren()
        text ?: throw IOException("All mirrors failed")
    }

    suspend fun httpGet(url: String, timeoutMs: Int = 15000): String = withContext(Dispatchers.IO) {
        val c = URL(url).openConnection(Proxy.NO_PROXY) as HttpURLConnection
        c.connectTimeout = timeoutMs; c.readTimeout = timeoutMs
        try { c.inputStream.bufferedReader().readText() } finally { c.disconnect() }
    }
}
