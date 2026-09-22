package com.sepahi.ghostlark.model

import kotlinx.serialization.Serializable

@Serializable
data class AppSettings(
    val apiPort: Int = 9090,
    val testerApiPort: Int = 9091,
    val stealthMode: Boolean = true,
    val extraStealth: Boolean = false,
    val shieldMode: Boolean = false,
    val shieldFallback: Boolean = false,
    val autoReconnect: Boolean = true,
    val tlsFragment: Boolean = true,
    val fragmentReality: Boolean = false,
    val domesticDirect: Boolean = true,
    val utlsFingerprint: String = "chrome",
    val testUrl: String = "https://www.gstatic.com/generate_204",
    val testTimeoutMs: Int = 6000,
    val testConcurrency: Int = 32,
    val testBatchSize: Int = 250,
    val quickScanSize: Int = 300,
    val hideUnsafe: Boolean = true,
    val includeWeak: Boolean = true,
) {
    val extraStealthOn: Boolean get() = stealthMode && extraStealth

    companion object {
        const val EXTRA_SCAN_SIZE = 80
        const val EXTRA_SCAN_CONCURRENCY = 8
        const val EXTRA_STOP_AFTER_OK = 6
        const val EXTRA_FAILOVER_BACKUPS = 3
    }
}

@Serializable
data class SubscriptionSource(
    val id: String,
    val name: String,
    val url: String,
    val enabled: Boolean = true,
    val isBuiltIn: Boolean = false,
    val lastFetch: Long? = null,
    val lastCount: Int? = null,
    val lastError: String? = null,
) {
    /** The original URL plus CDN mirrors (jsDelivr, Statically) that are rarely blocked. */
    val mirrorUrls: List<String>
        get() {
            val prefix = "https://raw.githubusercontent.com/"
            if (!url.startsWith(prefix)) return listOf(url)
            val parts = url.removePrefix(prefix).split('/')
            if (parts.size < 4) return listOf(url)
            val (user, repo, branch) = parts
            val path = parts.drop(3).joinToString("/")
            return listOf(url, "https://cdn.jsdelivr.net/gh/$user/$repo@$branch/$path", "https://cdn.statically.io/gh/$user/$repo/$branch/$path")
        }

    companion object {
        private fun b(name: String, url: String, enabled: Boolean = true) =
            SubscriptionSource(id = url.hashCode().toUInt().toString(16), name = name, url = url, enabled = enabled, isBuiltIn = true)

        val builtIns = listOf(
            b("Epodonios", "https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/All_Configs_Sub.txt"),
            b("MhdiTaheri Collector", "https://raw.githubusercontent.com/MhdiTaheri/V2rayCollector/main/sub/mix"),
            b("V2RayAggregator", "https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge.txt"),
            b("TGParse (Surfboard)", "https://raw.githubusercontent.com/Surfboardv2ray/TGParse/main/splitted/mixed"),
            b("ALIILAPRO", "https://raw.githubusercontent.com/ALIILAPRO/v2rayNG-Config/main/sub.txt"),
            b("SoliSpirit", "https://raw.githubusercontent.com/SoliSpirit/v2ray-configs/main/all_configs.txt"),
            b("MatinGhanbari", "https://raw.githubusercontent.com/MatinGhanbari/v2ray-configs/main/subscriptions/v2ray/all_sub.txt"),
            b("AzadNet", "https://raw.githubusercontent.com/AzadNetCH/Clash/main/AzadNet.txt"),
            b("Kwinshadow Telegram", "https://raw.githubusercontent.com/Kwinshadow/TelegramV2rayCollector/main/sublinks/mix.txt"),
            b("Mineral (LalatinaHub)", "https://raw.githubusercontent.com/LalatinaHub/Mineral/master/result/nodes"),
            b("ndsphonemy speed", "https://raw.githubusercontent.com/ndsphonemy/proxy-sub/main/speed.txt"),
            b("ProxyCollector (Mahdi0024)", "https://raw.githubusercontent.com/Mahdi0024/ProxyCollector/master/sub/proxies.txt"),
            b("Pawdroid", "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub"),
            b("roosterkid", "https://raw.githubusercontent.com/roosterkid/openproxylist/main/V2RAY_RAW.txt"),
            b("MahsaNet", "https://raw.githubusercontent.com/mahsanet/MahsaFreeConfig/main/mci/sub_1.txt"),
            b("NoMoreWalls", "https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list_raw.txt"),
            b("ebrasha (very large)", "https://raw.githubusercontent.com/ebrasha/free-v2ray-public-list/main/all_extracted_configs.txt", false),
            b("mheidari98 (very large)", "https://raw.githubusercontent.com/mheidari98/.proxy/main/all", false),
        )
    }
}

@Serializable
data class WarpAccount(
    val id: String, val token: String, val privateKey: String, val publicKey: String,
    val v4: String, val v6: String, val peerPublicKey: String, val endpointHost: String, val endpointPort: Int,
    val reserved: List<Int>, val created: Long,
)
