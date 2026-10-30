# TRD-005 — Instrumentation, Debug UX, and One Easter Egg

Depends on: all other TRDs. Everything in this document is debug/test
builds only unless stated otherwise. §8 (Developer Mode) states
otherwise: it defines a mode that exists in production builds, off by
default, and gates the diagnostic surface there.

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

## 3. Working heartbeat (product feature, from field use)

While a watch is live but Dave has nothing to say, the user may want
proof of life. An optional **synthesized** heartbeat — a soft sine ping
generated in code at runtime, no audio asset, fully offline — may sound
at a user-set interval. It is off by default, lives in Advanced
settings with interval, volume, and pitch controls, and never sounds
while idle or while the debug log has capture paused. This is a
product setting, not a debug affordance; generated-audio assets were
considered and rejected for this cue (loop repetition, licensing,
tunability). In production builds the detailed tuning controls move
behind Developer Mode (§8); hackathon builds keep them in Advanced.

## 4. Log viewer

- **INS-05** Debug/test builds get a Log tab (filter by component/event,
  inspect one digest's trail) — a plain list is fine — plus shake-to-view
  from anywhere. Entering the viewer pauses capture; leaving resumes the
  same goal in the same session. In production builds the viewer, tab,
  and shake handler are not compiled out but hidden behind Developer
  Mode (§8), unavailable until it is enabled.

## 5. Critical-error reporting

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

## 6. Easter egg

The codename is a Doctor Who reference (Proper Dave, *Silence in the
Library*; the earnest-names-for-blind-apps genre is why the project
isn't called something like "EnVision"). It is always available in
debug/test builds. In production builds it exists only behind
Developer Mode (§8) — a deliberate change from the original
"compiled out of production" rule, made by the owner: a hidden joke
may be present-but-gated rather than absent.

- **INS-09** When activated, the critical-error modal's title — as
  displayed and as spoken — becomes exactly:
  “Hey! Who turned out the lights?”
- **INS-10** Activation: entering the exact value `Proper Dave` in the
  **Codename** Settings field (shown in debug/test builds, and in
  production only inside the Developer Mode section). Deliberately not
  a voice command: speech input is the component most likely to be
  broken at the moment this modal appears. Changing or clearing the
  value deactivates; both transitions are logged.
- **INS-11** With Developer Mode off, a production build must behave
  as if the egg were absent: no field, no activation path, no spoken
  or displayed title change. The string itself will be discoverable
  in the binary; that is accepted. What is verified — against the
  release build, not assumed — is unreachability while the mode is
  off, and exact behaviour (§5) while it is on.

## 7. Acceptance

Walk a recorded failing session and answer §1's four questions from the
log alone. Needing the user to re-enact the walk means instrumentation
has failed, regardless of how much was logged.

## 8. Developer Mode (production builds; recorded decision, not yet built)

Proper Dave's product surface is deliberately, absurdly customisable;
that customisation stays visible. What production hides is the
*operator* surface — dials that exist to diagnose, not to use.

- **INS-12** Developer Mode exists in every build, is off by default,
  and is enabled by tapping the version row in Settings five times.
  The version row must be a VoiceOver-actionable control announcing
  the same gesture, so the unlock is not a sighted-only secret. Debug
  and test builds behave as if it is always on. During the hackathon
  all controls remain visible; gating lands with production polish.
- **INS-13** Behind Developer Mode in production: capture frame-rate
  and sampling controls, detailed progress-noise (heartbeat) tuning,
  the debug log viewer and shake-to-view (INS-05), server/model
  internals beyond the connection test, and the Easter egg's
  activation field (INS-10). Product controls — goal entry, source
  selection, glasses connect, skills when they exist — are never
  gated by this mode.
- **INS-14** Enabling or disabling Developer Mode is logged
  (INS-01), takes effect without restart, and disabling it returns
  every gated control to its hidden state immediately.

## 9. Incident reporting (post-hackathon direction)

- **INS-15** Failures split into user-solvable (permissions off,
  glasses unregistered: the user gets the plain next action, §5) and
  not-user-solvable (crashes, internal faults). For the latter, the
  app may offer to **send an incident report**: crash diagnostics
  (MetricKit where available) plus the session's log excerpt, to a
  future server incident endpoint in the TRD-004 error envelope.
- **INS-16** Sending is always an explicit user action, never
  automatic, and the report contains no frames unless the user
  attaches them knowingly — INS-04's "never transmitted by default"
  rule is not diluted by this section. A "lights-out" class failure
  (INS-09's namesake) is the canonical sendable incident.
