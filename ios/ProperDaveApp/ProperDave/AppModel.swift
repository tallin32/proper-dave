import Combine
import Foundation
import MWDATCore
import ProperDaveCore

enum Backend: String, CaseIterable, Identifiable {
    case demo = "On-device demo (no server)"
    case server = "Server"
    var id: String { rawValue }
}

enum FrameSourceKind: String, CaseIterable, Identifiable {
    case mock = "Mock walk (scripted gates)"
    case camera = "Phone camera"
    case glasses = "Meta glasses (DAT)"
    var id: String { rawValue }
}

enum CriticalPresentation: String, CaseIterable, Identifiable {
    case terminalOnly = "Terminal errors only"
    case always = "Always"
    case never = "Never (log only)"
    var id: String { rawValue }
}

struct CriticalError: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var description: String
    var isTerminal: Bool = true
}

@MainActor
final class AppModel: ObservableObject {
    let log = EventLog()
    let session: SessionController
    let speaker = Speaker()
    let heartbeat = HeartbeatPlayer()
    private var stateSink: AnyCancellable?

    @Published var promptText: String { didSet { save(promptText, "promptText") } }
    @Published var backend: Backend { didSet { save(backend.rawValue, "backend") } }
    @Published var sourceKind: FrameSourceKind {
        didSet {
            save(sourceKind.rawValue, "sourceKind")
            // Live toggle: changing the picker mid-watch hot-swaps the
            // frame source in both directions (CAP-14).
            guard session.state == .watching || session.state == .pausedForDebug,
                  session.activeSourceID != nil,
                  session.activeSourceID != expectedSourceID(for: sourceKind) else { return }
            log.append(component: "capture", event: "source_picker_changed", detail: sourceKind.rawValue)
            session.switchSource(to: makeSource(for: sourceKind))
        }
    }
    @Published var serverHost: String { didSet { save(serverHost, "serverHost") } }
    @Published var serverPort: Int { didSet { save(serverPort, "serverPort") } }
    @Published var apiKey: String { didSet { save(apiKey, "apiKey") } }
    @Published var sampleInterval: Double { didSet { save(sampleInterval, "sampleInterval") } }
    @Published var glassesMicEnabled: Bool {
        didSet {
            save(glassesMicEnabled, "glassesMicEnabled")
            log.append(component: "session", event: "experimental_feature_changed",
                       detail: "glassesMicrophone user=\(glassesMicEnabled) effective=\(effectiveGlassesMicEnabled)")
        }
    }
    @Published var criticalPresentation: CriticalPresentation { didSet { save(criticalPresentation.rawValue, "criticalPresentation") } }
    @Published var codename: String {
        didSet {
            save(codename, "codename")
            if isEasterEggActive != eggWasActive {
                log.append(component: "session", event: isEasterEggActive ? "easter_egg_activated" : "easter_egg_deactivated")
            }
            eggWasActive = isEasterEggActive
        }
    }

    // Working heartbeat (synthesized, no asset). Advanced settings.
    @Published var heartbeatEnabled: Bool {
        didSet { save(heartbeatEnabled, "heartbeatEnabled"); applyHeartbeat() }
    }
    @Published var heartbeatInterval: Double {
        didSet {
            save(heartbeatInterval, "heartbeatInterval")
            heartbeat.interval = heartbeatInterval
            heartbeat.restartTiming()
        }
    }
    @Published var heartbeatVolume: Double {
        didSet { save(heartbeatVolume, "heartbeatVolume"); heartbeat.volume = Float(heartbeatVolume) }
    }
    @Published var heartbeatPitch: Double {
        didSet { save(heartbeatPitch, "heartbeatPitch"); heartbeat.frequency = heartbeatPitch }
    }

    @Published var criticalError: CriticalError?
    @Published var showLogSheet = false
    @Published var connectionStatus: String?
    @Published var isTestingConnection = false
    @Published var glassesStatus: String?
    @Published var glassesReady = false

