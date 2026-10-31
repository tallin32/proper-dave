import Foundation

/// Prompt and payload shaping shared by on-device model tiers
/// (TRD-003 §4). Keeping this in the core means the Apple built-in
/// tier and the downloadable tier receive byte-identical requests;
/// only the engine behind the session differs.
public enum LocalModelPrompt {
    public static func goalParse(_ rawText: String) -> String {
        """
        Convert this request from a blind user into watch targets.
        Return only the structured fields requested by the schema.
        kind is "describe" for open-ended narration ("tell me what I see
        as I pass", "what's interesting here"), "question" for a one-shot
        question about the current scene, otherwise "watch". For describe,
        targets are focus categories (shops, building names, people,
        signs, landmarks) and may be empty; verbosity is landmarks,
        notable, or detailed. Otherwise targets must be concrete visible
        things: sign text, place names, gate/floor numbers, objects, or
        progress markers.

        Request: \(rawText)
        """
    }

    public static func escalation(_ request: EscalationRequest) -> String {
        let labels = request.digest.labels
            .map { "\($0.name) (\(String(format: "%.2f", $0.confidence)))" }
            .joined(separator: ", ")
        let ocr = request.digest.ocrText.map(\.text).joined(separator: " | ")
        let recent = request.recentDigests
            .map { $0.ocrText.map(\.text).joined(separator: " | ") }
            .filter { !$0.isEmpty }
            .joined(separator: " -> ")
        return """
        Goal: \(request.goal.rawText)
        Goal kind: \(request.goal.kind.rawValue) (verbosity: \(request.goal.verbosity.rawValue))
        \(request.goal.kind == .describe ? "This is a describe goal: summarise only what is newly notable — named places read verbatim, entrances, obstacles in the path. No exhaustive inventory, no transient litter unless verbosity is detailed, no repeating topics already covered. Describe people only as aggregate activity, never identifying individuals." : "")
        Targets: \(request.goal.targets.joined(separator: ", "))
        Exclusions: \(request.goal.exclusions.joined(separator: ", "))
        Machine labels: \(labels.isEmpty ? "none" : labels)
        OCR text: \(ocr.isEmpty ? "none" : ocr)
        Recent OCR: \(recent.isEmpty ? "none" : recent)
        Last callout: \(request.lastCallout ?? "none")
        Attached image: \(request.image == nil ? "no — judge only from the labels and OCR above; do not invent visual details" : "yes")

        Decide whether this exact moment deserves one short spoken callout.
        Silence is preferred. Never report that a target is merely absent.
        Do not repeat the last callout. A callout must be one or two short,
        concrete sentences, reading signs verbatim where possible.
        """
    }
}
