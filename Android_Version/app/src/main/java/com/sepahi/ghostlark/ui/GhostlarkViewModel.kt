package com.sepahi.ghostlark.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.sepahi.ghostlark.bg.CoreManager
import com.sepahi.ghostlark.core.ClashApi
import com.sepahi.ghostlark.core.SingBoxConfig
import com.sepahi.ghostlark.core.Warp
import com.sepahi.ghostlark.data.SourceService
import com.sepahi.ghostlark.data.Store
import com.sepahi.ghostlark.model.AppSettings
import com.sepahi.ghostlark.model.ProxyNode
import com.sepahi.ghostlark.model.ShareLinkParser
import com.sepahi.ghostlark.model.SubscriptionSource
import com.sepahi.ghostlark.model.Tier
import com.sepahi.ghostlark.model.WarpAccount
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.util.UUID

sealed class ConnState {
    object Disconnected : ConnState()
    data class Connecting(val phase: String) : ConnState()
    data class Connected(val node: ProxyNode, val shield: Boolean) : ConnState()
    data class Failed(val message: String) : ConnState()
    val isConnected get() = this is Connected
    val isBusy get() = this is Connecting
}

class GhostlarkViewModel(app: Application) : AndroidViewModel(app) {
    private val store = Store(app)
    private val ctx get() = getApplication<Application>()

    var settings by mutableStateOf(store.loadSettings()); private set
    var sources by mutableStateOf(store.loadSources()); private set
    private var allNodes: List<ProxyNode> = store.loadNodes()
    var displayed by mutableStateOf<List<ProxyNode>>(emptyList()); private set
    var filterText by mutableStateOf(""); private set
    var onlyVerified by mutableStateOf(false); private set
    var warp by mutableStateOf(store.loadWarp()); private set

    var conn by mutableStateOf<ConnState>(ConnState.Disconnected); private set
    var phase by mutableStateOf<String?>(null); private set
    var isFetching by mutableStateOf(false); private set
    var fetchStatus by mutableStateOf(""); private set
    var isTesting by mutableStateOf(false); private set
    var testDone by mutableStateOf(0); private set
    var testTotal by mutableStateOf(0); private set
    var testOk by mutableStateOf(0); private set
    var lastError by mutableStateOf<String?>(null); private set
    var warning by mutableStateOf<String?>(null); private set
    var upBps by mutableStateOf(0L); private set
    var downBps by mutableStateOf(0L); private set
    var totalUp by mutableStateOf(0L); private set
    var totalDown by mutableStateOf(0L); private set
    var exitInfo by mutableStateOf<String?>(null); private set
    var warpBusy by mutableStateOf(false); private set
    var poolSize by mutableStateOf(1); private set

    private var trafficJob: Job? = null
    private var cancelTest = false
    private var reconnectAttempts = 0

    val usableCount get() = allNodes.count { it.supported && it.tier != Tier.UNSAFE }
    val verifiedCount get() = allNodes.count { it.testedOk }
    val busy get() = conn.isBusy || phase != null || isFetching || isTesting

    init {
        ensureWarpNode()
        refilter()
        viewModelScope.launch {
            CoreManager.revoked.collect { if (it > 0 && conn.isConnected) onCoreLost("VPN was revoked by the system") }
        }
    }

    // MARK: settings & filters

    fun updateSettings(f: (AppSettings) -> AppSettings) { settings = f(settings); store.saveSettings(settings); refilter() }
    fun setFilter(t: String) { filterText = t; refilter() }
    fun showVerifiedOnly(v: Boolean) { onlyVerified = v; refilter() }

    private fun ensureWarpNode() {
        val has = allNodes.any { it.id == ProxyNode.WARP_ID }
        if (warp != null && !has) allNodes = listOf(ProxyNode.warpNode()) + allNodes
        if (warp == null && has) allNodes = allNodes.filter { it.id != ProxyNode.WARP_ID }
    }

    private fun refilter() {
        val t = filterText.trim().lowercase()
        val stealth = settings.stealthMode
        displayed = allNodes.asSequence()
            .filter { n -> n.supported && !(settings.hideUnsafe && n.tier == Tier.UNSAFE) }
            .filter { n -> !onlyVerified || n.testedOk }
            .filter { n -> t.isEmpty() || n.name.lowercase().contains(t) || n.server.lowercase().contains(t) || n.sourceName.lowercase().contains(t) || n.countryCode?.lowercase() == t }
            .sortedByDescending { it.rank(stealth, extra = settings.extraStealthOn) }
            .toList()
    }

    private fun updateNode(id: String, f: (ProxyNode) -> ProxyNode) { allNodes = allNodes.map { if (it.id == id) f(it) else it } }
    private fun persistNodes() { val snapshot = allNodes; viewModelScope.launch(Dispatchers.IO) { runCatching { store.saveNodes(snapshot) } } }

