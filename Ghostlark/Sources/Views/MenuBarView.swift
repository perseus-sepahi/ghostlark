import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        switch connection.state {
        case .connected:
            Text("Connected" + (connection.shieldActive ? " · Shield" : ""))
            if let n = connection.activeNode { Text(n.name).font(.caption) }
            if let ip = connection.exitIP { Text("Exit \(ip) \(connection.exitCountry ?? "")") }
            Divider()
            Button("Disconnect") { Task { await state.disconnect() } }
        case .connecting(let s):
            Text(s)
            Button("Cancel") { Task { await state.disconnect() } }
        case .held:
            Text("Kill switch engaged")
            Button("Reconnect") { Task { await state.autoConnect() } }
            Button("Disconnect (release)") { Task { await state.disconnect() } }
        case .failed, .disconnected:
            Text("Disconnected")
            Button("Find best & connect") { Task { await state.autoConnect() } }
                .disabled(state.autoPhase != nil)
        }
        Divider()
        Toggle("Stealth", isOn: $state.settings.stealthMode)
        Toggle("Extra Stealth", isOn: $state.settings.extraStealth).disabled(!state.settings.stealthMode)
        Toggle("Shield (WARP over proxy)", isOn: $state.settings.shieldMode)
        Divider()
        Button("Open Ghostlark") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
