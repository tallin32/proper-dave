# TRD-002 — The Classifier (Silence Engine)

Depends on: [TRD-000](000-overview.md), [TRD-001](001-image-capture.md)

## 1. Job

For every digest, decide whether anything changed that matters to the
active goal. The default answer is silence. The MVP implementation is a
transparent scoring gate; a learned on-device model may replace it later
behind this identical interface.

```swift
enum GoalKind: Codable { case watch, question, describe }

struct GoalContext: Codable {
    var rawText: String
    var kind: GoalKind = .watch        // see §5 for describe
    var targets: [String]              // may be empty for describe (§5)
    var exclusions: [String]
    var progressLandmarks: String?   // e.g. "gate numbers", see §4
    var verbosity: Verbosity = .notable  // describe only: landmarks | notable | detailed
    var expiresAt: Date?
}

enum Decision: Codable {
    case suppress(reason: SuppressReason)
    case escalateDigest(confidence: Double)
    case escalateFrame(confidence: Double)
}
```

- **CLS-01** Evaluation is a pure function of (digest, last-N window,
  goal) plus caller-supplied timing state. No timers, no network — this
  is what makes field sessions replayable offline.
- **CLS-02** Window size N defaults to 5 (per the sketch) and is a debug
  setting. The caller owns window and cooldown state, not the classifier.
- **CLS-03** A Python reference implementation of this spec exists so
  recorded sessions can be scored off-device; both implementations must
  pass one shared set of golden vectors.

## 2. Scoring

**Change score:** gained/lost OCR text, gained/lost labels, and pixel-diff
magnitude, normalised and combined with fixed weights (tuned constants,
not magic — they live in one place and field logs justify changing them).

**Relevance score:** how much of the *change* matches `targets`, minus
matches against `exclusions`.

- **CLS-04** Low change suppresses regardless of relevance. A target
  sitting unchanged in view was already reported; it does not get
  re-narrated.
- **CLS-05** Low relevance suppresses regardless of change. A busy scene
  unrelated to the goal (laundry during a thermostat question) costs no
  cloud call.
- **CLS-06** Escalate with the image attached only when text signals are
  too thin to settle relevance but change is large; digest-only is the
  normal path.
- **CLS-07** After an escalation, a cooldown (default 10 s, reversible)
  suppresses repeats unless change is major. This is the hard guarantee
  against the every-few-seconds failure mode from the sketch.
- **CLS-08** A finding already called out is suppressed as
  `alreadyReported`; repetition is never re-earned.

## 3. Normative scenarios

| Scenario | Behaviour |
|---|---|
| Same concourse, five frames, watching for B62 | All suppressed. Zero cloud calls. |
| "Gate B62" first appears in OCR | One escalation, one callout; identical follow-ups suppressed. |
| People cross an elevator watch; indicator unchanged | Suppressed as not relevant. |
| Elevator doors open / indicator changes | One escalation, one callout. |
| Thermostat goal; camera passes laundry, then the thermostat | Laundry silent; thermostat escalates. |
| Describe goal; a candy wrapper blows past, then a named storefront appears | Wrapper suppressed (transient, low saliency); storefront escalates once. |
| Describe goal; the fourth identical coffee chain on the same walk | Suppressed as an already-announced topic. |

## 4. Progress landmarks

Pure silence has one deliberate exception: walking an ordered sequence
(gates B40, B42 … toward B62, floor numbers, house numbers), passing an
earlier member is useful orientation, not noise.

- **CLS-09** Goal parsing may set `progressLandmarks` when the target
  implies a sequence, or the user may ask for it outright ("call out gate
  numbers as I pass them"). Without the pattern, this section never fires.
- **CLS-10** Each distinct landmark escalates exactly once per session,
  still subject to CLS-07/08. This is the seed of the sketch's
  programmable mini-skills; the general skill mechanism is post-MVP.

## 5. Describe goals (open-ended narration)

A user may ask for the world itself, not a target: "tell me what I see
as I pass." That is a **describe** goal. It inverts the watch-goal
question — not "does this match what I'm after?" but "is this notable,
and is it new?" The user has consented to narration by asking; the
restraint survives as the notability bar. (Scenario that named this
section: a Fifth Avenue stroll, and a candy wrapper blowing past —
true, visible, and beneath notice.)

- **CLS-12** Describe goals need no targets and may start with an
  empty target set; §6's no-targets rule applies to watch goals only.
  Parsing instead extracts focus categories ("shops", "building
  names") into `targets` when present, and exclusions as usual.
- **CLS-13** A **saliency score** replaces relevance for describe:
  named places and signage, entrances, landmarks, and obstacles in
  the path score high; transient small objects (blowing litter),
  individual passers-by, and already-announced topics score at or
  below zero. Announced topics are remembered per session — the
  fourth identical coffee chain is not news.
- **CLS-14** Describe speaks on **scene transitions, not frames**:
  the caller accumulates a digest window and escalates at a
  transition (new block, new frontage) or window close, under a
  longer cooldown than CLS-07 (default 20 s, reversible). The model
  summarises only what is newly notable, in one or two sentences —
  never an exhaustive inventory of a frame.
- **CLS-15** `verbosity` sets the saliency threshold:
  `landmarks` (named places, entrances, obstacles only), `notable`
  (default; adds storefronts and signage), `detailed` (adds minor
  features — where candy wrappers may legitimately appear, at the
  user's explicit request). It is part of the goal and refinable.
- **CLS-16** **Mid-goal refinement**: a follow-up utterance — "just
  the landmarks", "skip shops", "more detail" — is parsed as a patch
  to the running goal (targets, exclusions, verbosity), not a new
  goal. Session, source, window, cooldown, and announced-topic state
  all carry over. An unparseable refinement is announced once and
  the existing goal continues unchanged; refinement never silently
  restarts or ends a watch.

## 6. Failure behaviour

- **CLS-11** Any internal error fails closed: suppress, log, move on.
  Silence plus a diagnosable log beats a callout storm.
- A watch goal with no extractable targets never starts; the user is
  asked once to rephrase. Watching with an empty target set is how
  you get "describe everything forever" — which is only ever entered
  deliberately, as a describe goal under §5's stricter gate.

## 7. Tests

Golden vectors for every row of §3, run against both implementations;
offline replay of recorded digests reporting escalation counts (bar:
zero escalations on five minutes of static scene); a flickering-sign
adversarial case proving CLS-07 holds. Describe adds: golden vectors
for saliency/dedupe, a recorded-stroll replay whose escalation count
stays transition-paced (not frame-paced), and a refinement test
proving session state survives a verbosity change (CLS-16).
