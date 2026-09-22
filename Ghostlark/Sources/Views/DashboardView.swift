import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var tester: NodeTester
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusCard
                HStack(alignment: .top, spacing: 16) {
                    modesCard
                    statsCard
                }
                if let n = connection.activeNode { nodeCard(n) }
                if let w = state.warning {
                    Label(w, systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Ghostlark")
        .onReceive(timer) { now = $0 }
    }

    // MARK: Status

    var statusCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(ringColor.opacity(0.18), lineWidth: 14).frame(width: 190, height: 190)
                Circle().trim(from: 0, to: connection.state.isConnected || connection.state == .held ? 1 : 0.0001)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 190, height: 190)
                    .animation(.easeInOut(duration: 0.6), value: connection.state)
                if busy {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: connection.state == .held ? "lock.shield.fill" : (connection.state.isConnected ? "shield.lefthalf.filled" : "shield.slash"))
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(ringColor)
                }
            }
            VStack(spacing: 4) {
                Text(headline).font(.title2.weight(.semibold))
                Text(subline).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if tester.isRunning {
                    ProgressView(value: Double(tester.done), total: Double(max(1, tester.total)))
                        .frame(width: 300)
                    Text("\(tester.done)/\(tester.total) tested · \(tester.okCount) reachable").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if connection.state.isConnected || connection.state == .held || connection.state.isBusy {
                    Button(role: .destructive) { Task { await state.disconnect() } } label: {
                        Label("Disconnect", systemImage: "xmark.circle").frame(minWidth: 140)
                    }
                    .controlSize(.large)
                    .disabled(busy && !connection.state.isBusy)
                } else {
                    Button { Task { await state.autoConnect() } } label: {
                        Label("Find best & connect", systemImage: "bolt.shield").frame(minWidth: 180)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
                if tester.isRunning {
                    Button("Stop test") { tester.cancel() }.controlSize(.large)
                } else if !connection.state.isConnected {
                    Button { Task { await state.quickScan() } } label: { Label("Quick scan", systemImage: "waveform.path.ecg") }
                        .controlSize(.large)
                        .disabled(busy)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
    }

    var busy: Bool { connection.state.isBusy || state.autoPhase != nil || state.isFetching || tester.isRunning }

    var ringColor: Color {
        switch connection.state {
        case .connected: return connection.shieldActive ? .blue : .green
        case .connecting: return .orange
        case .held: return .red
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    var headline: String {
        if let p = state.autoPhase { return p }
        switch connection.state {
        case .connected:
            let tags = [connection.extraActive ? "Extra Stealth" : nil, connection.shieldActive ? "Shield" : nil].compactMap { $0 }
            return tags.isEmpty ? "Protected" : "Protected · " + tags.joined(separator: " + ")
        case .connecting(let s): return s
        case .held: return "Kill switch engaged"
        case .failed: return "Not connected"
        case .disconnected: return state.isFetching ? state.fetchStatus : "Not connected"
        }
    }

    var subline: String {
        switch connection.state {
        case .connected:
            var parts: [String] = []
            if let ip = connection.exitIP { parts.append("Exit \(ip)") }
            if let c = connection.exitCountry { parts.append(c) }
            if connection.exitViaWARP { parts.append("via Cloudflare WARP") }
            if connection.extraActive && connection.poolSize > 1 { parts.append("failover pool of \(connection.poolSize)") }
            if let since = connection.connectedSince { parts.append(uptime(since)) }
            return parts.isEmpty ? "Verifying exit…" : parts.joined(separator: " · ")
        case .held:
            return "The core stopped. System proxy is pinned to the dead port so nothing leaks. Reconnect or Disconnect."
        case .failed(let m): return m
        case .connecting: return "Nothing is exposed until the tunnel is verified."
        case .disconnected: return state.autoPhase == nil ? "Traffic is using your normal connection." : ""
        }
    }

    func uptime(_ since: Date) -> String {
        let s = Int(now.timeIntervalSince(since))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: Modes

    var modesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Modes").font(.headline)
            modeToggle("Stealth", icon: "eye.slash", isOn: $state.settings.stealthMode,
                       help: "Prefer Reality/TLS-camouflaged servers, fragment TLS handshakes, route domestic (.ir) sites directly, encrypted DNS through the tunnel.")
            modeToggle("Extra Stealth", icon: "eye.trianglebadge.exclamationmark", isOn: $state.settings.extraStealth,
                       help: "Only Reality or verified-TLS WebSocket/gRPC servers, a quiet scan instead of hundreds of probes, QUIC blocked, and a failover pool so a blocked server is replaced without exposing you.")
                .disabled(!state.settings.stealthMode)
            modeToggle("Shield (WARP over proxy)", icon: "lock.shield", isOn: $state.settings.shieldMode,
                       help: "Runs a Cloudflare WARP WireGuard tunnel inside the free proxy. The proxy operator only sees ciphertext; Cloudflare becomes the exit.")
            modeToggle("Kill switch", icon: "hand.raised", isOn: $state.settings.killSwitch,
                       help: "If the core dies, keep the system proxy pinned so traffic fails closed instead of leaking.")
            modeToggle("Auto-reconnect", icon: "arrow.triangle.2.circlepath", isOn: $state.settings.autoReconnect,
                       help: "Switch to the next verified server automatically if the connection drops.")
            if state.settings.shieldMode {
                HStack(spacing: 6) {
                    Image(systemName: state.warp == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(state.warp == nil ? .orange : .green)
                    Text(state.warp == nil ? "WARP account will be registered on connect" : "WARP account ready")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Changes apply on the next connection.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    func modeToggle(_ title: String, icon: String, isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: icon)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(help)
    }

    // MARK: Stats

    var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Traffic").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Label("Down", systemImage: "arrow.down").foregroundStyle(.secondary)
                    Text(formatBytes(connection.downBps) + "/s").monospacedDigit()
                    Text(formatBytes(connection.totalDown)).monospacedDigit().foregroundStyle(.secondary)
                }
                GridRow {
                    Label("Up", systemImage: "arrow.up").foregroundStyle(.secondary)
                    Text(formatBytes(connection.upBps) + "/s").monospacedDigit()
                    Text(formatBytes(connection.totalUp)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { Text("Local proxy").foregroundStyle(.secondary); Text(verbatim: "127.0.0.1:\(state.settings.localPort)").monospaced() }
                GridRow { Text("System proxy").foregroundStyle(.secondary); Text(connection.proxyApplied ? "Applied" : "Not set") }
                GridRow { Text("DNS").foregroundStyle(.secondary); Text("DoH 1.1.1.1 through tunnel") }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Node

    func nodeCard(_ n: ProxyNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Current server").font(.headline)
                Spacer()
                Badge(text: n.tier.label, color: n.tier.color)
                Badge(text: "Stealth \(n.stealthScore)", color: .purple)
            }
            HStack(spacing: 10) {
                Text(n.countryFlag ?? "🏳️").font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name).font(.body.weight(.medium)).lineLimit(1)
                    Text("\(n.proto.label) · \(n.transport.label) · \(n.securityBadge) · \(n.server):\(n.port)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let ms = n.test.latency { Text("\(ms) ms").monospacedDigit().foregroundStyle(.secondary) }
            }
            if !n.notes.isEmpty {
                ForEach(n.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Source: \(n.sourceName)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}
