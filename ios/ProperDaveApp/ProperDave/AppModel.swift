import AVFoundation
import Combine
import Foundation
import MWDATCore
import ProperDaveCore

enum Backend: String, CaseIterable, Identifiable {
    case demo = "On-device demo (no server)"
    case server = "Server"
    case offline = "Offline on-device model"
    var id: String { rawValue }
}

enum OfflineTier: String, CaseIterable, Identifiable {
    case apple = "Apple built-in model"
    case downloadable = "Downloadable Qwen3-VL 2B"
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
    private let motionProbe = MotionProbe()
    private var stateSink: AnyCancellable?
    private var packSink: AnyCancellable?

    @Published var promptText: String { didSet { save(promptText, "promptText") } }
    @Published var backend: Backend { didSet { save(backend.rawValue, "backend") } }
    @Published var offlineTier: OfflineTier { didSet { save(offlineTier.rawValue, "offlineTier") } }
    /// Connectivity loss mid-goal: announce it, keep the goal alive,
    /// and — only if the user opted in here — judge with the
    /// on-device model until the server answers again, then switch
    /// back. The goal never stops for a network drop.
    @Published var useLocalModelOnConnectivityLoss: Bool {
        didSet { save(useLocalModelOnConnectivityLoss, "useLocalModelOnConnectivityLoss") }
    }
    private var connectivityFallbackActive = false
    private var serverProbeTask: Task<Void, Never>?