    private fun merge(fetched: List<ProxyNode>): Int {
        val index = LinkedHashMap<String, ProxyNode>(allNodes.size + fetched.size)
        allNodes.forEach { index[it.id] = it }
        var added = 0
        val now = System.currentTimeMillis()
        for (n in fetched) {
            val e = index[n.id]
            if (e != null) index[n.id] = e.copy(lastSeen = now) else { index[n.id] = n; added++ }
        }
        val cutoff = now - 7L * 86400_000
        var merged = index.values.filter { it.isWarp || it.okCount > 0 || it.lastSeen > cutoff }
        if (merged.size > 30_000) merged = merged.sortedByDescending { it.rank(settings.stealthMode) }.take(30_000)
        allNodes = merged
        ensureWarpNode(); refilter(); persistNodes()
        return added
    }

    // MARK: sources

    fun addSource(name: String, url: String) {
        val u = url.trim(); if (!u.startsWith("http")) return
        sources = sources + SubscriptionSource(UUID.randomUUID().toString(), name.ifBlank { u.substringAfter("://").substringBefore("/") }, u)
        store.saveSources(sources)
    }
    fun toggleSource(id: String, enabled: Boolean) { sources = sources.map { if (it.id == id) it.copy(enabled = enabled) else it }; store.saveSources(sources) }
    fun removeSource(id: String) { sources = sources.filter { it.id != id || it.isBuiltIn }; store.saveSources(sources) }
    fun importLinks(text: String): Int = merge(ShareLinkParser.parseSubscription(text, "Manual"))

    fun refreshSources() { viewModelScope.launch { refreshSourcesNow() } }

    private suspend fun refreshSourcesNow() {
        if (isFetching) return
        isFetching = true
        try {
            val enabled = sources.filter { it.enabled }
            fetchStatus = "Fetching ${enabled.size} sources…"
            val all = mutableListOf<ProxyNode>()
            var finished = 0
            coroutineScope {
                enabled.map { src ->
                    async(Dispatchers.IO) {
                        val r = runCatching { ShareLinkParser.parseSubscription(SourceService.fetch(src), src.name) }
                        withContext(Dispatchers.Main) {
                            finished++
                            r.onSuccess { list -> all += list; sources = sources.map { if (it.id == src.id) it.copy(lastFetch = System.currentTimeMillis(), lastCount = list.size, lastError = null) else it }; CoreManager.log("[sources] ${src.name}: ${list.size} links") }
                                .onFailure { e -> sources = sources.map { if (it.id == src.id) it.copy(lastFetch = System.currentTimeMillis(), lastCount = null, lastError = e.message) else it }; CoreManager.log("[sources] ${src.name} failed: ${e.message}") }
                            fetchStatus = "Fetched $finished/${enabled.size} (${all.size} links)"
                        }
                    }
                }.awaitAll()
            }
            store.saveSources(sources)
            val added = merge(all)
            CoreManager.log("[sources] merged: $added new, ${allNodes.size} total, $usableCount usable")
        } finally { isFetching = false; fetchStatus = "" }
    }

    // MARK: testing

    private fun eligible(): List<ProxyNode> {
        val min = if (settings.includeWeak) Tier.WEAK else Tier.GOOD
        val extra = settings.extraStealthOn
        return allNodes.filter { it.supported && it.tier >= min && (!it.isWarp || warp != null) && (!extra || it.extraStealthEligible) }
    }

    fun cancelTest() { cancelTest = true }
    fun quickScan() {
        viewModelScope.launch {
            val extra = settings.extraStealthOn
            val list = eligible().sortedByDescending { it.rank(settings.stealthMode, extra = extra) }
                .take(if (extra) AppSettings.EXTRA_SCAN_SIZE else settings.quickScanSize)
            testNodes(list, quiet = extra, stopAfterOk = if (extra) AppSettings.EXTRA_STOP_AFTER_OK * 2 else null)
        }
    }
    fun fullScan() { viewModelScope.launch { testNodes(eligible()) } }

