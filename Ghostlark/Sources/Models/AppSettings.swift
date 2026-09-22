import Foundation

struct AppSettings: Codable, Equatable {
    var localPort = 2080
    var apiPort = 9090
    var testerApiPort = 9091

    var stealthMode = true
    /// Stricter than Stealth: only camouflaged protocols, quiet scanning, QUIC blocked, failover pool.
    var extraStealth = false
    var shieldMode = false
    var shieldFallback = false
    var killSwitch = true
    var autoReconnect = true
    var setSystemProxy = true

    var tlsFragment = true
    var fragmentReality = false
    var domesticDirect = true
    var utlsFingerprint = "chrome"

    var testURL = "https://www.gstatic.com/generate_204"
    var testTimeoutMs = 6000
    var testConcurrency = 48
    var testBatchSize = 300
    var quickScanSize = 400

    var hideUnsafe = true
    var includeWeak = true
    var showMenuBar = true

    init() {}

    var extraStealthOn: Bool { stealthMode && extraStealth }
    /// Extra Stealth scan limits: a burst of hundreds of connections to foreign proxy IPs is itself a signature.
    static let extraScanSize = 80
    static let extraScanConcurrency = 8
    static let extraStopAfterOK = 6
    static let extraFailoverBackups = 3

    enum CodingKeys: String, CodingKey {
        case localPort, apiPort, testerApiPort, stealthMode, extraStealth, shieldMode, shieldFallback, killSwitch, autoReconnect, setSystemProxy
        case tlsFragment, fragmentReality, domesticDirect, utlsFingerprint
        case testURL, testTimeoutMs, testConcurrency, testBatchSize, quickScanSize
        case hideUnsafe, includeWeak, showMenuBar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? d.localPort
        apiPort = try c.decodeIfPresent(Int.self, forKey: .apiPort) ?? d.apiPort
        testerApiPort = try c.decodeIfPresent(Int.self, forKey: .testerApiPort) ?? d.testerApiPort
        stealthMode = try c.decodeIfPresent(Bool.self, forKey: .stealthMode) ?? d.stealthMode
        extraStealth = try c.decodeIfPresent(Bool.self, forKey: .extraStealth) ?? d.extraStealth
        shieldMode = try c.decodeIfPresent(Bool.self, forKey: .shieldMode) ?? d.shieldMode
        shieldFallback = try c.decodeIfPresent(Bool.self, forKey: .shieldFallback) ?? d.shieldFallback
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? d.killSwitch
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        setSystemProxy = try c.decodeIfPresent(Bool.self, forKey: .setSystemProxy) ?? d.setSystemProxy
        tlsFragment = try c.decodeIfPresent(Bool.self, forKey: .tlsFragment) ?? d.tlsFragment
        fragmentReality = try c.decodeIfPresent(Bool.self, forKey: .fragmentReality) ?? d.fragmentReality
        domesticDirect = try c.decodeIfPresent(Bool.self, forKey: .domesticDirect) ?? d.domesticDirect
        utlsFingerprint = try c.decodeIfPresent(String.self, forKey: .utlsFingerprint) ?? d.utlsFingerprint
        testURL = try c.decodeIfPresent(String.self, forKey: .testURL) ?? d.testURL
        testTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .testTimeoutMs) ?? d.testTimeoutMs
        testConcurrency = try c.decodeIfPresent(Int.self, forKey: .testConcurrency) ?? d.testConcurrency
        testBatchSize = try c.decodeIfPresent(Int.self, forKey: .testBatchSize) ?? d.testBatchSize
        quickScanSize = try c.decodeIfPresent(Int.self, forKey: .quickScanSize) ?? d.quickScanSize
        hideUnsafe = try c.decodeIfPresent(Bool.self, forKey: .hideUnsafe) ?? d.hideUnsafe
        includeWeak = try c.decodeIfPresent(Bool.self, forKey: .includeWeak) ?? d.includeWeak
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? d.showMenuBar
    }
}

