import Foundation

/// Thread-safe, coalescing log buffer for core output.
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    private let cap = 4000
    var mirrorFile: URL?

    func append(_ s: String) {
        lock.lock()
        pending.append(s)
        let needsFlush = !scheduled
        scheduled = true
        lock.unlock()
        if needsFlush {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let p = pending
        pending = []
        scheduled = false
        lock.unlock()
        guard !p.isEmpty else { return }
        if let f = mirrorFile, let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write((p.joined(separator: "\n") + "\n").data(using: .utf8)!); try? h.close()
        } else if let f = mirrorFile {
            try? (p.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
        }
        lines.append(contentsOf: p)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }

    func clear() { lines = [] }
}