    /// Speech (CONV-12): Dave's own voice/rate/pitch, defaulting to
    /// plain system behaviour. "" voice = system default voice.
    @Published var speechVoiceID: String {
        didSet {
            save(speechVoiceID, "speechVoiceID")
            applySpeechSettings()
            if let voice = AVSpeechSynthesisVoice(identifier: speechVoiceID),
               voice.voiceTraits.contains(.isPersonalVoice) {
                AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in }
            }
        }
    }
    @Published var speechRatePercent: Int {
        didSet { save(speechRatePercent, "speechRatePercent"); applySpeechSettings() }
    }
    @Published var speechPitch: Double {
        didSet { save(speechPitch, "speechPitch"); applySpeechSettings() }
    }

    private func applySpeechSettings() {
        speaker.voiceIdentifier = speechVoiceID
        speaker.ratePercent = speechRatePercent
        speaker.pitch = Float(speechPitch)
    }

    func speakSpeechSample() {
        speaker.speak("This is how Dave sounds. The train to Grand Central is arriving.")
    }

    /// Point-of-view demo footage (developer feature): record the
    /// frames Dave judged from, export one real-time MP4.
    let povRecorder = POVRecorder()
    @Published var povRecordingEnabled: Bool {
        didSet { save(povRecordingEnabled, "povRecordingEnabled") }
    }
    @Published var povExportURL: URL?
    @Published var povExporting = false

    func exportPOVFootage() {
        guard !povExporting else { return }
        povExporting = true
        Task { [weak self] in
            let url = await self?.povRecorder.exportMP4()
            self?.povExportURL = url
            self?.povExporting = false
            if url == nil {
                self?.speaker.speak("There is no footage to export yet.")
            }
        }
    }
    /// Recorded sessions for replay (developer feature): when on,
    /// every goal's digests + frames are saved as a bundle so the
    /// walk can be replayed through the current classifier later
    /// ("should have reported X, reports Y — twist the knobs, same
    /// data"). On-device only, last 10 kept; bundles leave the phone
    /// solely via the manual dev-server send in the Log tab.
    @Published var sessionRecordingEnabled: Bool {
        didSet { save(sessionRecordingEnabled, "sessionRecordingEnabled") }
    }
    static var recordingsBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecordedSessions", isDirectory: true)
    }
    let sessionRecorder = SessionRecorder(base: AppModel.recordingsBase)
    @Published private(set) var recordedSessions: [RecordedSessionMeta] = []
    @Published private(set) var sendingSessionID: UUID?

    func refreshRecordedSessions() {
        recordedSessions = RecordedSessionStore.summaries(base: Self.recordingsBase)
    }

    func replayRecordedSession(_ meta: RecordedSessionMeta) {
        switch session.state {
        case .idle, .ended: break
        default:
            if case .failed = session.state { break }
            return
        }
        let digests = RecordedSessionStore.loadDigests(base: Self.recordingsBase, id: meta.id)
        guard !digests.isEmpty else {
            speaker.speak("That recording has no frames to replay.")
            return
        }
        let client = RecordedAnswersClient(meta: meta)
        let source = ReplayDigestSource(digests: digests) {
            RecordedSessionStore.frameData(base: Self.recordingsBase, meta: meta, digest: $0)
        }
        log.append(component: "session", event: "replay_started",
                   detail: "\(meta.goalText) (\(digests.count) digests)")
        session.start(goalText: meta.goalText, parser: client, evaluator: client,
                      source: source, interval: 0.3, cooldown: Classifier.defaultCooldown)
        speaker.speak("Replaying. \(meta.goalText)")
    }

    func deleteRecordedSession(_ meta: RecordedSessionMeta) {
        RecordedSessionStore.delete(base: Self.recordingsBase, id: meta.id)
        refreshRecordedSessions()
    }

    /// Dev-server upload: every file of the bundle, one raw POST
    /// each, so the workstation (and the agent) can analyze the
    /// actual JPGs. Manual, per session, Developer Mode only.
    func sendRecordedSession(_ meta: RecordedSessionMeta) {
        guard sendingSessionID == nil else { return }
        sendingSessionID = meta.id
        Task { [weak self] in
            guard let self else { return }
            let dir = RecordedSessionStore.directory(base: Self.recordingsBase, id: meta.id)
            let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
            var sent = 0
            do {
                for file in files {
                    let rel = file.path.replacingOccurrences(of: dir.path + "/", with: "")
                    guard let url = URL(string: "http://\(serverHost):\(serverPort)/v1/dev/sessions/\(meta.id.uuidString)/files/\(rel)") else { continue }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    request.httpBody = try Data(contentsOf: file)
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw CloudError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, rel)
                    }
                    sent += 1
                }
                log.append(component: "session", event: "session_sent_to_server",
                           detail: "\(meta.id) files=\(sent)")
                speaker.speak("Session sent. \(sent) files.")
            } catch {
                log.append(component: "session", event: "session_send_failed",
                           detail: "\(meta.id) \(error.localizedDescription)")
                speaker.speak("Could not send the session. \(error.localizedDescription)")
            }
            sendingSessionID = nil
            refreshRecordedSessions()
        }
    }

    let modelPacks = ModelPackManager()
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
        offlineTier = OfflineTier(rawValue: d.string(forKey: "offlineTier") ?? "") ?? .apple
        useLocalModelOnConnectivityLoss = d.bool(forKey: "useLocalModelOnConnectivityLoss")
        speechVoiceID = d.string(forKey: "speechVoiceID") ?? ""
        speechRatePercent = d.integer(forKey: "speechRatePercent") == 0 ? 100 : d.integer(forKey: "speechRatePercent")
        speechPitch = d.double(forKey: "speechPitch") == 0 ? 1.0 : d.double(forKey: "speechPitch")
        povRecordingEnabled = d.bool(forKey: "povRecordingEnabled")
        sessionRecordingEnabled = d.bool(forKey: "sessionRecordingEnabled")
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
        applySpeechSettings()
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
        session.onNotice = { [weak self] text in self?.speaker.speak(text) }
        session.onFrame = { [weak self] digest, data in
            guard let self else { return }
            if self.povRecordingEnabled, let data {
                self.povRecorder.record(jpeg: data, at: digest.capturedAt)
            }
            // Replay must not record itself, or bundles nest.
            if self.sessionRecordingEnabled, digest.sourceID != "replay" {
                if self.sessionRecorder.activeSessionID != digest.sessionID {
                    self.sessionRecorder.begin(sessionID: digest.sessionID,
                                               goalText: self.session.goal?.rawText ?? "",
                                               sourceID: digest.sourceID)
                }
                self.sessionRecorder.record(digest: digest, jpeg: data)
            }
        }
        session.onConnectivityLost = { [weak self] in self?.handleConnectivityLoss() }
        session.onConnectivityRestored = { [weak self] in self?.handleConnectivityRestored() }
        session.onCriticalError = { [weak self] title, description in
            self?.presentCritical(title: title, description: description, isTerminal: true)
        }
        // CAP-14 fallback: a dead glasses stream falls back to the phone
        // camera mid-goal instead of failing the goal.
        session.fallbackSource = { CameraDigestSource() }
        session.onSourceFallback = { [weak self] sourceID in
            self?.speaker.speak("Switched to \(sourceID == "iphone-camera" ? "phone camera" : sourceID).")
            self?.glassesStatus = "Glasses stopped sending; switched to the phone camera."
        }
        // Log-only motion hint: activity changes land in the JSONL
        // next to classifier decisions so field sessions can prove
        // (or refute) walking/stationary correlations before motion
        // steers anything. No behaviour reads this yet.
        motionProbe.onEvent = { [weak self] event, detail in
            self?.log.append(component: "motion", event: event, detail: detail)
        }
        motionProbe.start()
        refreshGlassesState()
        refreshRecordedSessions()
        // $state emits the incoming value before the stored property
        // changes, so the new state must be passed through, not re-read.
        stateSink = session.$state.sink { [weak self] state in
            self?.applyHeartbeat(state: state)
            // A goal that ends on its own (or is replaced) still
            // closes its recording bundle with its log slice.
            if state == .ended || state == .starting {
                self?.finishSessionRecording()
            } else if case .failed = state {
                self?.finishSessionRecording()
            }
        }
        // Warm the downloadable model when its download completes
        // (and at launch if already installed and selected), so
        // the container load doesn't land inside a live goal.
        packSink = modelPacks.$state.sink { [weak self] state in
            guard state == .downloaded else { return }
            self?.warmOfflineModelIfSelected()
        }
        warmOfflineModelIfSelected()
    }

    private func warmOfflineModelIfSelected() {
        guard backend == .offline, offlineTier == .downloadable else { return }
        let client = cloudClient
        Task { await client.warmUp() }
    }

    /// Heartbeat sounds only while a watch is live (and never while the
    /// debug log has capture paused).
    private func applyHeartbeat(state: SessionController.State? = nil) {
        heartbeat.setActive(heartbeatEnabled && (state ?? session.state) == .watching)
    }

    var cloudClient: any CloudModelClient {
        switch backend {
        case .demo:
            return DemoCloudClient()
        case .server:
            return ServerCloudClient(host: serverHost.isEmpty ? "127.0.0.1" : serverHost, port: serverPort, apiKey: apiKey)
        case .offline:
            switch offlineTier {
            case .apple:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) { return AppleLocalClient() }
                #endif
                return UnavailableOfflineClient(modelName: "offline:apple-foundation",
                                                reason: AppleOfflineModel.statusText)
            case .downloadable:
                return DownloadableLocalClient(packManager: modelPacks)
            }
        }
    }

    /// Client-side NLU: the best local understander parses and
    /// refines goals regardless of where judgement routes (TRD-003 §2).
    var understandingClient: any CloudModelClient {
        // The demo must stay self-contained and deterministic: its own
        // parser, never a system model that may claim availability and
        // then fail generation (observed in the simulator).
        if backend == .demo { return DemoCloudClient() }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleOfflineModel.isAvailable { return AppleLocalClient() }
        #endif
        if modelPacks.isDownloaded { return DownloadableLocalClient(packManager: modelPacks) }
        return cloudClient
    }

    var offlineStatusText: String {
        switch offlineTier {
        case .apple: return AppleOfflineModel.statusText
        case .downloadable: return modelPacks.statusText
        }
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
            source.onEvent = { [weak self] event, detail in
                Task { @MainActor in self?.log.append(component: "capture", event: event, detail: detail) }
            }
            source.onStatus = { [weak self] status in
                Task { @MainActor in self?.glassesStatus = status }
            }
            return source
        }
    }

    func startWatching() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if povRecordingEnabled { povRecorder.begin() }
        if backend == .offline {
            log.append(component: "session", event: "offline_mode_started",
                       detail: "\(offlineTier.rawValue): \(offlineStatusText)")
        }
        let cooldown = sourceKind == .mock ? max(3, sampleInterval * 1.5) : Classifier.defaultCooldown
        session.start(goalText: text, parser: understandingClient, evaluator: cloudClient, source: makeSource(for: sourceKind),
                      interval: sampleInterval, cooldown: cooldown)
        speaker.speak("Watching. \(text)")
    }

    func stopWatching() {
        serverProbeTask?.cancel(); serverProbeTask = nil
        connectivityFallbackActive = false
        povRecorder.finish()
        session.stop()
        finishSessionRecording()
        speaker.speak("Stopped.")
    }

    private func finishSessionRecording() {
        guard sessionRecorder.activeSessionID != nil else { return }
        sessionRecorder.finish(events: log.events, goal: session.goal)
        refreshRecordedSessions()
        if let latest = recordedSessions.first {
            log.append(component: "session", event: "session_recorded",
                       detail: "\(latest.id) digests=\(latest.digestCount) frames=\(latest.frameCount)")
        }
    }

    /// Connectivity loss mid-goal (owner-specified behaviour):
    /// announce it once, keep the goal running, judge on-device only
    /// if the user opted in, and return to the server model when it
    /// answers again. The goal is never stopped for a network drop.
    private func handleConnectivityLoss() {
        guard backend == .server else { return }
        log.append(component: "cloud", event: "connectivity_loss_handling",
                   detail: "useLocal=\(useLocalModelOnConnectivityLoss)")
        if useLocalModelOnConnectivityLoss, let local = localFallbackClient() {
            connectivityFallbackActive = true
            session.replaceEvaluator(local, reason: "connectivity loss")
            speaker.speak("Lost the connection to the server. Continuing with the on-device model — I'll switch back when the server returns.")
            startServerProbe()
        } else if useLocalModelOnConnectivityLoss {
            speaker.speak("Lost the connection to the server, and no on-device model is ready. I'll keep watching and keep trying the server.")
            startServerProbe()
        } else {
            speaker.speak("Lost the connection to the server. I'll keep watching and keep trying.")
        }
    }

    private func handleConnectivityRestored() {
        serverProbeTask?.cancel(); serverProbeTask = nil
        log.append(component: "cloud", event: "connectivity_restored_handling",
                   detail: "wasFallback=\(connectivityFallbackActive)")
        if connectivityFallbackActive {
            connectivityFallbackActive = false
            speaker.speak("Connection restored. Back to the server model.")
        } else {
            speaker.speak("Connection restored.")
        }
    }

    private func localFallbackClient() -> (any CloudModelClient)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleOfflineModel.isAvailable { return AppleLocalClient() }
        #endif
        if modelPacks.isDownloaded { return DownloadableLocalClient(packManager: modelPacks) }
        return nil
    }

    /// While the on-device model judges, poll the server so the
    /// session can return to it. Silent: the spoken restoration
    /// comes from the session's restored callback once the server
    /// evaluator has actually answered again.
    private func startServerProbe() {
        serverProbeTask?.cancel()
        let probe = ServerCloudClient(host: serverHost.isEmpty ? "127.0.0.1" : serverHost,
                                      port: serverPort, apiKey: apiKey)
        serverProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                if await probe.health() {
                    self?.session.replaceEvaluator(
                        ServerCloudClient(host: self?.serverHost.isEmpty ?? true ? "127.0.0.1" : (self?.serverHost ?? ""),
                                          port: self?.serverPort ?? 3283, apiKey: self?.apiKey ?? ""),
                        reason: "connectivity restored")
                    return
                }
            }
        }
    }

    /// Conversation turn routing (TRD-006 control plane):
    /// deterministic session commands first (status, stop, repeat,
    /// detail level — answered from state, never a model), then
    /// one-shot questions, then mid-goal refinement, then new goals,
    /// then local chat. Anything unrecognized while idle gets an
    /// honest capability reply, never a made-up one.
    func conversationTurn(_ rawText: String, history: [String]) async -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = text.lowercased()
        guard !text.isEmpty else { return "I didn't catch that." }
        let watching = session.state == .watching || session.state == .pausedForDebug
        if let command = ConversationCommand.parse(text) {
            log.append(component: "session", event: "conversation_command", detail: "\(command)")
            switch command {
            case .speakFaster, .speakSlower:
                // Speech settings are global, not goal state: these
                // work whether or not a watch is running, and the
                // reply itself is spoken at the new rate.
                guard let delta = command.speechRateDelta(from: speechRatePercent) else {
                    return command == .speakFaster
                        ? "I'm already speaking as fast as I go."
                        : "I'm already speaking as slowly as I go."
                }
                speechRatePercent = min(200, max(50, speechRatePercent + delta))
                return "Okay — speaking at \(speechRatePercent) percent of the system rate."
            case .endConversation:
                // The view intercepts this to dismiss; reaching
                // here still answers honestly.
                return "Conversation ended."
            case .status:
                return session.statusSummary()
            case .stop:
                guard watching else { return "I'm not watching right now." }
                stopWatching()
                return "Stopped watching."
            case .repeatLast:
                if let lastCallout = session.lastCallout { return lastCallout }
                return watching ? "I haven't described anything yet."
                                : "There's nothing to repeat — I'm not watching right now."
            case .moreDetail, .lessDetail, .landmarksOnly:
                guard watching, let goal = session.goal else {
                    return "I'm not watching right now. Start a goal first, then I can adjust how much I describe."
                }
                guard let patch = command.verbosityPatch(from: goal.verbosity) else {
                    return command == .moreDetail
                        ? "I'm already describing everything I notice."
                        : "I'm already keeping it to just the landmarks."
                }
                session.applyPatch(patch, origin: "conversation")
                switch patch.verbosity {
                case .detailed: return "Okay — I'll describe more of what I notice."
                case .notable: return "Okay — I'll stick to what's notable."
                case .landmarks: return "Okay — landmarks only."
                case .none: return "Okay."
                }
            }
        }
        // An answer to Dave's own question (the low-light offer)
        // outranks goal parsing and refinement. Commands above win:
        // "stop" always stops watching, never means "no".
        if session.lowLightOfferPending, let answer = YesNoAnswer.parse(text),
           let reply = session.respondToLowLightOffer(accepted: answer) {
            log.append(component: "session", event: "conversation_answer", detail: "low-light offer: \(answer)")
            return reply
        }
        let questionMarkers = ["what's in front", "what is in front", "what do you see",
                               "in front of the camera", "in front of me"]
        if questionMarkers.contains(where: low.contains) {
            promptText = text
            startWatching()
            return "Looking — I'll tell you what I see."
        }
        if watching {
            refineWatching(text)
            return "I'll apply that to the current goal if I can."
        }
        if low.hasPrefix("watch") || low.hasPrefix("tell me when") || low.hasPrefix("find")
            || low.contains("describe") || low.contains("tell me what") {
            promptText = text
            startWatching()
            return "Starting that now: “\(text)”"
        }
        if let reply = await localChat(text, history: history) { return reply }
        return "I'm better at watching than chatting. Try “watch for the elevator”, “what's in front of me?”, or “tell me what I see as I pass”."
    }

    private func localChat(_ text: String, history: [String]) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AppleOfflineModel.isAvailable {
            return try? await AppleLocalClient().chat(userText: text, history: history)
        }
        #endif
        if modelPacks.isDownloaded {
            return try? await DownloadableLocalClient(packManager: modelPacks).chat(userText: text, history: history)
        }
        return nil
    }

    /// CLS-16 refinement: patch the running goal, never restart it.
    func refineWatching(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A yes/no here may be answering Dave's low-light offer,
        // not refining the goal.
        if session.lowLightOfferPending, let answer = YesNoAnswer.parse(trimmed),
           let reply = session.respondToLowLightOffer(accepted: answer) {
            speaker.speak(reply)
            return
        }
        session.refineGoal(text: trimmed)
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

    /// Demo reset: fully unregister from Meta AI so the next Connect runs
    /// the complete registration flow from scratch. Also goes through the
    /// Meta AI app and returns via the properdave:// callback.
    func unregisterGlasses() {
        WearablesBootstrap.configureIfNeeded()
        glassesStatus = "Opening Meta AI to unregister…"
        Task {
            do {
                try await Wearables.shared.startUnregistration()
                glassesReady = Wearables.shared.registrationState == .registered
                glassesStatus = glassesReady
                    ? "Still registered — finish the removal in the Meta AI app."
                    : "Unregistered. Use Connect Meta glasses to register again."
            } catch {
                glassesStatus = "Unregistration failed: \(error.localizedDescription)"
            }
            log.append(component: "capture", event: "glasses_unregistration", detail: glassesStatus ?? "")
        }
    }

    /// The glasses button must say what it actually does. Registration is
    /// a one-time Meta AI flow; there is no per-session "reconnect" —
    /// a live session reconnects itself, and this button's only live
    /// action is switching a running watch onto the glasses.
    var glassesActionTitle: String {
        if !glassesReady { return "Register glasses with Meta AI" }
        if (session.state == .watching || session.state == .pausedForDebug),
           session.activeSourceID != "meta-glasses" {
            return "Switch watch to glasses"
        }
        return "Glasses registered"
    }
    var glassesActionEnabled: Bool {
        if !glassesReady { return true }
        return (session.state == .watching || session.state == .pausedForDebug)
            && session.activeSourceID != "meta-glasses"
    }

    /// What the glasses button does, per glassesActionTitle.
    func glassesAction() {
        if !glassesReady {
            connectGlasses()
        } else if session.state == .watching || session.state == .pausedForDebug {
            sourceKind = .glasses  // picker didSet hot-swaps the live watch
            glassesStatus = "Switched the live watch to the glasses."
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
        guard backend == .server else {
            connectionStatus = backend == .offline ? offlineStatusText : "On-device demo needs no server."
            return
        }
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
