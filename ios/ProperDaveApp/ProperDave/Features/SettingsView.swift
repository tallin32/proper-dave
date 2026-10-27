import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Backend", selection: $model.backend) {
                        ForEach(Backend.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame source", selection: $model.sourceKind) {
                        ForEach(FrameSourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper(value: $model.sampleInterval, in: 0.5...10, step: 0.5) {
                        LabeledContent("Sample every") { Text(String(format: "%.1f s", model.sampleInterval)) }
                    }
                } header: {
                    Text("Watching")
                } footer: {
                    Text("Glasses are optional at all times; the phone camera always works. Changing Frame source during a watch switches it immediately, in either direction. Meta glasses use the Wearables Device Access Toolkit with Developer Mode on in the Meta AI app.")
                }

                Section {
                    Button {
                        model.connectGlasses()
                    } label: {
                        Label(model.glassesReady ? "Reconnect Meta glasses" : "Connect Meta glasses",
                              systemImage: "eyeglasses")
                    }
                    LabeledContent("Status", value: model.glassesReady ? "Connected" : "Not connected")
                    if let status = model.glassesStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Meta glasses (optional)")
                } footer: {
                    Text("Available any time, including during a watch — connecting switches the live session over. Registration opens the Meta AI app and returns via properdave://.")
                }

                if model.backend == .server {
                    Section {
                        TextField("Host (IP or DNS name)", text: $model.serverHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Stepper(value: $model.serverPort, in: 1...65535) {
                            LabeledContent("Port", value: "\(model.serverPort)")
                        }
                        SecureField("API key (optional)", text: $model.apiKey)
                        Button {
                            model.testConnection()
                        } label: {
                            if model.isTestingConnection { ProgressView() } else { Text("Test connection") }
                        }
                        if let status = model.connectionStatus {
                            Text(status).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Server")
                    } footer: {
                        Text("Run it with: uv run proper-dave-server (port 3283). Plain HTTP on a home network is a courtesy lock, not security.")
                    }
                }

                Section {
                    Toggle("Working heartbeat sound", isOn: $model.heartbeatEnabled)
                    if model.heartbeatEnabled {
                        VStack(alignment: .leading) {
                            Text("Ping every \(model.heartbeatInterval, specifier: "%.0f") s")
                            Slider(value: $model.heartbeatInterval, in: 2...15, step: 1)
                        }
                        VStack(alignment: .leading) {
                            Text("Volume")
                            Slider(value: $model.heartbeatVolume, in: 0.05...1, step: 0.05)
                        }
                        VStack(alignment: .leading) {
                            Text("Pitch")
                            Slider(value: $model.heartbeatPitch, in: 330...990, step: 10)
                        }
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("A soft synthesized ping while Dave is watching but has nothing to say — proof of life, generated in code, no audio file, works offline. Off by default; it never sounds over a callout screen or while idle. Some will love it, some will want to strangle it: hence the toggle.")
                }

                #if DEBUG
                Section {
                    Toggle("Use glasses microphone (experimental)", isOn: $model.glassesMicEnabled)
                    LabeledContent("Effective", value: model.effectiveGlassesMicEnabled ? "On (this build allows it)" : "Off")
                } header: {
                    Text("Experimental")
                } footer: {
                    Text("Glasses mic input is experimental in Meta's SDK and cannot ship in published apps. Hackathon builds only; production ignores the stored preference. Until DAT audio is linked, dictation falls back to the phone microphone.")
                }
                Section {
                    Picker("Critical error modal", selection: $model.criticalPresentation) {
                        ForEach(CriticalPresentation.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Codename", text: $model.codename)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Trigger test critical error", role: .destructive) { model.triggerTestCriticalError() }
                    NavigationLink("Debug log") { LogView() }
                } header: {
                    Text("Debug (test builds only)")
                } footer: {
                    Text("Shake the device to view the log. Sessions kept: last 10 (MVP). None of this section ships in production.")
                }
                #endif
            }
            .navigationTitle("Settings")
        }
    }
}
