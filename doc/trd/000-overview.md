# TRD-000 — System Overview

Source: [sketch](../back-of-napkin-sketch.md)

## 1. The product in one paragraph

A realtime visual interpreter for blind and visually impaired users whose
defining behaviour is restraint. It speaks when the world changes in a way
that matters to the user's current request, and is otherwise silent. The
failure it exists to fix is the cheerful loop — "I still don't see Gate
B62" — every few seconds.

## 1a. On the name

The codename "Proper Dave" is deliberate. The assistive-technology
market is crowded with names in the register of (deliberately
hyperbolic example) "VisionEyeMiracleCureSightHelperWonderGuide
3000" — names that promise a sighted person's idea of a miracle
to people who did not ask for one. Dave promises nothing except
competence and restraint: a proper job, done when it matters,
silent otherwise. The product's tone — plain-spoken, unpatronising,
no cheerfulness loop — is encoded in the name. If the codename ever
changes, the register must not.

## 1b. The governing metaphor

The output target is that of a well trained sighted guide, minus
the ability to detect terrain. A guide works to a brief: the user
asks for specific things, and the guide provides those things —
"just read me the signs" and "this is my first time in Dubai, tell
me everything" are the same relationship at different scope, and
the goal parser, the verbosity tiers, and mid-goal refinement are
that relationship implemented. A guide who narrates candy wrappers
to someone who asked only for signs is not being thorough; they are
being badly trained. Silence between briefs is competence, not
absence. Terrain, finally, is expressly not Dave's: it belongs to
the cane, the dog, and the user's own skill, and claiming any of
it would be assistance applied where it was not requested. Every
future argument about when Dave should speak can be settled
against this paragraph.

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
- **SYS-07** An offline on-device model is an enhancement, never a
  prerequisite: the server path must keep working without it, and the
  offline path must keep working with no network at all (TRD-003 §4).
  Neither mode silently substitutes for the other.

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
- **Conversation mode** (TRD-006) is a separate, explicitly entered
  posture for talking *with* Dave — call-style screen, retained
  context, goals startable and refinable mid-conversation — with a
  wake-word-only state in which bystander speech is discarded
  on-device and only “Hey Proper Dave” (customisable) is obeyed.

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
  deliberately undecided here. A second, organic source of skills is
  recorded in TRD-002 CLS-19: a live session whose accumulated
  refinements have become a configuration worth keeping may be
  offered to the user as a saveable, nameable skill. How that
  authoring works — guided question-and-answer prompts, or Dave
  drafting a skeleton the user renames and edits, stored locally or
  server-side — is a decision the owner has explicitly deferred;
  this paragraph records the door, not the room behind it.
- **Incident reporting.** Crashes and failures the user cannot solve
  should eventually be sendable as incident reports to the operator
  (TRD-005 §9) — always by explicit user action, never silently.
- **Continuous-monitoring assumption (Settings toggle?).** Tools in
  this space tend to bake in one posture: continual monitoring, with
  separate tools (Be My AI is the example) meant for one-shots.
  Proper Dave currently decides per goal, from the user's wording —
  one-shot question vs continuing describe/watch (see the
  deterministic intent floor in `GoalIntent`; TRD-002/TRD-003 own the
  parsing rules). Worth considering a user-facing Settings toggle,
  "assume continuous monitoring", that sets the default reading of
  *ambiguous* phrasings (continuous unless the wording is plainly
  singular, or vice versa), with the explicit wording always
  winning and a mid-goal refinement able to flip a running goal.
  Open questions if taken up: which way the default ships, whether
  the toggle lives beside or behind Developer Mode, and how it
  interacts with conversation mode's defaults (TRD-006). Recorded
  as a consideration only; nothing in the MVP implements it, and
  goal-kind detection remains language-driven until the owner
  decides.
- **Postures, not one posture (prior-art note).** Field testing
  keeps surfacing distinct *postures* that share a pipeline but
  want different answers to "what counts as change" and "what
  earns speech": (a) moving — stroll narration (topic saliency,
  dedupe, long cooldown); (b) stationary, waiting for a specific
  event — watch (baseline reading, then silence until the target
  or a progress marker); (c) stationary, ambient — scene-change
  narration (the change itself is the relevance); (d) one-shot
  questions; and (e) **process watching** — a pot of stock going
  simmer → rolling boil → boil-over — which is a recorded *gap*:
  the change is gradual and labels stay stable ("pot" throughout),
  so a label/OCR-turnover change score can sit silent while the
  state changes. Filling (e) likely needs temporal frame
  difference or periodic frame escalation for process-shaped
  goals; undecided and unimplemented. Prior art marks the hole
  rather than the design (examples, not templates): ScribeMe's
  Live Assist narrates continuously after one prompt, and the
  owner's firsthand experience of it was periodic absence
  narration — "I still don't see an exit" every few seconds —
  consistent with frames going to an LLM with history and no
  silence gate (the owner's inference; the mechanism is not
  public). OOrion splits the postures into separate tools chosen
  up front (Find an item, from a fixed object list, with
  spatial-audio guidance; Search for text; Nearby Objects) and is
  genuinely strong at locate-and-guide, which Proper Dave does
  not attempt. Be My AI is the one-shot end of the spectrum.
  The hole Proper Dave is aimed at: one goal language across
  postures, a cheap on-device gate deciding what earns a model
  call and what earns speech, silence as the default rather
  than a failure, and the silence policy itself user-adjustable
  (verbosity today; the toggle above and a plainer "narrate
  more/less" control are the open form of it). Naming the
  postures here so posture-specific defaults are tuned
  deliberately, per posture, instead of discovered by accident
  — which is how the first three were found. Posture is
  *inferred from the goal's wording* (that inference is what
  goal parsing is), never declared by the user in Settings:
  making the user announce "I am now walking" would rebuild
  the prior art's choose-a-tool-first burden inside one app.
  Device signals the system already has (motion activity,
  frame stability) may later refine an inferred posture's
  defaults automatically, but they are hints under the
  wording, never a user-facing mode switch; the Settings
  toggle recorded above governs only how ambiguous wording
  defaults, which is a different thing.
- **Smooth tool selection, if inference ever stops paying.**
  OOrion's select-a-tool shape may not be a failure of
  imagination: deciding what to run has real overhead —
  inference latency, misclassification cost, an ever-growing
  marker/prompt surface (the field logs in this repo are the
  evidence). Proper Dave currently spends that overhead so the
  user doesn't have to. If the balance ever tips and explicit
  tool/posture selection becomes necessary, the recorded
  constraint is that selection must be *smooth*, not a return
  to menus: changeable mid-session, without taking the phone
  out of a pocket, hands-free with the glasses on. Sketch of
  the shape (not a design): a spoken override inside
  conversation/wake state ("Dave, just describe", "watch for
  this instead") or a glasses-native gesture, a one-phrase
  spoken or earcon confirmation, the current posture
  announceable on demand ("what are you doing?"), and a switch
  that preserves session and goal context the way a source
  switch does (TRD-001 CAP-14) rather than restarting. Explicit
  selection would remain an override layered on inference,
  never the entry requirement — the user who just states a
  goal should never meet a tool picker first. Open questions:
  what metric declares inference no longer paying (misroute
  rate in field logs? parse latency?), which hands-free inputs
  the glasses actually offer (TRD-001; glasses audio is still
  experimental), and how an override interacts with mid-goal
  refinement (TRD-002 CLS-16) and conversation turns (TRD-006).
  Recorded as a direction with a trigger condition; nothing
  implements it.

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
