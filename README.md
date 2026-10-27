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

Still to build: the iOS app (TRD-001/002/005 — phone camera and Meta DAT
glasses sources, typed + dictated prompt entry, speech, debug log). Glasses
are optional and connectable at any time; their absence is never an error
(TRD-001 CAP-13/14).

## Run

```sh
uv sync --group dev
uv run proper-dave-server     # 0.0.0.0:3283 ("DAVE")
uv run pytest                 # 12 tests
```

Optional environment: `PROPER_DAVE_PORT`, `PROPER_DAVE_API_KEY`,
`PROPER_DAVE_SERVER_LOG` (JSONL server log).
