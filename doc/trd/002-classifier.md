# TRD-002 — The Classifier (Silence Engine)

Depends on: [TRD-000](000-overview.md), [TRD-001](001-image-capture.md)

## 1. Job

For every digest, decide whether anything changed that matters to the
active goal. The default answer is silence. The MVP implementation is a
transparent scoring gate; a learned on-device model may replace it later
behind this identical interface.

```swift
struct GoalContext: Codable {
    var rawText: String
    var targets: [String]
    var exclusions: [String]
    var progressLandmarks: String?   // e.g. "gate numbers", see §4
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

## 5. Failure behaviour

- **CLS-11** Any internal error fails closed: suppress, log, move on.
  Silence plus a diagnosable log beats a callout storm.
- A goal with no extractable targets never starts; the user is asked once
  to rephrase. Watching with an empty target set is how you get
  "describe everything forever".

## 6. Tests

Golden vectors for every row of §3, run against both implementations;
offline replay of recorded digests reporting escalation counts (bar:
zero escalations on five minutes of static scene); a flickering-sign
adversarial case proving CLS-07 holds.