    /** quiet = Extra Stealth scan: few probes, low concurrency, stop once enough servers answer. */
    private suspend fun testNodes(list: List<ProxyNode>, quiet: Boolean = false, stopAfterOk: Int? = null) {
        if (isTesting || list.isEmpty() || conn.isConnected || conn.isBusy) return
        isTesting = true; cancelTest = false; testDone = 0; testOk = 0; testTotal = list.size
        try {
            val secret = UUID.randomUUID().toString()
            val api = ClashApi(settings.testerApiPort, secret)
            val sem = Semaphore(if (quiet) AppSettings.EXTRA_SCAN_CONCURRENCY else settings.testConcurrency.coerceIn(4, 96))
            var start = 0
            while (start < list.size && !cancelTest) {
                val batch = list.subList(start, minOf(list.size, start + settings.testBatchSize))
                start += batch.size
                try {
                    CoreManager.load(ctx, SingBoxConfig.testerConfig(batch, settings, warp, secret), CoreManager.Loaded.TESTER)
                } catch (e: Exception) {
                    CoreManager.log("[tester] core failed: ${e.message}"); lastError = "Tester failed: ${e.message}"
                    testDone += batch.size; continue
                }
                if (!api.waitReady(10000)) { CoreManager.log("[tester] not ready"); CoreManager.unload(); testDone += batch.size; continue }
                coroutineScope {
                    batch.map { n ->
                        async {
                            sem.withPermit {
                                if (cancelTest) return@withPermit
                                val r = runCatching { api.delay(n.tag, settings.testUrl, settings.testTimeoutMs) }
                                withContext(Dispatchers.Main) {
                                    testDone++
                                    r.onSuccess { ms -> testOk++; if (stopAfterOk != null && testOk >= stopAfterOk) cancelTest = true; updateNode(n.id) { it.copy(latencyMs = ms, lastError = null, lastTested = System.currentTimeMillis(), okCount = it.okCount + 1) } }
                                        .onFailure { e -> updateNode(n.id) { it.copy(latencyMs = null, lastError = e.message, lastTested = System.currentTimeMillis(), failCount = it.failCount + 1) } }
                                }
                            }
                        }
                    }.awaitAll()
                }
                CoreManager.unload()
            }
        } finally { isTesting = false; refilter(); persistNodes() }
    }

    // MARK: connection

    fun connect(node: ProxyNode) { viewModelScope.launch { connectNow(node) } }

    private suspend fun connectNow(node: ProxyNode, allowShield: Boolean = true): Boolean {
        lastError = null; warning = null
        val extra = settings.extraStealthOn
        if (extra && !node.extraStealthEligible) {
            lastError = "${node.name.take(30)} does not meet Extra Stealth rules (needs Reality, or verified TLS with WebSocket/gRPC on an HTTPS port)."
            conn = ConnState.Failed(lastError!!); return false
        }
        if ((node.isWarp || settings.shieldMode) && warp == null) { ensureWarpNow(); if (warp == null && node.isWarp) return false }
        val effective = if (allowShield) settings else settings.copy(shieldMode = false)
        val shield = effective.shieldMode && warp != null && !node.isWarp
        val exit = if (shield || node.isWarp) "warp" else "proxy"
        conn = ConnState.Connecting("Starting core")
        trafficJob?.cancel()
        val secret = UUID.randomUUID().toString()
        val api = ClashApi(settings.apiPort, secret)
        try {
            val backups = if (!extra) emptyList() else allNodes
                .filter { it.id != node.id && it.testedOk && it.extraStealthEligible && (!shield || it.shieldCapable == true) }
                .sortedByDescending { it.rank(settings.stealthMode, shield, extra = true) }.take(AppSettings.EXTRA_FAILOVER_BACKUPS)
            poolSize = 1 + backups.size
            CoreManager.load(ctx, SingBoxConfig.mainConfig(node, effective, warp, secret, backups), CoreManager.Loaded.MAIN)
        } catch (e: Exception) {
            conn = ConnState.Failed("Core failed to start: ${e.message}"); lastError = e.message; return false
        }
        if (!api.waitReady(10000)) { CoreManager.unload(); conn = ConnState.Failed("Core did not become ready"); lastError = "Core did not become ready"; return false }
        conn = ConnState.Connecting(if (shield) "Verifying Shield tunnel" else "Verifying tunnel")
        try {
            api.delay(exit, settings.testUrl, if (shield) 9000 else 12000)
        } catch (e: Exception) {
            CoreManager.unload()
            val hint = if (shield) " (Shield needs a server that relays UDP)" else ""
            val msg = "Server unreachable: ${e.message}$hint"
            conn = ConnState.Failed(msg); lastError = msg
            updateNode(node.id) { if (shield) it.copy(shieldCapable = false) else it.copy(latencyMs = null, lastError = msg, failCount = it.failCount + 1) }
            refilter(); persistNodes()
            return false
        }
        conn = ConnState.Connected(node, shield)
        updateNode(node.id) { it.copy(okCount = it.okCount + 1, shieldCapable = if (shield) true else it.shieldCapable) }
        if (settings.shieldMode && !shield && !node.isWarp) warning = "Connected without Shield: this server does not relay UDP."
        reconnectAttempts = 0
        refilter(); persistNodes()
        CoreManager.updateNotification("Connected · ${node.name.take(30)}")
        totalUp = 0; totalDown = 0; upBps = 0; downBps = 0; exitInfo = null
        trafficJob = viewModelScope.launch {
            try { api.traffic().collect { (u, d) -> upBps = u; downBps = d; totalUp += u; totalDown += d } } catch (_: Exception) {}
            if (conn.isConnected) onCoreLost("Core stopped unexpectedly")
        }
        viewModelScope.launch {
            val t = runCatching { SourceService.httpGet("https://www.cloudflare.com/cdn-cgi/trace") }.getOrNull() ?: return@launch
            val kv = t.lines().mapNotNull { l -> l.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }.toMap()
            if (conn.isConnected) exitInfo = listOfNotNull(kv["ip"]?.let { "Exit $it" }, kv["loc"], if (kv["warp"] == "on" || kv["warp"] == "plus") "via WARP" else null).joinToString(" · ")
        }
        return true
    }

