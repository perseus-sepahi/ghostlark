package com.sepahi.ghostlark.data

import android.content.Context
import com.sepahi.ghostlark.model.AppSettings
import com.sepahi.ghostlark.model.ProxyNode
import com.sepahi.ghostlark.model.SubscriptionSource
import com.sepahi.ghostlark.model.WarpAccount
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File

/** JSON persistence in the app's private files directory. */
class Store(context: Context) {
    private val dir = File(context.filesDir, "ghostlark").apply { mkdirs() }
    val coreDir: File = File(context.filesDir, "core").apply { mkdirs() }
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private inline fun <reified T> load(name: String, fallback: T, serializer: kotlinx.serialization.KSerializer<T>): T {
        val f = File(dir, name)
        if (!f.exists()) return fallback
        return runCatching { json.decodeFromString(serializer, f.readText()) }.getOrDefault(fallback)
    }

    private fun <T> save(name: String, value: T, serializer: kotlinx.serialization.KSerializer<T>) {
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(json.encodeToString(serializer, value))
        tmp.renameTo(File(dir, name))
    }

    fun loadSettings() = load("settings.json", AppSettings(), AppSettings.serializer())
    fun saveSettings(s: AppSettings) = save("settings.json", s, AppSettings.serializer())

    fun loadSources(): List<SubscriptionSource> {
        val saved = load("sources.json", emptyList(), ListSerializer(SubscriptionSource.serializer()))
        val known = saved.map { it.url }.toSet()
        return saved + SubscriptionSource.builtIns.filter { it.url !in known }
    }
    fun saveSources(s: List<SubscriptionSource>) = save("sources.json", s, ListSerializer(SubscriptionSource.serializer()))

    fun loadNodes() = load("nodes.json", emptyList(), ListSerializer(ProxyNode.serializer()))
    fun saveNodes(n: List<ProxyNode>) = save("nodes.json", n, ListSerializer(ProxyNode.serializer()))

    fun loadWarp(): WarpAccount? {
        val f = File(dir, "warp.json")
        if (!f.exists()) return null
        return runCatching { json.decodeFromString(WarpAccount.serializer(), f.readText()) }.getOrNull()
    }
    fun saveWarp(w: WarpAccount?) { if (w == null) File(dir, "warp.json").delete() else save("warp.json", w, WarpAccount.serializer()) }
}
