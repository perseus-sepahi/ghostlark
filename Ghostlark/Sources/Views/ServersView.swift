import SwiftUI

struct ServersView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var tester: NodeTester
    @State private var showImport = false
    @State private var importText = ""

    var body: some View {
        VStack(spacing: 0) {
            Table(state.displayed, selection: $state.selection, sortOrder: $state.sortOrder) {
                TableColumn("Server") { n in
                    HStack(spacing: 6) {
                        Text(n.countryFlag ?? "·").frame(width: 22)
                        Text(n.name).lineLimit(1)
                        if connection.activeNode?.id == n.id && connection.state.isConnected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn("Protocol") { n in
                    HStack(spacing: 4) {
                        Text(n.proto.label)
                        Text(n.transport == .tcp ? "" : n.transport.label).foregroundStyle(.secondary)
                    }.font(.callout)
                }
                .width(min: 90, ideal: 130)
                TableColumn("Security", value: \.safetyScore) { n in
                    HStack(spacing: 4) {
                        Badge(text: n.tier.label, color: n.tier.color)
                        Text(n.securityBadge).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 170)
                TableColumn("Stealth", value: \.stealthScore) { n in
                    HStack(spacing: 6) {
                        ProgressView(value: Double(state.settings.extraStealthOn ? n.extraStealthScore : n.stealthScore), total: 100).frame(width: 50)
                        Text("\(state.settings.extraStealthOn ? n.extraStealthScore : n.stealthScore)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        if n.extraStealthEligible { Image(systemName: "eye.slash.fill").font(.caption2).foregroundStyle(.purple).help("Meets Extra Stealth rules") }
                    }
                }
                .width(min: 80, ideal: 100)
                TableColumn("Latency") { n in
                    switch n.test {
                    case .ok(let ms):
                        Text("\(ms) ms").monospacedDigit().foregroundStyle(ms < 400 ? .green : (ms < 1200 ? .orange : .red))
                    case .failed(let why):
                        Text("✕").foregroundStyle(.red).help(why)
                    case .untested:
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 70, ideal: 80)
                TableColumn("Reliability") { n in
                    let total = n.okCount + n.failCount
                    Text(total == 0 ? "—" : "\(Int(n.reliability * 100))% (\(total))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 90)
                TableColumn("Source", value: \.sourceName) { n in
                    Text(n.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 90, ideal: 130)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let n = state.nodes.first(where: { $0.id == ids.first! }) {
                    Button("Connect") { Task { await state.connect(n) } }
                    Button("Copy share link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(n.rawLink, forType: .string)
                    }
                    Divider()
                }
                Button("Test \(ids.count) selected") { state.selection = ids; Task { await state.testSelection() } }
                Button("Delete \(ids.count)", role: .destructive) { state.deleteNodes(ids: ids) }
            } primaryAction: { ids in
                if let id = ids.first, let n = state.nodes.first(where: { $0.id == id }) {
                    Task { await state.connect(n) }
                }
            }

            Divider()
            HStack(spacing: 12) {
                if tester.isRunning {
                    ProgressView(value: Double(tester.done), total: Double(max(1, tester.total))).frame(width: 160)
                    Text("\(tester.done)/\(tester.total) · \(tester.okCount) OK").font(.caption).monospacedDigit()
                    Button("Stop") { tester.cancel() }.controlSize(.small)
                } else if state.isFetching {
                    ProgressView().controlSize(.small)
                    Text(state.fetchStatus).font(.caption)
                } else {
                    Text("\(state.displayed.count) shown · \(state.supportedCount) usable · \(state.testedOKCount) verified")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let err = state.lastError, !connection.state.isConnected {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .navigationTitle("Servers")
        .searchable(text: $state.filterText, placement: .toolbar, prompt: "Name, host, country code, source")
        .toolbar {
            ToolbarItemGroup {
                Picker("Protocol", selection: $state.filterProtocol) {
                    Text("All protocols").tag(ProxyProtocol?.none)
                    ForEach(ProxyProtocol.allCases, id: \.self) { p in Text(p.label).tag(ProxyProtocol?.some(p)) }
                }
                .frame(width: 150)
                Toggle(isOn: $state.onlyTestedOK) { Label("Verified only", systemImage: "checkmark.seal") }
                    .toggleStyle(.button)
                Button { Task { await state.refreshSources() } } label: { Label("Refresh sources", systemImage: "arrow.clockwise") }
                    .disabled(state.isFetching)
                Menu {
                    Button("Quick scan (top \(state.settings.quickScanSize))") { Task { await state.quickScan() } }
                    Button("Full scan (\(state.eligibleForTesting().count))") { Task { await state.fullScan() } }
                    Button("Test selected (\(state.selection.count))") { Task { await state.testSelection() } }
                        .disabled(state.selection.isEmpty)
                } label: { Label("Test", systemImage: "waveform.path.ecg") }
                .disabled(tester.isRunning)
                Button { showImport = true } label: { Label("Import links", systemImage: "square.and.arrow.down") }
            }
        }
        .sheet(isPresented: $showImport) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import share links").font(.headline)
                Text("Paste vless://, vmess://, trojan://, ss://, hysteria2:// or tuic:// links, one per line, or a base64 subscription payload.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $importText).font(.system(.caption, design: .monospaced)).frame(minHeight: 200)
                HStack {
                    Spacer()
                    Button("Cancel") { showImport = false }
                    Button("Import") {
                        let n = state.importText(importText)
                        state.log.append("[import] \(n) new servers")
                        importText = ""
                        showImport = false
                    }.buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 560, height: 360)
        }
    }
}
