package com.sepahi.ghostlark.bg

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.delay

/** Bridge between the UI and the foreground VPN service that hosts the sing-box core (same process). */
object CoreManager {
    enum class Loaded { NONE, TESTER, MAIN }

    @Volatile private var service: GhostlarkVpnService? = null
    val loaded = MutableStateFlow(Loaded.NONE)
    val revoked = MutableStateFlow(0)
    val logs = MutableStateFlow<List<String>>(emptyList())

    fun log(line: String) {
        logs.value = (logs.value + line).takeLast(1500)
    }

    internal fun attach(s: GhostlarkVpnService) { service = s }
    internal fun detach(s: GhostlarkVpnService) { if (service === s) { service = null; loaded.value = Loaded.NONE } }

    private suspend fun ensureService(context: Context): GhostlarkVpnService {
        service?.let { return it }
        ContextCompat.startForegroundService(context, Intent(context, GhostlarkVpnService::class.java).setAction(GhostlarkVpnService.ACTION_START))
        val s = withTimeoutOrNull(8000) {
            while (service == null) delay(50)
            service
        }
        return s ?: error("VPN service did not start")
    }

    /** Loads a config into the running core (starting the service if needed). Throws on core error. */
    suspend fun load(context: Context, config: String, kind: Loaded) {
        val s = ensureService(context)
        withContext(Dispatchers.IO) { s.loadConfig(config) }
        loaded.value = kind
    }

    suspend fun unload() {
        val s = service ?: return
        withContext(Dispatchers.IO) { runCatching { s.unloadConfig() } }
        loaded.value = Loaded.NONE
    }

    fun stopService(context: Context) {
        context.startService(Intent(context, GhostlarkVpnService::class.java).setAction(GhostlarkVpnService.ACTION_STOP))
    }

    fun updateNotification(text: String) { service?.updateNotification(text) }
}