    private fun onCoreLost(reason: String) {
        trafficJob?.cancel()
        conn = ConnState.Failed(reason)
        CoreManager.log("[ghostlark] $reason")
        if (settings.autoReconnect && reconnectAttempts < 3) { reconnectAttempts++; viewModelScope.launch { autoConnectNow() } }
    }

    fun disconnect() {
        viewModelScope.launch {
            trafficJob?.cancel()
            phase = null
            CoreManager.unload()
            CoreManager.stopService(ctx)
            conn = ConnState.Disconnected
            upBps = 0; downBps = 0; exitInfo = null
        }
    }

    fun autoConnect() { viewModelScope.launch { autoConnectNow() } }

    private suspend fun autoConnectNow() {
        if (phase != null) return
        lastError = null
        try {
            if (settings.shieldMode && warp == null) { phase = "Registering WARP for Shield"; ensureWarpNow() }
            val newest = sources.mapNotNull { it.lastFetch }.maxOrNull()
            val stale = newest == null || System.currentTimeMillis() - newest > 12 * 3600_000L
            if (usableCount < 30 || stale) { phase = "Fetching server lists"; refreshSourcesNow() }
            val stealth = settings.stealthMode
            val shield = settings.shieldMode && warp != null
            val extra = settings.extraStealthOn
            val candidates = eligible().sortedByDescending { it.rank(stealth, shield, extra) }.take(if (extra) AppSettings.EXTRA_SCAN_SIZE else settings.quickScanSize)
            if (candidates.isEmpty()) { lastError = "No usable servers found. Check Sources and your network."; return }
            phase = if (extra) "Quiet scan of up to ${candidates.size} servers" else "Testing ${candidates.size} servers"
            testNodes(candidates, quiet = extra, stopAfterOk = if (extra) (if (shield) 16 else AppSettings.EXTRA_STOP_AFTER_OK) else null)
            val ids = candidates.map { it.id }.toSet()
            val working = allNodes.filter { it.id in ids && it.testedOk }.sortedByDescending { it.rank(stealth, shield, extra) }
            if (working.isEmpty()) { lastError = if (extra) "No Extra Stealth server answered. Refresh sources, or turn Extra Stealth off for a wider choice." else "None of the tested servers responded. Try a Full scan or add sources."; return }
            val tries = working.take(if (shield) 24 else 6)
            for ((i, n) in tries.withIndex()) {
                phase = (if (shield) "Probing Shield via " else "Connecting to ") + "${n.name.take(28)} (${i + 1}/${tries.size})"
                if (connectNow(n)) return
            }
            if (shield && settings.shieldFallback) { phase = "No Shield-capable server; connecting plain"; if (connectNow(working.first(), allowShield = false)) return }
            lastError = if (shield && !settings.shieldFallback) "No tested server relays UDP for Shield. Run a Full scan, or enable the plain-proxy fallback in Settings."
            else (lastError ?: "Could not establish a verified connection.")
        } finally { phase = null }
    }

    // MARK: WARP

    fun ensureWarp() { viewModelScope.launch { ensureWarpNow() } }
    private suspend fun ensureWarpNow(): WarpAccount? {
        warp?.let { return it }
        if (warpBusy) return null
        warpBusy = true
        try {
            val a = Warp.register()
            warp = a; store.saveWarp(a); ensureWarpNode(); refilter(); persistNodes()
            CoreManager.log("[warp] registered device ${a.id}")
            return a
        } catch (e: Exception) {
            lastError = "WARP registration failed: ${e.message}"; CoreManager.log("[warp] failed: ${e.message}"); return null
        } finally { warpBusy = false }
    }
    fun resetWarp() { warp = null; store.saveWarp(null); ensureWarpNode(); refilter(); persistNodes() }
}
