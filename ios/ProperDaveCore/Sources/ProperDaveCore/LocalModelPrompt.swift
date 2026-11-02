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
        as I pass", "tell me what's interesting as I go", "continue telling
        me what is in front of the camera", "keep letting me know when the
        scene changes"), "question" for a one-shot
        question about the current scene ("what's in front of the camera",
        "what do you see right now", "anything interesting here") — a question is answered from the
        first frame and never becomes a watch — otherwise "watch". For describe,
        targets are focus categories (shops, building names, people,
        signs, landmarks) and may be empty; a narration request may also name
        specific things to watch for ("...including apartment numbers;
        tell me when I approach the gym") — that is still describe,
        and the named things belong in targets so narration
        prioritises them. Verbosity is landmarks,
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
        \(request.goal.kind == .describe ? "This is a describe goal: summarise only what is newly notable — named places read verbatim, entrances, obstacles in the path. If targets name a place or thing the user is approaching, announce it when it becomes visible even if its visible wording differs from the target name (a target of 'gym' may be signed 'fitness center'). No exhaustive inventory, no transient litter unless verbosity is detailed, no repeating topics already covered. An escalation means the on-device gate measured a material change, and that judgement is not yours to re-make: a different view of the same room is new material, not a repeat — describe what is newly in view, and only stay silent if the same specific sign, object, or viewpoint is still all that is in frame. Describe people only as aggregate activity, never identifying individuals." : "")
        \(request.goal.kind == .describe && request.lastCallout == nil ? "BASELINE: nothing has been spoken for this goal yet, so nothing here is 'new' or 'already covered' from the user's point of view. Give a brief first description of what is currently here in one or two sentences if the labels, OCR, or image show anything at all. Do not stay silent for lack of novelty; silence-first applies only after this first report." : "")
        \(request.goal.isSceneChangeGoal ? "This goal asks to be told when the scene changes. An escalation means the view has materially changed: describe the new scene in one or two sentences. The first report establishes the starting scene — present it as what is here now, never as a change and never as 'no change', because there is no earlier scene to compare with." : "")
        Targets: \(request.goal.targets.joined(separator: ", "))
        Exclusions: \(request.goal.exclusions.joined(separator: ", "))
        Machine labels: \(labels.isEmpty ? "none" : labels)
        OCR text: \(ocr.isEmpty ? "none" : ocr)
        Recent OCR: \(recent.isEmpty ? "none" : recent)
        Last callout: \(request.lastCallout ?? "none")
        Attached image: \(request.image == nil ? "no — judge only from the labels and OCR above; do not invent visual details" : "yes")

        \(request.goal.kind == .question
            ? """
              DIRECT QUESTION: the user asked about this scene and is waiting
              for an answer. Answer it directly in one or two short, concrete
              sentences, describing what is visible (reading signs verbatim).
              The silence preference for unprompted narration does NOT apply
              here. Return noCallout only if the labels, OCR, and any attached
              image are genuinely insufficient to say anything truthful.
              """
            : request.goal.isSceneChangeGoal
            ? """
              DIRECT SCENE REPORT: describe the new scene in one or
              two short, concrete sentences from the labels, OCR,
              and any attached image. The scene differs from the
              last report. Only describe what is visible — never
              discuss these directions, detection, or silence.
              Return noCallout only if the labels, OCR, and image
              are genuinely insufficient to say anything truthful.
              """
            : """
              Decide whether this exact moment deserves one short spoken callout.
              Silence is preferred. Never report that a target is merely absent.
              Do not repeat the last callout. A callout must be one or two short,
              concrete sentences, reading signs verbatim where possible.
              On a goal's first escalation, a current reading that directly
              bears on the target — a displayed temperature below the
              requested value, a dial position, an indicator state, an
              earlier gate number on the way to yours — is worth one
              callout as a baseline. Report dial positions as estimates,
              never as precise readings. Mere absence of the target is not.
              """)
        """
    }
}