    private var eggWasActive = false
    private func save<T>(_ value: T, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    var isEasterEggActive: Bool {
        #if DEBUG
        return codename.trimmingCharacters(in: .whitespaces) == "Proper Dave"
        #else
        return false
        #endif
    }
    var criticalTitle: String {
        #if DEBUG
        // Literal lives inside DEBUG so Release binaries contain no trace
        // of it (INS-11) — verified with strings against the product.
        if isEasterEggActive { return "Hey! Who turned out the lights?" }
        #endif
        return criticalError?.title ?? "Error"
    }
    var effectiveGlassesMicEnabled: Bool {
        ExperimentalFeatures.glassesMicrophoneEnabled(userEnabled: glassesMicEnabled)
    }
    var promptInputDescription: String {
        effectiveGlassesMicEnabled && sourceKind == .glasses
            ? "Glasses mic requested (experimental); phone mic until DAT audio is linked"
            : "Phone microphone"
    }

    init() {
        let d = UserDefaults.standard
        promptText = d.string(forKey: "promptText") ?? ""
        backend = Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .demo
        sourceKind = FrameSourceKind(rawValue: d.string(forKey: "sourceKind") ?? "") ?? .mock
        serverHost = d.string(forKey: "serverHost") ?? ""
        serverPort = d.integer(forKey: "serverPort") == 0 ? 3283 : d.integer(forKey: "serverPort")
        apiKey = d.string(forKey: "apiKey") ?? ""
        sampleInterval = d.double(forKey: "sampleInterval") == 0 ? 2 : d.double(forKey: "sampleInterval")
        glassesMicEnabled = d.bool(forKey: "glassesMicEnabled")
        criticalPresentation = CriticalPresentation(rawValue: d.string(forKey: "criticalPresentation") ?? "") ?? .terminalOnly
        codename = d.string(forKey: "codename") ?? ""
        heartbeatEnabled = d.bool(forKey: "heartbeatEnabled")
        heartbeatInterval = d.double(forKey: "heartbeatInterval") == 0 ? 4 : d.double(forKey: "heartbeatInterval")
        heartbeatVolume = d.double(forKey: "heartbeatVolume") == 0 ? 0.25 : d.double(forKey: "heartbeatVolume")
        heartbeatPitch = d.double(forKey: "heartbeatPitch") == 0 ? 660 : d.double(forKey: "heartbeatPitch")
        session = SessionController(log: log)
        heartbeat.interval = heartbeatInterval
        heartbeat.volume = Float(heartbeatVolume)
        heartbeat.frequency = heartbeatPitch
        #if DEBUG
        heartbeat.onPing = { [weak self] in
            self?.log.append(component: "speech", event: "heartbeat_ping")
        }
        #endif
        #if DEBUG
        eggWasActive = codename.trimmingCharacters(in: .whitespaces) == "Proper Dave"
        #endif
        session.onCallout = { [weak self] text in self?.speaker.speak(text) }
        session.onCriticalError = { [weak self] title, description in
            self?.presentCritical(title: title, description: description, isTerminal: true)
        }
        // CAP-14 fallback: a dead glasses stream falls back to the phone
        // camera mid-goal instead of failing the goal.
        session.fallbackSource = { CameraDigestSource() }
        refreshGlassesState()
        // $state emits the incoming value before the stored property
        // changes, so the new state must be passed through, not re-read.
        stateSink = session.$state.sink { [weak self] state in self?.applyHeartbeat(state: state) }
    }

    /// Heartbeat sounds only while a watch is live (and never while the
    /// debug log has capture paused).
    private func applyHeartbeat(state: SessionController.State? = nil) {
        heartbeat.setActive(heartbeatEnabled && (state ?? session.state) == .watching)
    }

    var cloudClient: any CloudModelClient {
        backend == .demo ? DemoCloudClient()
            : ServerCloudClient(host: serverHost.isEmpty ? "127.0.0.1" : serverHost, port: serverPort, apiKey: apiKey)
    }

    func expectedSourceID(for kind: FrameSourceKind) -> String {
        switch kind {
        case .mock: return "mock"
        case .camera: return "iphone-camera"
        case .glasses: return "meta-glasses"
        }
    }

    func makeSource(for kind: FrameSourceKind) -> any DigestSource {
        switch kind {
        case .mock: return MockDigestSource()
        case .camera: return CameraDigestSource()
        case .glasses:
            let source = MetaGlassesDigestSource()
            source.onFailure = { [weak self] message in
                Task { @MainActor in self?.log.append(component: "capture", event: "capture_failed_terminal", detail: message) }
            }
            return source
        }
    }

    func startWatching() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cooldown = sourceKind == .mock ? max(3, sampleInterval * 1.5) : Classifier.defaultCooldown
        session.start(goalText: text, client: cloudClient, source: makeSource(for: sourceKind),
                      interval: sampleInterval, cooldown: cooldown)
        speaker.speak("Watching. \(text)")
    }

