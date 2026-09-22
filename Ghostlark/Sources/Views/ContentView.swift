import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case servers = "Servers"
    case sources = "Sources"
    case logs = "Logs"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "shield.lefthalf.filled"
        case .servers: return "server.rack"
        case .sources: return "antenna.radiowaves.left.and.right"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ConnectionManager
    @State private var section: SidebarSection = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).font(.caption).lineLimit(1)
                    }
                    Text("\(state.supportedCount) servers · \(state.testedOKCount) verified")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        } detail: {
            switch section {
            case .dashboard: DashboardView()
            case .servers: ServersView()
            case .sources: SourcesView()
            case .logs: LogsView()
            case .settings: SettingsView()
            }
        }
    }

    var statusColor: Color {
        switch connection.state {
        case .connected: return .green
        case .connecting: return .orange
        case .held: return .red
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    var statusText: String {
        switch connection.state {
        case .connected: return connection.shieldActive ? "Connected · Shield" : "Connected"
        case .connecting(let s): return s
        case .held: return "Kill switch engaged"
        case .failed: return "Connection failed"
        case .disconnected: return "Disconnected"
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension SafetyTier {
    var color: Color {
        switch self {
        case .strong: return .green
        case .good: return .teal
        case .weak: return .orange
        case .unsafe: return .red
        }
    }
}

func formatBytes(_ b: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(b)
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(b) B" : String(format: "%.1f %@", v, units[i])
}
