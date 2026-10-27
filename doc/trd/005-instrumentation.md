# TRD-005 — Instrumentation, Debug UX, and One Easter Egg

Depends on: all other TRDs. Everything in this document is debug/test
builds only unless stated otherwise.

## 1. Why

The developer in the field is blind and working alone. When a callout is
missed, "it didn't work" is not a diagnosis. The log must be able to
answer, for any moment of a recorded session: why did it speak, why was
it silent, how many cloud calls happened and what they cost, and which
component failed first.

## 2. Event log

- **INS-01** One append-only structured (JSONL) stream per session:
  timestamp, session ID, component, event, and detail. Minimum events:
  capture start/stop, sample-rate and retry/backoff events, source
  failures split terminal vs transient, a `decision` record for **every**
  digest (scores, thresholds, outcome, suppress reason), escalation
  sent, callout / no-callout / model error, speech events, goal
  lifecycle, server-settings changes, and experimental-feature flips.
- **INS-02** Decision records must be cheap enough to emit at full frame
  rate; the log file, not a console, is the diagnostic surface.
- **INS-03** Retention: last 10 sessions on device for the MVP (revisit
  for production). Server logs stay server-side files; merging them into
  the app viewer is post-MVP.
- **INS-04** Logs contain OCR text and, with debug capture explicitly on,
  frames — the user's actual surroundings. On-device only, export only
  by explicit user action, never transmitted by default, and no
  analytics may be added under cover of this section.

## 3. Log viewer

- **INS-05** Debug/test builds get a Log tab (filter by component/event,
  inspect one digest's trail) — a plain list is fine — plus shake-to-view
  from anywhere. Entering the viewer pauses capture; leaving resumes the
  same goal in the same session. Release builds compile the viewer, tab,
  and shake handler out entirely.

## 4. Critical-error reporting

Fatal or user-actionable failures (camera death, permissions, glasses
unregistered) deserve more than a silent log line — but a blind debug
user expects the occasional hiccup and does not need a voice-first
ceremony around each one.

- **INS-06** In debug/test builds, a critical error posts a **local
  notification** (custom sound permitted) and raises a modal when the
  app is in hand; release builds instead speak one plain notice and log.
- **INS-07** The modal carries a title, a plain-language description
  with the user's next action, and exactly two buttons: **View debug
  log** (pauses capture per INS-05) and **Continue** (dismisses; a
  terminal failure does not silently resurrect capture). One modal per
  incident — repeats update the log, never stack modals.
- **INS-08** Presentation is a Settings choice (always / terminal-only /
  never; terminal-only is default) and must be fully VoiceOver-usable.
  Automatically *speaking* the modal is a post-hackathon refinement;
  the one exception is INS-09's title, spoken whenever the modal is read.

## 5. Easter egg

The codename is a Doctor Who reference (Proper Dave, *Silence in the
Library*; the earnest-names-for-blind-apps genre is why the project
isn't called something like "EnVision"). It ships in debug/test builds
only, and production excludes it completely.

- **INS-09** When activated, the critical-error modal's title — as
  displayed and as spoken — becomes exactly:
  “Hey! Who turned out the lights?”
- **INS-10** Activation: entering the exact value `Proper Dave` in a
  debug-only **Codename** Settings field. Deliberately not a voice
  command: speech input is the component most likely to be broken at the
  moment this modal appears. Changing or clearing the value deactivates;
  both transitions are logged.
- **INS-11** Production builds contain none of it — no string, no field,
  no activation path. This is verifiable against the release binary, and
  shall be verified, not assumed.

## 6. Acceptance

Walk a recorded failing session and answer §1's four questions from the
log alone. Needing the user to re-enact the walk means instrumentation
has failed, regardless of how much was logged.
