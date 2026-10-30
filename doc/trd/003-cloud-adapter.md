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

## 4. Speech delivery and failures

- **CLD-05** One callout at a time; a queued one may be replaced by a
  strictly more relevant one. Nothing exceeds roughly 25 spoken seconds;
  overruns are truncated and logged.
- Network loss: drop after one retry, tell the user once per session
  ("connection lost, still watching silently"), then apply SYS-05.
- Timeout (>15 s, reversible) and malformed output both count as
  no-callout and are logged with the raw response in debug builds.
- Rate-limit/auth errors: one plain-language notice; the goal pauses
  until the user restarts it.

## 5. Tests

Fake-model contract tests covering callout, no-callout, overlong and
malformed outputs; replay of recorded escalations to evaluate prompt
changes without new field trips.
