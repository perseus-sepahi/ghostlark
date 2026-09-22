import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    /// Not @Published on purpose: SwiftUI bindings (MenuBarExtra, toggles) write back equal
    /// values during updates, and @Published would publish every time and spin the view graph.
    var settings: AppSettings {
        willSet { if newValue != settings { objectWillChange.send() } }
        didSet { if settings != oldValue { saveSettings(); refilter() } }
    }
    @Published var sources: [SubscriptionSource] { didSet { saveSources() } }
    @Published private(set) var nodes: [ProxyNode] = []
    @Published private(set) var displayed: [ProxyNode] = []

    @Published var filterText = "" { didSet { refilter() } }
    @Published var filterProtocol: ProxyProtocol? = nil { didSet { refilter() } }
    @Published var onlyTestedOK = false { didSet { refilter() } }
    @Published var sortOrder: [KeyPathComparator<ProxyNode>] = [] { didSet { refilter() } }
    @Published var selection: Set<String> = []

    @Published var isFetching = false
    @Published var fetchStatus = ""
    @Published var warp: WARPAccount?
    @Published var warpBusy = false
    @Published var autoPhase: String? = nil
    @Published var lastError: String? = nil
    @Published var warning: String? = nil

    let connection = ConnectionManager()
    let tester = NodeTester()
    let log = LogStore()

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Ghostlark", isDirectory: true)
        // The app was called Aegis before 0.3.0: carry the saved servers, sources and settings over once.
        let legacy = base.appendingPathComponent("Aegis", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("core"), withIntermediateDirectories: true)
        return dir
    }()
    var workDir: URL { AppState.supportDir.appendingPathComponent("core", isDirectory: true) }

    private var nodeSaveTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var reconnectWindowStart = Date()

    init() {
        let dir = AppState.supportDir
        let dec = JSONDecoder()
        settings = (try? dec.decode(AppSettings.self, from: Data(contentsOf: dir.appendingPathComponent("settings.json")))) ?? AppSettings()
        var loadedSources = (try? dec.decode([SubscriptionSource].self, from: Data(contentsOf: dir.appendingPathComponent("sources.json")))) ?? []
        // Merge in any new built-ins by URL.
        let known = Set(loadedSources.map { $0.url })
        for b in SubscriptionSource.builtIns where !known.contains(b.url) { loadedSources.append(b) }
        sources = loadedSources
        warp = WARPService.load()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("nodes.json")),
           let saved = try? dec.decode([ProxyNode].self, from: data) {
            nodes = saved
        }
        ensureWARPNode()
        refilter()
        CoreProcess.killStale(workDir: workDir)
        // A crash or forced quit can leave macOS pointing at our dead local port, which breaks browsing.
        let port = settings.localPort
        Task.detached(priority: .userInitiated) { if SystemProxy.isSet(port: port) { SystemProxy.clear() } }
        if let path = ProcessInfo.processInfo.environment["GHOSTLARK_LOGFILE"] { log.mirrorFile = URL(fileURLWithPath: path) }

        connection.onUnexpectedExit = { [weak self] in
            guard let self = self else { return }
            self.log.append("[ghostlark] core exited unexpectedly")
            if self.settings.autoReconnect { Task { await self.reconnectAfterFailure() } }
        }
    }

    // MARK: Persistence

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) {
            try? d.write(to: AppState.supportDir.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    private func saveSources() {
        if let d = try? JSONEncoder().encode(sources) {
            try? d.write(to: AppState.supportDir.appendingPathComponent("sources.json"), options: .atomic)
        }
    }

    private func scheduleNodeSave() {
        nodeSaveTask?.cancel()
        let snapshot = nodes
        let url = AppState.supportDir.appendingPathComponent("nodes.json")
        nodeSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    // MARK: Node store

    private func ensureWARPNode() {
        let warpNode = WARPService.node()
        if warp != nil {
            if !nodes.contains(where: { $0.id == warpNode.id }) { nodes.insert(warpNode, at: 0) }
        } else {
            nodes.removeAll { $0.id == warpNode.id }
        }
    }

    func setNodes(_ new: [ProxyNode]) {
        nodes = new
        refilter()
        scheduleNodeSave()
    }

    func updateNode(id: String, _ mutate: (inout ProxyNode) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&nodes[i])
    }

    func applyTestResult(id: String, outcome: TestOutcome) {
        updateNode(id: id) { n in
            n.test = outcome
            n.lastTested = Date()
            if outcome.isOK { n.okCount += 1 } else { n.failCount += 1 }
        }
    }

    func deleteNodes(ids: Set<String>) {
        nodes.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        refilter()
        scheduleNodeSave()
    }

    func merge(_ fetched: [ProxyNode]) -> Int {
        var index: [String: ProxyNode] = [:]
        index.reserveCapacity(nodes.count + fetched.count)
        for n in nodes { index[n.id] = n }
        var added = 0
        let now = Date()
        for n in fetched {
            if var existing = index[n.id] {
                existing.lastSeen = now
                if existing.name.count < 3 && n.name.count >= 3 { existing.name = n.name }
                index[n.id] = existing
            } else {
                index[n.id] = n
                added += 1
            }
        }
        // Prune stale nodes that never worked.
        let cutoff = now.addingTimeInterval(-7 * 86400)
        var merged = index.values.filter { $0.isWARP || $0.okCount > 0 || $0.lastSeen > cutoff }
        if merged.count > 40_000 {
            merged.sort { $0.rank(stealthWeighted: settings.stealthMode) > $1.rank(stealthWeighted: settings.stealthMode) }
            merged = Array(merged.prefix(40_000))
        }
        nodes = merged
        ensureWARPNode()
        refilter()
        scheduleNodeSave()
        return added
    }

    func refilter() {
        let text = filterText.lowercased().trimmingCharacters(in: .whitespaces)
        let hideUnsafe = settings.hideUnsafe
        var list = nodes.filter { n in
            if hideUnsafe && n.tier == .unsafe { return false }
            if !n.supported { return false }
            if let p = filterProtocol, n.proto != p { return false }
            if onlyTestedOK && !n.test.isOK { return false }
            if !text.isEmpty {
                return n.name.lowercased().contains(text) || n.server.lowercased().contains(text)
                    || n.sourceName.lowercased().contains(text) || (n.countryCode?.lowercased() == text)
            }
            return true
        }
        if sortOrder.isEmpty {
            let stealth = settings.stealthMode, extra = settings.extraStealthOn
            list.sort { $0.rank(stealthWeighted: stealth, extra: extra) > $1.rank(stealthWeighted: stealth, extra: extra) }
        } else {
            list.sort(using: sortOrder)
        }
        displayed = list
    }

    var supportedCount: Int { nodes.filter { $0.supported && $0.tier != .unsafe }.count }
    var testedOKCount: Int { nodes.filter { $0.test.isOK }.count }

    // MARK: Sources

    func refreshSources() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false; fetchStatus = "" }
        let proxyPort = connection.state.isConnected ? settings.localPort : nil
        let enabled = sources.filter { $0.enabled }
        fetchStatus = "Fetching \(enabled.count) sources…"
        var all: [ProxyNode] = []
        var results: [UUID: (Int?, String?)] = [:]

        await withTaskGroup(of: (UUID, String, Result<[ProxyNode], Error>).self) { group in
            for src in enabled {
                group.addTask {
                    do {
                        let text = try await SourceService.fetch(src, proxyPort: proxyPort)
                        let parsed = await Task.detached(priority: .userInitiated) {
                            ShareLinkParser.parseSubscription(text, source: src.name)
                        }.value
                        return (src.id, src.name, .success(parsed))
                    } catch {
                        return (src.id, src.name, .failure(error))
                    }
                }
            }
            var finished = 0
            for await (id, name, result) in group {
                finished += 1
                switch result {
                case .success(let parsed):
                    all.append(contentsOf: parsed)
                    results[id] = (parsed.count, nil)
                    log.append("[sources] \(name): \(parsed.count) links")
                case .failure(let e):
                    results[id] = (nil, e.localizedDescription)
                    log.append("[sources] \(name) failed: \(e.localizedDescription)")
                }
                fetchStatus = "Fetched \(finished)/\(enabled.count) sources (\(all.count) links)"
            }
        }
        let now = Date()
        for i in sources.indices {
            if let r = results[sources[i].id] {
                sources[i].lastFetch = now
                sources[i].lastCount = r.0
                sources[i].lastError = r.1
            }
        }
        let added = merge(all)
        log.append("[sources] merged: \(added) new, \(nodes.count) total, \(supportedCount) usable")
    }

    func addSource(name: String, url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed) != nil else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        sources.append(SubscriptionSource(name: n.isEmpty ? (URL(string: trimmed)?.host ?? "Custom") : n, url: trimmed))
    }

    func removeSource(_ id: UUID) { sources.removeAll { $0.id == id && !$0.isBuiltIn } }

    /// Imports pasted share links or a raw subscription payload.
    func importText(_ text: String) -> Int {
        let parsed = ShareLinkParser.parseSubscription(text, source: "Manual")
        return merge(parsed)
    }

    // MARK: Testing

    func eligibleForTesting() -> [ProxyNode] {
        let minTier: SafetyTier = settings.includeWeak ? .weak : .good
        let extra = settings.extraStealthOn
        return nodes.filter { $0.supported && $0.tier >= minTier && (!$0.isWARP || warp != nil) && (!extra || $0.extraStealthEligible) }
    }

    /// `quiet` is the Extra Stealth scan: few probes, low concurrency, and stop as soon as enough servers answer.
    func testNodes(_ list: [ProxyNode], quiet: Bool = false, stopAfterOK: Int? = nil) async {
        guard !list.isEmpty else { return }
        var s = settings
        if quiet { s.testConcurrency = AppSettings.extraScanConcurrency }
        await tester.run(nodes: list, settings: s, warp: warp, workDir: workDir, log: log, stopAfterOK: stopAfterOK) { [weak self] id, outcome in
            self?.applyTestResult(id: id, outcome: outcome)
        }
        refilter()
        scheduleNodeSave()
    }

    func testSelection() async {
        let ids = selection
        await testNodes(nodes.filter { ids.contains($0.id) })
    }

    func quickScan() async {
        let stealth = settings.stealthMode, extra = settings.extraStealthOn
        let candidates = eligibleForTesting()
            .sorted { $0.rank(stealthWeighted: stealth, extra: extra) > $1.rank(stealthWeighted: stealth, extra: extra) }
            .prefix(extra ? AppSettings.extraScanSize : settings.quickScanSize)
        await testNodes(Array(candidates), quiet: extra, stopAfterOK: extra ? AppSettings.extraStopAfterOK * 2 : nil)
    }

    func fullScan() async { await testNodes(eligibleForTesting()) }

    // MARK: Connection

    /// Connects to a node. Returns true on success. `allowShield` false forces a plain connection.
    @discardableResult
    func connect(_ node: ProxyNode, allowShield: Bool = true) async -> Bool {
        lastError = nil
        warning = nil
        let extra = settings.extraStealthOn
        if extra && !node.extraStealthEligible {
            lastError = "\(node.name) does not meet Extra Stealth rules (needs Reality, or verified TLS with WebSocket/gRPC on an HTTPS port). Turn Extra Stealth off to use it."
            return false
        }
        if (node.isWARP || settings.shieldMode) && warp == nil {
            _ = await ensureWARP()
            if warp == nil && node.isWARP { return false }
        }
        var effective = settings
        if !allowShield { effective.shieldMode = false }
        let shieldAttempt = effective.shieldMode && warp != nil && !node.isWARP
        do {
            let stealth = settings.stealthMode
            let backups: [ProxyNode] = !extra ? [] : Array(nodes
                .filter { $0.id != node.id && $0.test.isOK && $0.extraStealthEligible && (!shieldAttempt || $0.shieldCapable == true) }
                .sorted { $0.rank(stealthWeighted: stealth, shield: shieldAttempt, extra: true) > $1.rank(stealthWeighted: stealth, shield: shieldAttempt, extra: true) }
                .prefix(AppSettings.extraFailoverBackups))
            try await connection.connect(node: node, backups: backups, settings: effective, warp: warp, workDir: workDir, log: log)
            updateNode(id: node.id) { $0.okCount += 1; if shieldAttempt { $0.shieldCapable = true } }
            if settings.shieldMode && !shieldAttempt && !node.isWARP { warning = "Connected without Shield: this server does not relay UDP." }
            reconnectAttempts = 0
            return true
        } catch let e as ConnectError {
            lastError = e.message
            updateNode(id: node.id) { n in
                if e.shieldFailure { n.shieldCapable = false }
                else { n.failCount += 1; n.test = .failed(e.message); n.lastTested = Date() }
            }
            refilter()
            scheduleNodeSave()
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func disconnect() async {
        await connection.disconnect()
    }

    /// Finds working servers and connects to the best one.
    func autoConnect() async {
        guard autoPhase == nil else { return }
        lastError = nil
        defer { autoPhase = nil }

        if settings.shieldMode && warp == nil {
            autoPhase = "Registering WARP for Shield"
            _ = await ensureWARP()
        }
        // Free servers churn within days: a list older than 12 hours is mostly dead, so refresh it first.
        let newestFetch = sources.compactMap { $0.lastFetch }.max()
        let stale = newestFetch.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true
        if supportedCount < 30 || stale {
            autoPhase = "Fetching server lists"
            await refreshSources()
        }
        let stealth = settings.stealthMode
        let extra = settings.extraStealthOn
        let shield = settings.shieldMode && warp != nil
        let candidates = Array(eligibleForTesting()
            .sorted { $0.rank(stealthWeighted: stealth, shield: shield, extra: extra) > $1.rank(stealthWeighted: stealth, shield: shield, extra: extra) }
            .prefix(extra ? AppSettings.extraScanSize : settings.quickScanSize))
        if candidates.isEmpty {
            lastError = "No usable servers found. Check Sources and your network."
            return
        }
        autoPhase = extra ? "Quiet scan of up to \(candidates.count) servers" : "Testing \(candidates.count) servers"
        await testNodes(candidates, quiet: extra, stopAfterOK: extra ? (shield ? 16 : AppSettings.extraStopAfterOK) : nil)

        let ids = Set(candidates.map { $0.id })
        let working = nodes.filter { ids.contains($0.id) && $0.test.isOK }
            .sorted { $0.rank(stealthWeighted: stealth, shield: shield, extra: extra) > $1.rank(stealthWeighted: stealth, shield: shield, extra: extra) }
        if working.isEmpty {
            lastError = extra ? "No Extra Stealth server answered. Refresh sources, or turn Extra Stealth off for a wider choice." : "None of the tested servers responded. Try a Full scan or add sources."
            return
        }
        // Shield needs a server that relays UDP; only a fraction do, so try more of them.
        let attempts = shield ? 24 : 6
        let tries = Array(working.prefix(attempts))
        for (i, n) in tries.enumerated() {
            autoPhase = shield ? "Probing Shield via \(n.name) (\(i + 1)/\(tries.count))" : "Connecting to \(n.name) (\(i + 1)/\(tries.count))"
            if await connect(n) { return }
        }
        if shield && settings.shieldFallback, let n = working.first {
            autoPhase = "No Shield-capable server; connecting plain"
            if await connect(n, allowShield: false) { return }
        }
        lastError = shield && !settings.shieldFallback
            ? "No tested server relays UDP for Shield. Run a Full scan, or enable \"Fall back to plain proxy\" in Settings."
            : (lastError ?? "Could not establish a verified connection.")
    }

    private func reconnectAfterFailure() async {
        if Date().timeIntervalSince(reconnectWindowStart) > 600 { reconnectWindowStart = Date(); reconnectAttempts = 0 }
        guard reconnectAttempts < 3 else {
            log.append("[ghostlark] too many reconnect attempts; staying \(settings.killSwitch ? "held (kill switch)" : "disconnected")")
            return
        }
        reconnectAttempts += 1
        let stealth = settings.stealthMode
        let failedID = connection.activeNode?.id
        let working = nodes.filter { $0.test.isOK && $0.id != failedID && $0.supported }
            .sorted { $0.rank(stealthWeighted: stealth) > $1.rank(stealthWeighted: stealth) }
        for n in working.prefix(4) {
            if await connect(n) { return }
        }
        await autoConnect()
    }

    // MARK: WARP

    @discardableResult
    func ensureWARP() async -> WARPAccount? {
        if let w = warp { return w }
        guard !warpBusy else { return nil }
        warpBusy = true
        defer { warpBusy = false }
        let port = connection.state.isConnected ? settings.localPort : nil
        do {
            let acct = try await WARPService.register(proxyPort: port)
            warp = acct
            ensureWARPNode()
            refilter()
            scheduleNodeSave()
            log.append("[warp] registered device \(acct.id)")
            return acct
        } catch {
            lastError = "WARP registration failed: \(error.localizedDescription)"
            log.append("[warp] registration failed: \(error.localizedDescription)")
            return nil
        }
    }

    func resetWARP() {
        WARPService.reset()
        warp = nil
        ensureWARPNode()
        refilter()
        scheduleNodeSave()
    }
}
