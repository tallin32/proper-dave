# proper-dave

An absurdly customizable AI visual assistant, designed to give you only the visual information you need and/or ask for

Design: [back-of-napkin sketch](doc/back-of-napkin-sketch.md) · [TRDs](doc/trd/README.md)

## Implemented so far

Build step 1–2 from TRD-000 §8:

- **Classifier harness** (`src/proper_dave/classifier.py`, TRD-002) — pure,
  replayable scoring gate with cooldown, already-reported suppression, and
  gate-progress landmarks, plus its golden vectors in `tests/`.
- **MVP server** (`src/proper_dave/server.py`, TRD-004) — FastAPI on port
  3283, `GET /v1/health`, `POST /v1/goals/parse`, `POST /v1/escalations`,
  per-session rate backstop, optional Bearer key, shared wire contract.
- **Fake cloud model** behind the TRD-003 `CloudModelClient` protocol, so
  the real model is a configuration swap (CLD-04).

- **iOS app** (`ios/ProperDaveApp`, core in `ios/ProperDaveCore`) —
  Home / Settings / Debug-Log tabs, typed prompt with optional dictation,
  phone-camera and Meta DAT glasses sources, debug critical-error modal
  with the Easter egg (verified absent from the Release binary). Glasses
  are optional and connectable at any time, including mid-goal; their
  absence is never an error, and a dead glasses stream falls back to the
  phone camera (TRD-001 CAP-13/14, covered by core tests).

The server picks its model back end by configuration (TRD-003 CLD-04):
`fake` (default), `local` (an OpenAI-compatible endpoint on this
machine, e.g. Ollama), or `frontier` (a hosted OpenAI-compatible API;
key lives only in the server's environment). The client never knows
which is live; `/v1/health` reports it. Still to build: field
verification on real glasses, and the fully-offline on-device fallback.

## Run

```sh
uv sync --group dev
uv run proper-dave-server     # 0.0.0.0:3283 ("DAVE")
uv run pytest                 # 26 tests
```

Dev server against a workstation-local model, or a frontier API:

```sh
PROPER_DAVE_MODEL_BACKEND=local uv run proper-dave-server
# defaults: http://localhost:11434/v1, model llama3.2-vision:11b
PROPER_DAVE_MODEL_BACKEND=frontier PROPER_DAVE_FRONTIER_BASE_URL=... \
  PROPER_DAVE_FRONTIER_MODEL=... PROPER_DAVE_FRONTIER_API_KEY=... \
  uv run proper-dave-server
```

```sh
open ios/ProperDaveApp/ProperDave.xcodeproj
swift test --package-path ios/ProperDaveCore   # 8 tests
```

Meta DAT credentials go in `ios/ProperDaveApp/Secrets.xcconfig`
(git-ignored; see `Secrets.example.xcconfig`). Without it the app still
builds and runs fully on phone/mock sources. Set your Apple team in
Signing & Capabilities so `TeamID` fills in.

Optional environment: `PROPER_DAVE_PORT`, `PROPER_DAVE_API_KEY`,
`PROPER_DAVE_SERVER_LOG` (JSONL server log), and the
`PROPER_DAVE_MODEL_BACKEND` / `PROPER_DAVE_LOCAL_*` /
`PROPER_DAVE_FRONTIER_*` family (`*_BASE_URL`, `*_MODEL`,
`*_PARSE_MODEL`, `*_EVALUATE_MODEL`, `*_API_KEY`) selecting the model
back end. Parse and evaluate may use different model tiers.
