import Foundation

/// Runs the bundled sing-box binary as a child process and streams its log output.
final class CoreProcess {
    static var binaryURL: URL? {
        if let u = Bundle.main.url(forResource: "sing-box", withExtension: nil) { return u }
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
        return FileManager.default.isExecutableFile(atPath: brew.path) ? brew : nil
    }

    private var process: Process?
    private let lock = NSLock()
    private var buffer = Data()
    var onLog: ((String) -> Void)?
    /// Called on a background thread when the process exits. `expected` is true if stop() was called.
    var onExit: ((Int32, Bool) -> Void)?
    private var stopping = false

    var isRunning: Bool { process?.isRunning ?? false }
    var pid: Int32? { process?.processIdentifier }

    struct StartError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Kills any sing-box left over from a previous crashed run that still uses one of our config files.
    static func killStale(workDir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "sing-box run -c \(workDir.path)/"]
        try? p.run()
        p.waitUntilExit()
    }

    func start(configURL: URL, workDir: URL) throws {
        guard let bin = CoreProcess.binaryURL else { throw StartError(message: "sing-box binary not found in app bundle") }
        lock.lock(); defer { lock.unlock() }
        if let p = process, p.isRunning { throw StartError(message: "core already running") }
        stopping = false
        CoreProcess.killStale(workDir: configURL.deletingLastPathComponent())

        let p = Process()
        p.executableURL = bin
        p.arguments = ["run", "-c", configURL.path, "-D", workDir.path]
        p.currentDirectoryURL = workDir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self = self else { return }
            self.consume(data)
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self = self else { return }
            let expected: Bool
            self.lock.lock(); expected = self.stopping; self.lock.unlock()
            self.onExit?(proc.terminationStatus, expected)
        }
        try p.run()
        process = p
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let raw = String(data: lineData, encoding: .utf8) {
                let line = CoreProcess.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { onLog?(line) }
            }
        }
    }

    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
    static func stripANSI(_ s: String) -> String {
        ansiRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// Sends SIGTERM, waits briefly, then SIGKILLs. Safe to call when not running.
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.stopSync()
                cont.resume()
            }
        }
    }

    func stopSync() {
        lock.lock()
        stopping = true
        let p = process
        lock.unlock()
        guard let p = p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
    }
}
