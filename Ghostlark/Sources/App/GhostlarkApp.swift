import SwiftUI
import AppKit

@main
struct GhostlarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Ghostlark") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.connection)
                .environmentObject(state.tester)
                .environmentObject(state.log)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    delegate.state = state
                    if CommandLine.arguments.contains("--autoconnect") { Task { await state.autoConnect() } }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra(isInserted: Binding(get: { state.settings.showMenuBar },
                                         set: { v in if state.settings.showMenuBar != v { state.settings.showMenuBar = v } })) {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(state.connection)
        } label: {
            Image(systemName: state.connection.state.isConnected ? "shield.lefthalf.filled" : "shield")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always leave the system proxy clean and the core stopped.
        if let s = state {
            s.connection.shutdownSync()
        } else {
            SystemProxy.clear()
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
