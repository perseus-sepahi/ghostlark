import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var state: AppState
    @State private var newURL = ""
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach($state.sources) { $src in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: $src.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(src.name).font(.body.weight(.medium))
                                    if src.isBuiltIn { Badge(text: "built-in") }
                                }
                                Text(src.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 8) {
                                    if let c = src.lastCount { Text("\(c) links").font(.caption2).foregroundStyle(.green) }
                                    if let e = src.lastError { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(1) }
                                    if let d = src.lastFetch { Text(d, style: .relative).font(.caption2).foregroundStyle(.tertiary) + Text(" ago").font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                            Spacer()
                            if !src.isBuiltIn {
                                Button(role: .destructive) { state.removeSource(src.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Public aggregators are fetched over HTTPS from GitHub, with jsDelivr and Statically CDN mirrors raced in parallel for censored networks. When connected, fetching goes through the tunnel.")
                        .font(.caption).foregroundStyle(.secondary).textCase(nil)
                }
            }
            Divider()
            HStack {
                TextField("Name (optional)", text: $newName).frame(width: 160)
                TextField("Subscription URL (https://…)", text: $newURL)
                Button("Add") {
                    state.addSource(name: newName, url: newURL)
                    newName = ""; newURL = ""
                }
                .disabled(URL(string: newURL.trimmingCharacters(in: .whitespaces))?.scheme == nil)
                Button { Task { await state.refreshSources() } } label: { Label("Fetch all", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isFetching)
            }
            .padding(12)
        }
        .navigationTitle("Sources")
    }
}
