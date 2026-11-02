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
            List {
                if !model.recordedSessions.isEmpty {
                    Section("Recorded sessions") {
                        ForEach(model.recordedSessions, id: \.id) { meta in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meta.goalText).font(.footnote.weight(.semibold))
                                Text("\(meta.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(meta.digestCount) digests · \(meta.frameCount) frames · \(ByteCountFormatter.string(fromByteCount: Int64(RecordedSessionStore.byteSize(base: AppModel.recordingsBase, id: meta.id)), countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 16) {
                                    Button("Replay") { model.replayRecordedSession(meta) }
                                    Button(model.sendingSessionID == meta.id ? "Sending…" : "Send to dev server") {
                                        model.sendRecordedSession(meta)
                                    }
                                    .disabled(model.sendingSessionID != nil)
                                    Button("Delete", role: .destructive) { model.deleteRecordedSession(meta) }
                                }
                                .font(.footnote)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section {
                    ForEach(shown) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.component) · \(event.event)").font(.footnote.weight(.semibold).monospaced())
                            if !event.detail.isEmpty {
                                Text(event.detail).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(event.ts.formatted(date: .omitted, time: .standard))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onAppear { model.refreshRecordedSessions() }
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
