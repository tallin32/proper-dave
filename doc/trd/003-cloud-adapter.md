# TRD-003 — Cloud Model Adapter

Depends on: [TRD-000](000-overview.md), [TRD-002](002-classifier.md)

## 1. Job

Convert one escalation into at most one short spoken callout, hiding
where the model lives today — a library calling it directly during early
development, or the MVP server (TRD-004) after that.

```swift
protocol CloudModelClient {
    func parseGoal(_ rawText: String) async throws -> GoalContext
    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult
}

enum CalloutResult {
    case callout(text: String, relevance: Double)
    case noCallout(reason: String)
}
```

- **CLD-01** `noCallout` is a first-class, respectable outcome. The model
  is told plainly that silence beats a low-value utterance, and the
  adapter never dresses a no-callout up as speech.
- **CLD-02** Callouts are one or two spoken-style sentences: concrete
  (signs read verbatim, floor numbers stated, the store named), no
  preamble, no restating the goal, never reporting mere absence.

## 2. Goal parsing

One cloud call when a goal starts turns raw text into a goal kind
(watch / question / describe), targets, exclusions, and a possible
progress pattern (TRD-002 §4), via a structured-output prompt.
Unparseable output means the goal does not start — there is no
free-text fallback watching mode. For describe goals the same call
extracts focus categories and a verbosity default instead of
requiring targets (TRD-002 CLS-12/15).

The same parse contract serves **mid-goal refinement** (CLS-16):
given the running goal plus a follow-up utterance, it returns the
patched goal. A refinement that cannot be parsed is reported to the
user once and the running goal is left exactly as it was.

Goal start also runs a **capability check**: what the task requires
(input source, temporal span, audio, visual detail) against what the
selected back end and tier can actually do. A task Dave cannot
honestly attempt — the canonical case is "describe this movie" put
to an offline tier: camera frames only, no dialogue, no plot-length
memory — is refused **once, at goal start, in plain language, with
the nearest doable alternative offered** ("I can tell you when the
scene changes, or describe what's on screen when you ask"). Refusal
never silently upgrades the back end: a user who chose an offline
tier chose it (CLD-06), and an honest "no" beats two hours of
confident incompetence.

For describe escalations the model's instruction differs from watch:
summarise only what is newly notable in this window — named places
read verbatim, entrances, obstacles in the path — in one or two
sentences. No exhaustive inventories, no transient litter at default
verbosity, no re-announcing topics the session already covered.
CLD-01/02 (silence is respectable; never report mere absence) still
bind: a window with nothing notable returns no-callout.

## 3. Two back ends, one contract

- **CLD-03** Early development may call the model directly from a Python
  library. The shipped client talks to the TRD-004 server. The request
  payload is byte-compatible between them (SYS-03).
- **CLD-04** Which back end is live is a dependency-injection decision
  plus a setting — "a two-cups-of-coffee change", never a refactor. No
  caller, prompt, or payload code may differ between the two.
- Model cost follows task complexity: cheap/fast tier for goal parsing,
  stronger tier only where escalation judgement needs it. Model IDs are
  configuration, never call-site literals (choices: OQ-0.1).
- Development keys live in the environment / local settings, never in
  source control. Real-user key custody (accounts, BYOK) is post-MVP.

## 4. Offline on-device back ends (owner-requested shipping feature)

The server remains the default, but a user may deliberately choose an
offline back end — before entering a subway, leaving coverage, or going
off grid. Offline support is a real operating mode, not a demo trick and
not a silent substitution for a failed server.

- **CLD-06** Offline mode is explicitly user-selected. Selecting it means
  inference stays on the device; the app must not quietly fail over to a
  server in that mode. If the selected offline tier is unavailable, the
  goal does not start and the reason is stated plainly.
- **CLD-07** Two tiers sit behind the same `CloudModelClient` contract:
  (a) the operating system's built-in model where available (Apple
  Foundation Models), which needs no in-app download; and (b) a
  downloadable open-weight model pack. Neither tier changes goal,
  classifier, speech, or wire-contract behaviour.
- **CLD-08** A downloadable pack is never fetched automatically. Before
  download, the UI states the model name, approximate download and
  installed sizes, licence family, and what the model can and cannot
  see. Download is user-initiated, progress is visible and cancellable,
  Wi-Fi is the default with any cellular use explicitly confirmed, and
  the pack can be deleted to reclaim the space. The exact byte count on
  disk is shown once installed.
- **CLD-09** Capability warnings are specific, not boilerplate: expected
  storage, slower response than the server, battery/heat cost during a
  long watch, and whether this tier receives the actual escalated image
  or only the on-device scene digest (labels/OCR). Warnings appear when
  the tier is selected and once at goal start, not repeatedly.
- **CLD-10** Inference uses no network. The only permitted network use
  in offline mode is the user-initiated model download/update itself;
  no frames, digests, prompts, or telemetry leave the device as part of
  inference.
- **CLD-11** Downloadable packs live only in the app's sandbox, are
  version-pinned, and are updated only by explicit user action. Deleting
  a pack returns the app to an honest "not downloaded" state.
- **CLD-12** If a task needs visual detail that the selected tier did
  not receive, the model must answer no-callout rather than invent it.
  The classifier still gates every escalation; offline mode never turns
  Proper Dave into periodic narration.

## 5. Speech delivery and failures

- **CLD-05** One callout at a time; a queued one may be replaced by a
  strictly more relevant one. Nothing exceeds roughly 25 spoken seconds;
  overruns are truncated and logged.
- Network loss: drop after one retry, tell the user once per session
  ("connection lost, still watching silently"), then apply SYS-05.
- Timeout (>15 s, reversible) and malformed output both count as
  no-callout and are logged with the raw response in debug builds.
- Rate-limit/auth errors: one plain-language notice; the goal pauses
  until the user restarts it.

## 6. Tests

Fake-model contract tests covering callout, no-callout, overlong and
malformed outputs; replay of recorded escalations to evaluate prompt
changes without new field trips. Offline tiers additionally need:
availability-state tests, download/delete state tests with a fake pack
store, and a no-network inference test (airplane-mode field check is
the acceptance evidence, not a simulator claim).
