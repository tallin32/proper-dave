import Foundation
import ProperDaveCore
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

enum OfflineModelError: LocalizedError {
    case unavailable(String)
    case emptyGoalParse
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyGoalParse: return "The offline model could not identify anything concrete to watch for."
        }
    }
}

enum AppleOfflineModel {
    static var statusText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Available on this device. No Proper Dave download; iOS manages the model and its storage."
            case .unavailable(.deviceNotEligible):
                return "Unavailable: this device does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Unavailable: turn on Apple Intelligence in iOS Settings."
            case .unavailable(.modelNotReady):
                return "Unavailable yet: iOS is still preparing or downloading the system model. This happens in iOS Settings, not in Proper Dave."
            case .unavailable(let other):
                return "Unavailable: \(other)"
            }
        }
        #endif
        return "Unavailable: requires iOS 26 or later."
    }

    static var isAvailable: Bool { statusText.hasPrefix("Available") }
}

#if canImport(FoundationModels)

@available(iOS 26.0, *)
@Generable(description: "Structured watch targets parsed from a blind user's request")
struct LocalGoalOutput {
    @Guide(description: "watch, question, or describe")
    var kind: String
    @Guide(description: "landmarks, notable, or detailed (describe goals)")
    var verbosity: String
    @Guide(description: "Concrete visible targets, or focus categories for describe goals")
    var targets: [String]
    @Guide(description: "Things explicitly excluded by the user")
    var exclusions: [String]
    @Guide(description: "Visible progression to report, such as gate numbers; empty if none")
    var progressLandmarks: String
}

@available(iOS 26.0, *)
@Generable(description: "A structured patch to a running goal from a free-form follow-up")
struct LocalPatchOutput {
    @Guide(description: "True if the follow-up was understood as a goal change")
    var understood: Bool
    @Guide(description: "New verbosity: landmarks, notable, detailed, or empty to keep")
    var verbosity: String
    @Guide(description: "Replacement target/focus list, or empty to keep")
    var setTargets: [String]
    @Guide(description: "Targets/focus categories to add")
    var addTargets: [String]
    @Guide(description: "Targets/focus categories to remove")
    var removeTargets: [String]
    @Guide(description: "Things to exclude from now on")
    var addExclusions: [String]
}

@available(iOS 26.0, *)
@Generable(description: "Whether this moment deserves one spoken callout")
struct LocalEscalationOutput {
    @Guide(description: "True only when speaking now is worthwhile")
    var shouldCallout: Bool
    @Guide(description: "One or two short spoken sentences; empty when silent")
    var text: String
    @Guide(description: "Relevance from 0 to 1")
    var relevance: Double
    @Guide(description: "Short reason when silent")
    var reason: String
}

/// One FoundationModels session per request. The same implementation is
/// used with Apple's system model and, on iOS 27, an MLXLanguageModel;
/// the prompts come from ProperDaveCore so the tiers cannot drift.
@available(iOS 26.0, *)
struct FoundationLocalClient: CloudModelClient {
    let modelName: String
    let makeSession: @Sendable () -> LanguageModelSession