    func stopWatching() {
        session.stop()
        speaker.speak("Stopped.")
    }

    /// CAP-13/14: available at any time — idle, mid-goal, whenever. On
    /// success mid-goal, the live session switches to the glasses without
    /// missing a beat; when idle it just arms the glasses source.
    func connectGlasses() {
        WearablesBootstrap.configureIfNeeded()
        glassesStatus = "Opening Meta AI to register…"
        Task {
            do {
                try await Wearables.shared.startRegistration()
                glassesReady = Wearables.shared.registrationState == .registered
                glassesStatus = glassesReady ? "Glasses connected."
                    : "Registration not completed. Finish in the Meta AI app (Developer Mode on), then try again."
                if glassesReady {
                    let live = session.state == .watching || session.state == .pausedForDebug
                    // Assigning the picker hot-swaps a live watch via its didSet.
                    sourceKind = .glasses
                    if live { glassesStatus = "Glasses connected — switched the live watch to them." }
                }
            } catch {
                glassesReady = false
                glassesStatus = "Registration failed: \(error.localizedDescription)"
            }
            log.append(component: "capture", event: "glasses_registration", detail: glassesStatus ?? "")
        }
    }

    func refreshGlassesState() {
        WearablesBootstrap.configureIfNeeded()
        glassesReady = Wearables.shared.registrationState == .registered
    }

    func presentCritical(title: String, description: String, isTerminal: Bool) {
        log.append(component: "session", event: "critical_error_shown", detail: title)
        switch criticalPresentation {
        case .never: speaker.speak(description); return
        case .terminalOnly where !isTerminal: speaker.speak(description); return
        default: break
        }
        criticalError = CriticalError(title: title, description: description, isTerminal: isTerminal)
        #if DEBUG
        DebugNotifier.notifyCritical(title: criticalTitle, body: description)
        #endif
    }

    func viewLogFromCritical() {
        criticalError = nil
        session.pauseForDebugLog()
        showLogSheet = true
    }
    func dismissLogSheet() {
        showLogSheet = false
        session.resumeFromDebugLog()
    }

    func testConnection() {
        guard backend == .server else { connectionStatus = "On-device demo needs no server."; return }
        isTestingConnection = true
        let client = ServerCloudClient(host: serverHost.isEmpty ? "127.0.0.1" : serverHost, port: serverPort, apiKey: apiKey)
        Task {
            let ok = await client.health()
            isTestingConnection = false
            connectionStatus = ok ? "Server reachable." : "Server not reachable. Check host, port, and that it is running."
        }
    }

    #if DEBUG
    func triggerTestCriticalError() {
        presentCritical(title: "Test critical error",
                        description: "A deliberate test incident from Settings. View debug log pauses capture; Continue carries on.",
                        isTerminal: true)
    }
    #endif
}
