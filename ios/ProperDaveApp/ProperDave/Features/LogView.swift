import ProperDaveCore
import SwiftUI

/// Debug log viewer (TRD-005 INS-05): plain filtered list.
struct LogView: View {
    @EnvironmentObject private var model: AppModel
    // Observed directly, not through AppModel (nested ObservableObject
    // changes would otherwise never re-render this list).
    @EnvironmentObject private var log: EventLog
    @State private var filter = "All"
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    private var components: [String] {
        ["All"] + Array(Set(log.events.map(\.component))).sorted()
    }
    private var shown: [LogEvent] {
        (filter == "All" ? log.events : log.events.filter { $0.component == filter }).reversed()
    }

    var body: some View {
        VStack {
            Picker("Component", selection: $filter) {
                ForEach(components, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal)
            List(shown) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.component) · \(event.event)").font(.footnote.weight(.semibold).monospaced())
                    if !event.detail.isEmpty {
                        Text(event.detail).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(event.ts.formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Debug log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "Copied" : "Copy JSONL") {
                    // Copies fresh JSONL on EVERY tap; the label is
                    // transient confirmation, then reverts so the next
                    // copy is visibly an action again.
                    UIPasteboard.general.string = log.jsonl()
                    copied = true
                    copyResetTask?.cancel()
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        if !Task.isCancelled { copied = false }
                    }
                }
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
    }
}
