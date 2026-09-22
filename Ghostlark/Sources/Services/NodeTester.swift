import Foundation

/// Tests many nodes by loading them all into one throwaway sing-box instance and asking
/// its Clash API to run a delay test through each outbound.
@MainActor
final class NodeTester: ObservableObject {
    @Published var isRunning = false
    @Published var done = 0
    @Published var total = 0
    @Published var okCount = 0
    @Published var phase = ""

    private var cancelled = false
    private let core = CoreProcess()

    func cancel() { cancelled = true }

    func run(nodes: [ProxyNode], settings: AppSettings, warp: WARPAccount?, workDir: URL, log: LogStore,
             stopAfterOK: Int? = nil, onResult: @escaping (String, TestOutcome) -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        done = 0; okCount = 0; total = nodes.count
        defer { isRunning = false; phase = "" }

        let secret = UUID().uuidString
        let api = ClashAPI(port: settings.testerApiPort, secret: secret)
        core.onLog = { line in log.append("[tester] " + line) }
        let configURL = workDir.appendingPathComponent("tester.json")
        let batchSize = max(20, settings.testBatchSize)
        let concurrency = max(4, min(128, settings.testConcurrency))

        var start = 0
        while start < nodes.count && !cancelled {
            let batch = Array(nodes[start..<min(nodes.count, start + batchSize)])
            start += batch.count
            phase = "Testing \(done + 1)-\(done + batch.count) of \(nodes.count)"

            do {
                try SingBoxConfig.write(SingBoxConfig.testerConfig(nodes: batch, settings: settings, warp: warp, apiSecret: secret), to: configURL)
                try core.start(configURL: configURL, workDir: workDir)
            } catch {
                log.append("[tester] failed to start core: \(error.localizedDescription)")
                for n in batch { onResult(n.id, .failed("tester failed")); done += 1 }
                continue
            }
            guard await api.waitReady(timeout: 12) else {
                log.append("[tester] core did not become ready")
                await core.stop()
                for n in batch { onResult(n.id, .failed("tester not ready")); done += 1 }
                continue
            }

            let url = settings.testURL
            let timeout = settings.testTimeoutMs
            await withTaskGroup(of: (String, TestOutcome).self) { group in
                var next = 0
                while next < batch.count && next < concurrency {
                    let n = batch[next]; next += 1
                    group.addTask { await NodeTester.testOne(n, api: api, url: url, timeoutMs: timeout) }
                }
                while let (id, outcome) = await group.next() {
                    done += 1
                    if outcome.isOK { okCount += 1 }
                    onResult(id, outcome)
                    if let limit = stopAfterOK, okCount >= limit { cancelled = true }
                    if cancelled { group.cancelAll(); break }
                    if next < batch.count {
                        let n = batch[next]; next += 1
                        group.addTask { await NodeTester.testOne(n, api: api, url: url, timeoutMs: timeout) }
                    }
                }
            }
            await core.stop()
        }
    }

    nonisolated static func testOne(_ node: ProxyNode, api: ClashAPI, url: String, timeoutMs: Int) async -> (String, TestOutcome) {
        do {
            let ms = try await api.delay(tag: node.tag, url: url, timeoutMs: timeoutMs)
            return (node.id, .ok(ms))
        } catch {
            return (node.id, .failed(error.localizedDescription))
        }
    }
}
