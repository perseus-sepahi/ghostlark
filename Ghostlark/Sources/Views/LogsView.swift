import SwiftUI

struct LogsView: View {
    @EnvironmentObject var log: LogStore
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .onChange(of: log.lines.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack {
                TextField("Filter", text: $filter).frame(width: 240)
                Spacer()
                Text("\(log.lines.count) lines").font(.caption).foregroundStyle(.secondary)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visible.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { log.clear() }
            }
            .padding(10)
        }
        .navigationTitle("Logs")
    }

    var visible: [String] {
        filter.isEmpty ? log.lines : log.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    func color(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("FATAL") || line.contains("failed") { return .red }
        if line.contains("WARN") { return .orange }
        if line.hasPrefix("[") { return .secondary }
        return .primary
    }
}
