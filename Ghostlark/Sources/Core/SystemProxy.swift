import Foundation

/// Controls the macOS system-wide proxy through `networksetup`. Admin users can change
/// these without a password prompt.
enum SystemProxy {
    static let bypass = ["127.0.0.1", "localhost", "*.local", "169.254/16"]

    @discardableResult
    static func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Enabled network services (Wi-Fi, Ethernet, ...). Disabled ones are prefixed with '*'.
    static func enabledServices() -> [String] {
        let (_, out) = run(["-listallnetworkservices"])
        return out.components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    static func set(host: String, port: Int) {
        for svc in enabledServices() {
            run(["-setwebproxy", svc, host, String(port)])
            run(["-setsecurewebproxy", svc, host, String(port)])
            run(["-setsocksfirewallproxy", svc, host, String(port)])
            run(["-setproxybypassdomains", svc] + bypass)   // setting a proxy also switches it on
        }
    }

    static func clear() {
        for svc in enabledServices() {
            run(["-setwebproxystate", svc, "off"])
            run(["-setsecurewebproxystate", svc, "off"])
            run(["-setsocksfirewallproxystate", svc, "off"])
        }
    }

    /// True if any enabled service currently points at the given local port.
    static func isSet(port: Int) -> Bool {
        for svc in enabledServices() {
            let (_, out) = run(["-getsocksfirewallproxy", svc])
            if out.contains("Enabled: Yes") && out.contains("Port: \(port)") { return true }
        }
        return false
    }
}
