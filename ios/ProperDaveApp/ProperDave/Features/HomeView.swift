import ProperDaveCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    // Observed directly: reading session state through AppModel does not
    // re-render this view when the session changes (nested ObservableObject).
    @EnvironmentObject private var session: SessionController
    @StateObject private var dictation = Dictation()

    private let examples = [
        "Tell me when the elevator arrives at my floor",
        "Tell me when I reach gate B62. Watch for coffee shops too",
        "Let me know when the train to Grand Central is arriving",
        "Watch the signs and tell me when I'm near the Verizon store",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("State", value: stateText)
                    LabeledContent("Source", value: session.activeSourceID ?? model.sourceKind.rawValue)
                    LabeledContent("Backend", value: model.backend.rawValue)
                    LabeledContent("Prompt input", value: model.promptInputDescription)
                    LabeledContent("Glasses", value: model.glassesReady ? "Connected" : "Not connected (optional)")
                    LabeledContent("Escalations", value: "\(session.escalationCount)")
                    if let goal = session.goal {
                        LabeledContent("Watching for", value: goal.targets.joined(separator: ", "))
                    }
                }
                Section {
                    // Always available, at any time (CAP-13/14) — not a
                    // setup step, and never required for anything else here.
                    Button {
                        model.connectGlasses()
                    } label: {
                        Label(model.glassesReady ? "Reconnect Meta glasses" : "Connect Meta glasses",
                              systemImage: "eyeglasses")
                    }
                    if let status = model.glassesStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Glasses (optional)")
                } footer: {
                    Text("No glasses? Everything on this screen works without them. Connecting during a watch switches to the glasses without ending it.")
                }
                goalSection
                Section("Examples") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(examples, id: \.self) { example in
                                Button(example) { model.promptText = example }
                                    .buttonStyle(.bordered).font(.footnote)
                            }
                        }
                    }
                }
                if let callout = session.lastCallout {
                    Section("Last callout") { Text(callout).font(.headline) }
                }
                if !session.decisionTrail.isEmpty {
                    Section("Recent decisions") {
                        ForEach(Array(session.decisionTrail.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Proper Dave")
            .onChange(of: dictation.transcript) { _, text in
                if dictation.isListening { model.promptText = text }
            }
        }
    }

    private var stateText: String {
        switch session.state {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .watching: return "Watching"
        case .pausedForDebug: return "Paused (debug log)"
        case .ended: return "Stopped"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private var isWatching: Bool {
        switch session.state {
        case .watching, .pausedForDebug, .starting: return true
        default: return false
        }
    }

    private var goalSection: some View {
        Section {
            TextField("Type what to watch for…", text: $model.promptText, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityLabel("Goal prompt")
                .accessibilityHint("Type what Proper Dave should watch for, then start watching.")
            if let error = dictation.errorText {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    dictation.toggle()
                    if !dictation.isListening && !dictation.transcript.isEmpty {
                        model.promptText = dictation.transcript
                    }
                } label: {
                    Label(dictation.isListening ? "Stop dictation" : "Dictate",
                          systemImage: dictation.isListening ? "stop.circle" : "mic")
                }
                Spacer()
                if isWatching {
                    Button("Stop", role: .destructive) { model.stopWatching() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Start watching") { model.startWatching() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } header: {
            Text("Goal")
        } footer: {
            Text("Type or dictate. Typing suits noisy places, privacy, or staying on a call — no spoken prompt is ever required.")
        }
    }
}
