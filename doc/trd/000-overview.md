# TRD-000 — System Overview

Source: [sketch](../back-of-napkin-sketch.md)

## 1. The product in one paragraph

A realtime visual interpreter for blind and visually impaired users whose
defining behaviour is restraint. It speaks when the world changes in a way
that matters to the user's current request, and is otherwise silent. The
failure it exists to fix is the cheerful loop — "I still don't see Gate
B62" — every few seconds.

## 2. What the MVP must prove

1. Indoors: "tell me when the elevator arrives at my floor" produces one
   callout when it arrives, and nothing before.
2. Outdoors with glasses on: "watch the signs; tell me when I'm near the
   Verizon store, a named restaurant, or a metro station" produces a
   callout on approach, from a real walk.
3. After either: a debug log explains every speak and every silence.

## 3. Vocabulary (used identically everywhere)

| Term | Meaning |
|---|---|
| Goal | One natural-language request of one of three kinds — **watch** (find a target), **question** (one-shot, escalate immediately), **describe** (open-ended narration of what's notable, TRD-002 §5) — parsed into targets, optional exclusions, an optional progress pattern, and an expiry. |
| Digest | A small on-device summary of one frame: labels, OCR text, coarse change metrics. Digests are compared and usually sent; raw video is not. |
| Classifier | The on-device component (TRD-002) that turns a digest + recent digests + goal into a Decision. |
| Decision | `SUPPRESS`, `ESCALATE_DIGEST`, or `ESCALATE_FRAME`. Default: `SUPPRESS`. |
| Callout | One short spoken utterance, or an explicit no-callout result. |
| Session | One goal's lifetime; every log event and request carries its ID. |

## 4. Shape

```
phone camera ─┐
              ├─ frames ─▶ digest ─▶ classifier ─▶ (silence, most of the time)
Meta glasses ─┘                              └─▶ escalate ─▶ cloud adapter ─▶ callout ─▶ speech
                                                  direct library ─or─ local server
all stages ─▶ structured event log (debug builds)
```

- **SYS-01** Only the classifier may start a cloud call. Nothing calls the
  model on a timer.
- **SYS-02** “Not found yet” is never spoken. Absence is the silent norm.
- **SYS-03** The escalation payload is identical via the direct library and
  via the server, so the two cannot drift (TRD-004).
- **SYS-04** Output to the user is speech plus, in debug builds, local
  notifications. Input is typed text or dictation, user's choice (see §6).
- **SYS-05** Losing the network or server degrades to silent watching, with
  the user told once per session — not per failure.
- **SYS-06** Glasses are an enhancement, never a prerequisite, and may be
  connected at any time, including mid-goal (TRD-001 CAP-13/14). Their
  absence is not an error state and is never announced as one.

## 5. Components

| Piece | Where | TRD |
|---|---|---|
| Frame sources + digest extraction | iOS | 001 |
| Classifier | iOS, spec mirrored by a Python harness | 002 |
| Cloud adapter (direct + server clients) | iOS + Python reference | 003 |
| MVP server | Local machine, Python/FastAPI | 004 |
| Instrumentation | iOS + server | 005 |

## 6. Interaction rules

- Starting a goal needs **typed or dictated** text. Typing must always
  work: users may be somewhere noisy, want privacy, or be on a phone call
  they cannot drop to speak a prompt and then rejoin.
- One active goal at a time for the MVP. Stop (voice or button) ends it,
  confirmed once.
- One-shot questions (“what's on this window sill?”) are goals that
  escalate immediately and watch nothing — same pipeline, no special mode.
- Open-ended requests (“tell me what I see as I pass”) are **describe**
  goals: narration the user explicitly asked for, gated by notability
  and novelty rather than target relevance (TRD-002 §5). SYS-02 still
  applies — what changes is the bar, not the existence of one.
- A running goal may be **refined** mid-flight (“just the landmarks”,
  “skip shops”) by typed or dictated text; refinement edits the goal
  and never restarts the session (TRD-002 CLS-16).

## 7. Out of scope for the MVP

Programmable skills (the general mechanism), accounts, subscriptions,
BYOK key custody, hosted deployment, Android, visual polish beyond
legibility. Interfaces may reserve names for these; code may not
implement them.

Recorded post-MVP directions (still out of scope; noted so today's
interfaces keep room for them):

- **User-authored skills.** Users will be able to import small,
  declarative skill packs — a "small appliance" skill, a "thermostat"
  mix-in — declared in a manifest much like an agent skill's front
  matter (name, when to bring it in, targets, prompt fragment,
  thresholds) and loaded on request, mixed into goal parsing and
  escalation judgement. The wire contract already reserves `skillID`
  for this (TRD-004 §4); nothing in the MVP implements loading,
  authoring, or trust/sandboxing of skills, and those questions are
  deliberately undecided here.
- **Incident reporting.** Crashes and failures the user cannot solve
  should eventually be sendable as incident reports to the operator
  (TRD-005 §9) — always by explicit user action, never silently.

## 8. Build order

1. Server + fake model behind the TRD-004 contract.
2. Python classifier harness against recorded digests.
3. iOS: core pipeline, then capture (phone first, glasses alongside),
   speech out, prompt in.
4. Real-model adapter; field tests against §2.

## 9. Open questions for the owner

- **OQ-0.1** Exact model IDs and cost tiers for parsing vs escalation.
[Answer] Parsing should be done on the lowest cost model that handles the input, ideally a local on-device model. Since this is all about Meta, user should be given the option to download a Muse model capable of parsing and classifying image data.
- **OQ-0.2** Is one active goal acceptable through field testing, or do
  overlapping watches (elevator + signs) need to arrive earlier?
[Answer] One active goal for the MVP; if we have time (which we very well may), then having two or three active goals seems reasonable.
