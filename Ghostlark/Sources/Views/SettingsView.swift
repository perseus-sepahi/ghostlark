import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Stealth (for restricted networks)") {
                Toggle("Stealth mode", isOn: $state.settings.stealthMode)
                Toggle("Extra Stealth", isOn: $state.settings.extraStealth)
                    .disabled(!state.settings.stealthMode)
                Text("Extra Stealth keeps the tunnel just as fast but narrows what Ghostlark will do: it only uses Reality or verified-TLS WebSocket/gRPC servers on HTTPS ports, ranks down Reality decoys that name big self-hosted sites (an SNI/IP mismatch censors can check), scans quietly (at most \(AppSettings.extraScanSize) probes, \(AppSettings.extraScanConcurrency) at a time, stopping once enough answer), blocks QUIC so browsers use plain HTTPS, and keeps a failover pool of verified servers so a blocked one is replaced automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fragment TLS handshakes", isOn: $state.settings.tlsFragment)
                    .disabled(!state.settings.stealthMode)
                    .help("Splits the TLS ClientHello so SNI-based filters cannot read the server name in one packet. Helps reach proxy servers whose hostnames are blocked.")
                Toggle("Also fragment Reality handshakes", isOn: $state.settings.fragmentReality)
                    .disabled(!state.settings.stealthMode || !state.settings.tlsFragment)
                    .help("Off by default: Reality already looks like a normal TLS session, and fragmenting it can make it stand out.")
                Toggle("Route domestic (.ir) sites directly", isOn: $state.settings.domesticDirect)
                    .disabled(!state.settings.stealthMode)
                    .help("Domestic sites often block foreign IPs and keep working without the tunnel; sending them direct also reduces the volume of tunnelled traffic.")
                Picker("TLS fingerprint", selection: $state.settings.utlsFingerprint) {
                    ForEach(["chrome", "firefox", "safari", "edge", "ios", "android", "random"], id: \.self) { Text($0).tag($0) }
                }
                .help("The browser whose TLS ClientHello the core imitates.")
            }

            Section("Shield (Cloudflare WARP)") {
                Toggle("Shield mode: WARP over proxy", isOn: $state.settings.shieldMode)
                Toggle("Fall back to plain proxy if no server relays UDP", isOn: $state.settings.shieldFallback)
                    .disabled(!state.settings.shieldMode)
                HStack {
                    if let w = state.warp {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Registered device \(w.id.prefix(8))…").font(.callout)
                            Text("Interface \(w.v4) · created \(w.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset account", role: .destructive) { state.resetWARP() }
                    } else {
                        Text("No WARP account yet").foregroundStyle(.secondary)
                        Spacer()
                        Button(state.warpBusy ? "Registering…" : "Register free account") { Task { await state.ensureWARP() } }
                            .disabled(state.warpBusy)
                    }
                }
                Text("A WireGuard key pair is generated on this Mac and registered with Cloudflare's free WARP service. The private key is stored in your Keychain and never leaves this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Protection") {
                Toggle("Kill switch (fail closed if core dies)", isOn: $state.settings.killSwitch)
                Toggle("Auto-reconnect to next verified server", isOn: $state.settings.autoReconnect)
                Toggle("Set macOS system proxy on connect", isOn: $state.settings.setSystemProxy)
                    .help("Turn off to use Ghostlark only from apps you point at 127.0.0.1:\(state.settings.localPort) manually.")
                Text("System-proxy mode protects every app that honours macOS proxy settings (browsers, most Mac apps). Apps that ignore proxies are not tunnelled; a TUN-based mode would need root or a signed Network Extension.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ports") {
                TextField("Local proxy port", value: $state.settings.localPort, format: .number.grouping(.never))
                TextField("Control API port", value: $state.settings.apiPort, format: .number.grouping(.never))
                TextField("Tester API port", value: $state.settings.testerApiPort, format: .number.grouping(.never))
            }

            Section("Testing") {
                TextField("Test URL", text: $state.settings.testURL)
                Stepper("Timeout: \(state.settings.testTimeoutMs) ms", value: $state.settings.testTimeoutMs, in: 2000...20000, step: 1000)
                Stepper("Concurrency: \(state.settings.testConcurrency)", value: $state.settings.testConcurrency, in: 4...128, step: 4)
                Stepper("Batch size: \(state.settings.testBatchSize)", value: $state.settings.testBatchSize, in: 50...1000, step: 50)
                Stepper("Quick scan candidates: \(state.settings.quickScanSize)", value: $state.settings.quickScanSize, in: 50...3000, step: 50)
            }

            Section("Server list") {
                Toggle("Hide unsafe servers (plaintext, broken ciphers)", isOn: $state.settings.hideUnsafe)
                Toggle("Include \"Weak\" servers when auto-selecting", isOn: $state.settings.includeWeak)
                Toggle("Show menu bar icon", isOn: $state.settings.showMenuBar)
            }

            Section("About") {
                Text("Ghostlark drives the open-source sing-box core (SagerNet, GPLv3). Free public proxies are run by unknown volunteers: assume the operator can see any traffic that is not itself encrypted (HTTPS, or Shield mode). Ghostlark never sends telemetry.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Data: \(AppState.supportDir.path)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