    /// One retry with a fresh session: the system model
    /// intermittently fails a generation outright (observed in the
    /// field at 04:58, one second after goal start, on a prompt
    /// that had parsed cleanly at 04:41). A transient generation
    /// error must not be a dead goal.
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { return try await operation() }
    }

    func parseGoal(_ rawText: String) async throws -> GoalContext {
        try await withRetry { try await parseGoalOnce(rawText) }
    }

    private func parseGoalOnce(_ rawText: String) async throws -> GoalContext {
        let output = try await makeSession().respond(
            to: LocalModelPrompt.goalParse(rawText), generating: LocalGoalOutput.self).content
        let targets = output.targets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kind = GoalKind(rawValue: output.kind) ?? .watch
        guard kind == .describe || !targets.isEmpty else { throw OfflineModelError.emptyGoalParse }
        return GoalContext(
            rawText: rawText, targets: targets,
            exclusions: output.exclusions.filter { !$0.isEmpty },
            progressLandmarks: output.progressLandmarks.isEmpty ? nil : output.progressLandmarks,
            kind: GoalKind(rawValue: output.kind) ?? .watch,
            verbosity: Verbosity(rawValue: output.verbosity) ?? .notable)
    }

    func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
        try await withRetry { try await refineOnce(current: current, refinement: refinement) }
    }

    private func refineOnce(current: GoalContext, refinement: String) async throws -> GoalContext {
        let prompt = """
        Current goal: \(current.rawText)
        Kind: \(current.kind.rawValue), verbosity: \(current.verbosity.rawValue)
        Targets/focus: \(current.targets.joined(separator: ", "))
        Exclusions: \(current.exclusions.joined(separator: ", "))
        Follow-up from the user: \(refinement)

        Convert the follow-up into the structured patch. "Just the
        landmarks" means verbosity landmarks. "Skip X" excludes X.
        "Only X" replaces the targets. If the follow-up is not a goal
        change you can identify, set understood to false.
        """
        let output = try await makeSession().respond(to: prompt, generating: LocalPatchOutput.self).content
        guard output.understood else { throw RefinementError.unparseable }
        let patch = GoalPatch(
            verbosity: Verbosity(rawValue: output.verbosity),
            setTargets: output.setTargets.isEmpty ? nil : output.setTargets,
            addTargets: output.addTargets, removeTargets: output.removeTargets,
            addExclusions: output.addExclusions)
        guard !patch.isEmpty else { throw RefinementError.unparseable }
        return patch.applied(to: current)
    }

    /// Free-text conversation reply (TRD-006 PoC): history is passed
    /// in the prompt; the session itself stays single-purpose.
    func chat(userText: String, history: [String]) async throws -> String {
        let prompt = """
        You are Proper Dave, a visual assistant for a blind user. Reply
        briefly and helpfully in at most two sentences. If the user wants
        something watched for, described, or changed, say so plainly.

        Conversation so far:
        \(history.joined(separator: "\n"))

        User: \(userText)
        Dave:
        """
        return try await withRetry {
            try await makeSession().respond(to: prompt).content
        }
    }

    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        try await withRetry { try await evaluateOnce(request) }
    }

    private func evaluateOnce(_ request: EscalationRequest) async throws -> CalloutResult {
        let session = makeSession()
        let output: LocalEscalationOutput
        if #available(iOS 27.0, *),
           let base64 = request.image,
           let data = Data(base64Encoded: base64),
           let image = UIImage(data: data)?.cgImage {
            let prompt = Prompt {
                LocalModelPrompt.escalation(request)
                Attachment(image).label("Escalated camera frame")
            }
            output = try await session.respond(to: prompt, generating: LocalEscalationOutput.self).content
        } else {
            // Below iOS 27 there is no image-attachment path: say so in
            // the prompt rather than claim an image the model can't see.
            var digestOnly = request
            digestOnly.image = nil
            output = try await session.respond(
                to: LocalModelPrompt.escalation(digestOnly), generating: LocalEscalationOutput.self).content
        }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.shouldCallout, !text.isEmpty else {
            return .noCallout(reason: output.reason.isEmpty ? "not_relevant" : output.reason)
        }
        return .callout(text: text, relevance: min(max(output.relevance, 0), 1))
    }
}

@available(iOS 26.0, *)
struct AppleLocalClient: CloudModelClient {
    var modelName: String { "offline:apple-foundation" }

    private func requireAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available: return
        case .unavailable: throw OfflineModelError.unavailable(AppleOfflineModel.statusText)
        }
    }

    func parseGoal(_ rawText: String) async throws -> GoalContext {
        try requireAvailable()
        return try await FoundationLocalClient(modelName: modelName) {
            LanguageModelSession(instructions: "You parse and judge goals for a blind user. Prefer silence over low-value speech, except when answering a direct question.")
        }.parseGoal(rawText)
    }

    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        try requireAvailable()
        return try await FoundationLocalClient(modelName: modelName) {
            LanguageModelSession(instructions: "You parse and judge goals for a blind user. Prefer silence over low-value speech, except when answering a direct question.")
        }.evaluate(request)
    }

    func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
        try requireAvailable()
        return try await FoundationLocalClient(modelName: modelName) {
            LanguageModelSession(instructions: "You parse and judge goals for a blind user. Prefer silence over low-value speech, except when answering a direct question.")
        }.refine(current: current, refinement: refinement)
    }

    func chat(userText: String, history: [String]) async throws -> String {
        try requireAvailable()
        return try await FoundationLocalClient(modelName: modelName) {
            LanguageModelSession(instructions: "You are Proper Dave, a visual assistant for a blind user.")
        }.chat(userText: userText, history: history)
    }
}

struct UnavailableOfflineClient: CloudModelClient {
    let modelName: String
    let reason: String
    func parseGoal(_ rawText: String) async throws -> GoalContext {
        throw OfflineModelError.unavailable(reason)
    }
    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        throw OfflineModelError.unavailable(reason)
    }
}

#endif
