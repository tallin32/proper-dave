# Architecture (one-page version)

Proper Dave is a silence-first visual interpreter for blind users. Its
governing metaphor (TRD-000 §1b): output should equal that of a well
trained sighted guide working to a brief, minus terrain detection —
terrain belongs to the cane, the dog, and the user's skill. The guide
speaks when the brief calls for it and is otherwise quiet; silence
between briefs is competence, not absence.

## The pipeline

```
camera / glasses ──► on-device digest ──► classifier gate ──► model ──► speech
 (iPhone or Meta      (Vision: labels,     (cheap, local,       (only on    (per-app
  DAT, switchable      OCR, brightness,     decides silence)     escalate)   TTS settings)
  mid-goal)            motion, change)
```

1. **Capture** (`Capture/`): phone camera or Meta DAT glasses. Glasses
   are addable at any time, including mid-goal; their absence is never
   a fail condition, and a dead glasses stream falls back to camera.
2. **Digest** (`DigestExtractor.swift`): each frame becomes a small
   structured summary on-device — Vision labels and *accurate* OCR,
   mean brightness, frame-to-frame luma change. Raw frames are only
   escalated when the gate decides the scene earns a model's eyes.
3. **Classifier gate** (`Classifier.swift`, TRD-002): scores change,
   relevance to the active goal, and novelty against cooldown,
   already-announced suppression, a signage fast-lane (saliency ≥0.75
   bypasses describe cooldown), and settled-scene escalation (motion,
   then a hold, earns one model look). Its job is protecting silence.
4. **Model tiers**, in escalation order of reach:
   - on-device Apple Foundation model or a downloaded Qwen pack
     (offline; subway-proof),
   - the Proper Dave server (`src/proper_dave/`, FastAPI :3283) backed
     by a workstation-local model or a frontier API (currently Muse
     Spark), selected purely by environment (`model_backends.py`).
   Connectivity loss swaps tiers mid-goal and swaps back on recovery;
   the user is told once, not per frame.
5. **Speech**: once a scene escalates, the model's answer is spoken.
   Client-side overrides stop models re-litigating silence (a prose
   "nothing new" veto on a scene the gate already judged changed gets
   spoken from the digest instead).

## Goals and conversation

A goal is typed (first-class — voice is never the only input) or
dictated, and parsed into `watch` / `question` / `describe` kinds by a
deterministic intent floor underneath a model parser. Scope discipline:
the spoken response must match the brief's scope — a targeted goal
admits only what bears on it; an open "what do you see?" admits what a
guide would mention. Conversation mode is a control plane over the
same machinery (refine, pause, resume, ask), including Dave asking the
user (e.g. a low-light offer before giving up on a dark frame), with an
automatic flashlight policy for sustained darkness.

## Tuning loop

Every goal can be recorded as a session bundle (frames, digests, log,
model answers) and replayed deterministically against new classifier
settings — "that walk should have reported X; it reported Y; twist the
knobs and re-judge the same data." Bundles upload to the dev server
only by explicit per-session action from Developer Mode. This loop,
not intuition, is how the silence/speech line gets tuned.

## Layout

| Path | What |
|---|---|
| `src/proper_dave/` | Server: classifier, wire models, model backends, FastAPI app |
| `ios/ProperDaveCore/` | Platform-independent Swift core (gate, session, clients); 89 tests |
| `ios/ProperDaveApp/` | SwiftUI app: Home / Settings / Log tabs, capture, glasses, speech |
| `doc/trd/` | Design record: TRD-000 overview & metaphor, 001 capture, 002 classifier, 003 cloud, 004 API, 005 instrumentation, 006 conversation |
| `doc/architecture.md` | This file |

Tests: `uv run pytest -q` (62 Python) and
`swift test --package-path ios/ProperDaveCore` (89 Swift).
