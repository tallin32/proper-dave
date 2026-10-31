import SwiftUI

/// Conversation mode, proof-of-concept slice (TRD-006): explicit
/// start/end, push-to-talk or typed turns, spoken replies. No
/// continuous listening, no wake word, no barge-in — those are the
/// specced hardening steps, not this screen.
struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = Dictation()
    @State private var turns: [(user: Bool, text: String)] = []
    @State private var input = ""
    @State private var repliesMuted = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if turns.isEmpty {
                        Text("Talk or type. Try “watch for the elevator”, “what's in front of me?”, or “tell me what I see as I pass”. While watching, follow-ups refine the goal.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        HStack {
                            if turn.user { Spacer() }
                            Text(turn.text)
                                .padding(8)
                                .background(turn.user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            if !turn.user { Spacer() }
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)

                Divider()
                HStack {
                    Button {
                        dictation.toggle()
                        if !dictation.isListening && !dictation.transcript.isEmpty {
                            input = dictation.transcript
                        }
                    } label: {
                        Label(dictation.isListening ? "Stop" : "Talk",
                              systemImage: dictation.isListening ? "stop.circle" : "mic")
                    }
                    TextField("Type a turn…", text: $input)
                        .focused($inputFocused)
                        .accessibilityLabel("Conversation turn")
                    Button("Send") { send() }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
            }
            .navigationTitle("Conversation")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("View log") { model.showLogSheet = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Mute replies", isOn: $repliesMuted)
                        Button("End conversation", role: .destructive) {
                            if dictation.isListening { dictation.toggle() }
                            dismiss()
                        }
                    } label: {
                        Label("Conversation options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                if turns.isEmpty {
                    speak("Conversation started. Talk, type, or ask me to watch for something.")
                }
            }
        }
    }

    private func speak(_ text: String) {
        turns.append((user: false, text: text))
        if !repliesMuted { model.speaker.speak(text) }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        turns.append((user: true, text: text))
        let history = turns.suffix(6).map { ($0.user ? "User: " : "Dave: ") + $0.text }
        Task {
            let reply = await model.conversationTurn(text, history: history)
            speak(reply)
        }
    }
}
