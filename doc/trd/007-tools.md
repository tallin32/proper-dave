# TRD-007: Tools, skills, and one-off requests

Status: registry + scoped-request lifecycle implemented in
`ToolRegistry.swift`; camera guidance and model dispatch are next.

## 1. Two layers

**Tools are native.** A fixed, enumerable vocabulary of verbs in
compiled code. Device tools act on the device (`torch`,
`guide_to_target`, `read_sign`); server tools reason over a frame or
digest on the user's own server (`read_package`, …). Server tools may
request device verbs but cannot invent new ones — the vocabulary of
action on the device stays bounded and reviewable, which is also the
App Store 2.5.2 line: declarative configuration over a fixed native
vocabulary is configuration; downloadable general-purpose code is
not shipped. User-authored *programs* run on the user's server tier,
where custom code already belongs (see also TRD-003).

**Skills are data.** A `SkillManifest` composes registered tools with
declared parameters only, plus trigger phrasings. No executable
content. A skill is validated at import against the registry: unknown
tools and undeclared parameters are rejected.

Offline consequence, accepted: server tools and skills that need
them are unavailable off-grid — the same trade the model tiers make.
Device tools and on-device models keep working.

## 2. One-off commands

One-offs ("read that sign", "never mind") parse deterministically
and whole-utterance (`OneOffCommand`), like conversation commands
(TRD-006): "watch for the stop sign" must never parse as an
instruction. Unmatched utterances flow to goal parsing/refinement
today, and to a model dispatcher over this registry later. The model,
when it arrives, parses intent into parameter changes on the
deterministic machinery or into scoped requests — it never judges
frames; the classifier (TRD-002) keeps that job so sessions stay
replayable.

## 3. Scoped requests

A one-off is a `ScopedRequest`: a narrow sub-goal (tool + target)
pushed over the running goal. While active:

- a digest showing the target escalates immediately — no cooldown
  makes a user who just asked wait;
- the request **completes** on that escalation, **cancels** on an
  explicit "never mind", is **superseded** by a re-ask, or **decays**:
  target unseen for `lostGrace` (10 s) → `targetLost`; absolute
  45 s → `timedOut`.

Decay is announced only when the user was being actively guided
(`guidanceActive`) and is plausibly still waiting; otherwise it
expires silently, per the silence doctrine (TRD-000 §1b). The parent
goal is never restated or disturbed by any of these exits.

## 4. Next steps (not in this change)

- `guide_to_target`: Vision bounding-box steering ("sign's up-left —
  pan left — hold") so `read_sign` can ask for a better frame before
  reading, falling back to the best captured frame (owner design,
  2026-11-05).
- Targeted read escalation: full-text OCR + model on the best frame,
  asked one question only.
- Skill import UI (desktop-authored files), then the model
  dispatcher over the registry, then chat (TRD-006) as the delivery
  surface for all of it.