struct SubscriptionSource: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var enabled: Bool
    var isBuiltIn: Bool
    var lastFetch: Date?
    var lastCount: Int?
    var lastError: String?

    init(name: String, url: String, enabled: Bool = true, isBuiltIn: Bool = false) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
    }

    /// Alternate URLs for the same file served from CDNs that are rarely blocked
    /// (jsDelivr, Statically). Only GitHub raw URLs have mirrors.
    var mirrorURLs: [String] {
        guard let u = URL(string: url), u.host == "raw.githubusercontent.com" else { return [url] }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return [url] }
        let user = parts[0], repo = parts[1], branch = parts[2]
        let path = parts[3...].joined(separator: "/")
        return [
            url,
            "https://cdn.jsdelivr.net/gh/\(user)/\(repo)@\(branch)/\(path)",
            "https://cdn.statically.io/gh/\(user)/\(repo)/\(branch)/\(path)",
        ]
    }

    static let builtIns: [SubscriptionSource] = [
        SubscriptionSource(name: "Epodonios", url: "https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/All_Configs_Sub.txt", isBuiltIn: true),
        SubscriptionSource(name: "MhdiTaheri Collector", url: "https://raw.githubusercontent.com/MhdiTaheri/V2rayCollector/main/sub/mix", isBuiltIn: true),
        SubscriptionSource(name: "V2RayAggregator", url: "https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge.txt", isBuiltIn: true),
        SubscriptionSource(name: "TGParse (Surfboard)", url: "https://raw.githubusercontent.com/Surfboardv2ray/TGParse/main/splitted/mixed", isBuiltIn: true),
        SubscriptionSource(name: "ALIILAPRO", url: "https://raw.githubusercontent.com/ALIILAPRO/v2rayNG-Config/main/sub.txt", isBuiltIn: true),
        SubscriptionSource(name: "SoliSpirit", url: "https://raw.githubusercontent.com/SoliSpirit/v2ray-configs/main/all_configs.txt", isBuiltIn: true),
        SubscriptionSource(name: "MatinGhanbari", url: "https://raw.githubusercontent.com/MatinGhanbari/v2ray-configs/main/subscriptions/v2ray/all_sub.txt", isBuiltIn: true),
        SubscriptionSource(name: "AzadNet", url: "https://raw.githubusercontent.com/AzadNetCH/Clash/main/AzadNet.txt", isBuiltIn: true),
        SubscriptionSource(name: "Kwinshadow Telegram", url: "https://raw.githubusercontent.com/Kwinshadow/TelegramV2rayCollector/main/sublinks/mix.txt", isBuiltIn: true),
        SubscriptionSource(name: "Mineral (LalatinaHub)", url: "https://raw.githubusercontent.com/LalatinaHub/Mineral/master/result/nodes", isBuiltIn: true),
        SubscriptionSource(name: "ndsphonemy speed", url: "https://raw.githubusercontent.com/ndsphonemy/proxy-sub/main/speed.txt", isBuiltIn: true),
        SubscriptionSource(name: "ProxyCollector (Mahdi0024)", url: "https://raw.githubusercontent.com/Mahdi0024/ProxyCollector/master/sub/proxies.txt", isBuiltIn: true),
        SubscriptionSource(name: "Pawdroid", url: "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub", isBuiltIn: true),
        SubscriptionSource(name: "roosterkid", url: "https://raw.githubusercontent.com/roosterkid/openproxylist/main/V2RAY_RAW.txt", isBuiltIn: true),
        SubscriptionSource(name: "MahsaNet", url: "https://raw.githubusercontent.com/mahsanet/MahsaFreeConfig/main/mci/sub_1.txt", isBuiltIn: true),
        SubscriptionSource(name: "NoMoreWalls", url: "https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list_raw.txt", isBuiltIn: true),
        SubscriptionSource(name: "ebrasha (very large)", url: "https://raw.githubusercontent.com/ebrasha/free-v2ray-public-list/main/all_extracted_configs.txt", enabled: false, isBuiltIn: true),
        SubscriptionSource(name: "mheidari98 (very large)", url: "https://raw.githubusercontent.com/mheidari98/.proxy/main/all", enabled: false, isBuiltIn: true),
    ]
}
