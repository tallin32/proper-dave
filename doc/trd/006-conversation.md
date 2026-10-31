# TRD-006 — Conversation mode and wake-word listening states

Status: owner-approved design, not yet implemented. Conversation core
is hackathon-plausible; full-duplex hardening is post-hackathon.
Depends on: TRD-000 (goals), TRD-003 (understanding/judgement split),
TRD-005 (log behaviour, Developer Mode).

## 1. The mode

Watching answers the world; conversation answers the *user*. They
are different postures and Dave keeps them separate.

- **CONV-01** Conversation is an explicit mode, entered and left by
  the user's deliberate action (button; typed equivalent always
  available). There is no always-listening wake-word posture
  outside the mode, and no wake word starts the app listening from
  cold.
- **CONV-02** The conversation screen is a standard voice-call
  surface: **End conversation** (returns Home), **microphone mute**,
  **speaker mute** (separate controls — they fail differently),
  a **typed turn field with Send** (typing stays first-class even
  here), a push/hold-to-talk fallback, a **wake-word-only toggle**
  (CONV-06), and **View log** (which pauses capture as usual,
  TRD-005 INS-05).
- **CONV-03** Listening state is *audible* state. Attentive,
  wake-word-only, and speaking each have a distinct earcon (and a
  visible indicator); a state change the user cannot hear is a
  defect. Dave also confirms state changes in speech on request.

## 2. Turns and arbitration

- **CONV-04** A conversation retains bounded context (recent turns;
  the model session/history carries it, per TRD-003's understanding
  split). Within a conversation the user may ask questions
  (one-shot semantics), start goals, refine them (CLS-16), and end
  them — the existing parsers and patchers are the intent layer;
  conversation adds dialogue, not a second brain.
- **CONV-05** A watch callout outranks a conversation turn: it
  speaks, then the conversation resumes. Dave never talks over
  himself; speech output is one queue (as callouts already are).
- **CONV-06** Turn-taking: push-to-talk always works; hands-free
  turn-taking uses silence endpointing tuned in the field (the
  noisy-environment doctrine applies — a turned-down room is the
  test, not the office). Barge-in/full duplex (interrupting Dave
  mid-sentence, echo-cancelling Dave's own voice) is
  post-hackathon hardening, explicitly.

## 3. Wake-word-only ("deafened") state

The couple arguing at the next table are not noise; they are
intelligible speech that is *not addressed to Dave*. The missing
concept in other tools is addressee detection, and this state is it.

- **CONV-07** Wake-word-only is entered by voice command, button,
  or typed command — non-verbal entry is mandatory, since the
  situations that need it are those where voice is unreliable.
  Dave confirms entry in speech ("I'll only listen for 'Hey Proper
  Dave'") and the CONV-03 earcon changes.
- **CONV-08** In this state, audio is examined **on-device only**.
  Everything except the wake phrase is discarded locally: never
  transmitted, never stored, never admitted to conversation
  history, never parsed as a goal. Forced on-device recognition is
  used where available so the privacy statement is literally true.
- **CONV-09** The wake phrase returns Dave to Attentive for the
  conversation; if no turn follows within a short window, he
  re-enters wake-word-only automatically (other people's Daves
  exist). The phrase is **"Hey " + instance name**, default
  instance name "Proper Dave", both customisable in Settings
  (product settings, not Developer Mode, and *not* the TRD-005
  Codename egg field — same drawer, different socks).
- **CONV-10** Hackathon implementation: recognizer-based phrase
  spotting (existing Speech plumbing, local transcript matched and
  discarded). Known limits: recognizer restarts, battery, and the
  phrase competing with room noise — mitigated by it being one
  known phrase from a nearby owner. The ultimate implementation —
  a dedicated on-device keyword-spotting model that never produces
  a transcript of bystanders at all — is post-hackathon.

## 4. Dave's voice

- **CONV-11** Default voice is the system synthesizer; a user's
  iOS Personal Voice is inherited when present (a user who made
  one expects Dave to use it). A custom/cloud Dave voice is only
  ever a future garnish with on-device fallback — cloud voices
  glitch under congestion and die in subways, and the subway may
  not mute Dave (product doctrine). No cloud voice is ever the
  only voice.

## 5. Acceptance

Start a conversation by touch in a noisy room; hold a three-turn
exchange mixing a question, a goal start, and a refinement; enter
wake-word-only by button while a companion talks continuously —
nothing they say is answered, stored, or acted on; speak the wake
phrase and complete one turn; end by touch and land Home. Every
state change audible without looking at the screen.
