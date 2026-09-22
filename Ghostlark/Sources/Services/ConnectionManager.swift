import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    case connected
    case failed(String)
    /// Core died; the kill switch is holding the system proxy on the dead port so traffic fails closed.
    case held

    var isConnected: Bool { self == .connected }
    var isBusy: Bool { if case .connecting = self { return true }; return false }
}

struct ConnectError: LocalizedError {
    let message: String
    var shieldFailure = false
    var errorDescription: String? { message }
}

@MainActor
final class ConnectionManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var activeNode: ProxyNode?
    @Published var upBps = 0
    @Published var downBps = 0
    @Published var totalUp = 0
    @Published var totalDown = 0
    @Published var connectedSince: Date?
    @Published var exitIP: String?
    @Published var exitCountry: String?
    @Published var exitViaWARP = false
    @Published var proxyApplied = false
    @Published var shieldActive = false
    @Published var extraActive = false
    @Published var poolSize = 1

    let core = CoreProcess()
    var onUnexpectedExit: (() -> Void)?

    private var trafficTask: Task<Void, Never>?
    private var poolTask: Task<Void, Never>?
    private var userStopping = false
    private var currentSettings = AppSettings()
    private var generation = 0

    func connect(node: ProxyNode, backups: [ProxyNode] = [], settings: AppSettings, warp: WARPAccount?, workDir: URL, log: LogStore) async throws {
        generation += 1
        let gen = generation
        currentSettings = settings
        userStopping = true
        trafficTask?.cancel()
        await core.stop()
        userStopping = false

        if node.isWARP && warp == nil { throw ConnectError(message: "WARP account not registered") }
        let shield = settings.shieldMode && warp != nil && !node.isWARP
        let exitTag = (shield || node.isWARP) ? "warp" : "proxy"
        state = .connecting("Starting core")
        activeNode = node
        shieldActive = shield
        extraActive = settings.extraStealthOn && !node.isWARP
        poolSize = extraActive ? 1 + backups.count : 1

        let secret = UUID().uuidString
        let api = ClashAPI(port: settings.apiPort, secret: secret)
        let configURL = workDir.appendingPathComponent("main.json")
        core.onLog = { line in log.append(line) }
        core.onExit = { [weak self] status, expected in
            guard let self = self, !expected else { return }
            Task { @MainActor in self.handleUnexpectedExit(status: status, gen: gen) }
        }
        do {
            try SingBoxConfig.write(SingBoxConfig.mainConfig(node: node, backups: backups, settings: settings, warp: warp, apiSecret: secret), to: configURL)
            try core.start(configURL: configURL, workDir: workDir)
        } catch {
            state = .failed(error.localizedDescription)
            activeNode = nil
            throw ConnectError(message: error.localizedDescription)
        }

        guard await api.waitReady(timeout: 10) else {
            await abort("Core failed to start (see Logs)")
            throw ConnectError(message: "Core failed to start (see Logs)")
        }

        state = .connecting(shield ? "Verifying Shield tunnel" : "Verifying tunnel")
        do {
            _ = try await api.delay(tag: exitTag, url: settings.testURL, timeoutMs: shield ? 9000 : 12000)
        } catch {
            let hint = shield ? " (Shield needs a server that relays UDP; try another server or disable Shield)" : ""
            let msg = "Server unreachable: \(error.localizedDescription)\(hint)"
            await abort(msg)
            throw ConnectError(message: msg, shieldFailure: shield)
        }

        if settings.setSystemProxy {
            let port = settings.localPort
            // Mark intent first: applying the proxy to every network service takes seconds, and a quit or
            // disconnect inside that window must still clean up.
            proxyApplied = true
            await Task.detached(priority: .userInitiated) { SystemProxy.set(host: "127.0.0.1", port: port) }.value
        }
        state = .connected
        connectedSince = Date()
        totalUp = 0; totalDown = 0; upBps = 0; downBps = 0
        exitIP = nil; exitCountry = nil; exitViaWARP = false
        startTraffic(api: api)
        if extraActive && !backups.isEmpty { startPoolWatch(api: api, members: [node] + backups) }
        Task { await self.fetchExitInfo(port: settings.localPort) }
    }

    private func abort(_ message: String) async {
        userStopping = true
        await core.stop()
        userStopping = false
        state = .failed(message)
        activeNode = nil
    }

    func disconnect() async {
        userStopping = true
        trafficTask?.cancel()
        trafficTask = nil
        await core.stop()
        if proxyApplied {
            await Task.detached(priority: .userInitiated) { SystemProxy.clear() }.value
            proxyApplied = false
        }
        poolTask?.cancel()
        state = .disconnected
        activeNode = nil
        connectedSince = nil
        shieldActive = false
        extraActive = false
        upBps = 0; downBps = 0
        userStopping = false
    }

    /// Synchronous teardown for app termination.
    func shutdownSync() {
        userStopping = true
        trafficTask?.cancel()
        core.stopSync()
        if proxyApplied || SystemProxy.isSet(port: currentSettings.localPort) { SystemProxy.clear() }
        proxyApplied = false
    }

    private func handleUnexpectedExit(status: Int32, gen: Int) {
        guard gen == generation, !userStopping else { return }
        trafficTask?.cancel()
        connectedSince = nil
        if currentSettings.killSwitch && proxyApplied {
            // Fail closed: keep pointing the system at the dead port until the user disconnects or we reconnect.
            state = .held
        } else {
            if proxyApplied {
                Task.detached { SystemProxy.clear() }
                proxyApplied = false
            }
            state = .failed("Core exited unexpectedly (status \(status))")
        }
        onUnexpectedExit?()
    }

    /// In Extra Stealth the core may fail over inside the pool; keep the UI honest about which server is live.
    private func startPoolWatch(api: ClashAPI, members: [ProxyNode]) {
        poolTask?.cancel()
        let byTag = Dictionary(uniqueKeysWithValues: members.map { ($0.tag, $0) })
        poolTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self = self, self.state == .connected else { return }
                if let now = await api.groupNow(tag: "proxy"), let n = byTag[now], n.id != self.activeNode?.id {
                    self.activeNode = n
                }
            }
        }
    }

    private func startTraffic(api: ClashAPI) {
        trafficTask?.cancel()
        trafficTask = Task { [weak self] in
            do {
                for try await (up, down) in api.trafficStream() {
                    guard let self = self, !Task.isCancelled else { return }
                    self.upBps = up
                    self.downBps = down
                    self.totalUp += up
                    self.totalDown += down
                }
            } catch { }
        }
    }

    private func fetchExitInfo(port: Int) async {
        let session = ProxiedSession.make(port: port, timeout: 15)
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace"),
              let (data, _) = try? await session.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return }
        var ip: String?; var loc: String?; var warp = false
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "ip": ip = String(kv[1])
            case "loc": loc = String(kv[1])
            case "warp": warp = kv[1] == "on" || kv[1] == "plus"
            default: break
            }
        }
        guard state == .connected else { return }
        exitIP = ip
        exitCountry = loc
        exitViaWARP = warp
    }
}
