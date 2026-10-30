# TRD-004 — MVP Server and API Contract

Depends on: [TRD-000](000-overview.md), [TRD-003](003-cloud-adapter.md)

## 1. Job

A small server the developer runs on a local machine — same network as
the phone, or exposed by port forwarding on a consumer connection — that
receives escalations, calls the model through the TRD-003 adapter, and
returns callouts. It is deliberately boring.

## 2. Shape

- **API-01** Python + FastAPI. Pydantic models and Swift `Codable` types
  are kept in lockstep by shared schema fixtures (CAP-08).
- **API-02** Stateless per request. Goal and session data ride in each
  request body; between calls the server keeps only logs.
- **API-03** The client app lets the user set server host (IP or DNS
  name) and port in Settings and test the connection there. Default port
  **3283** ("DAVE" on a phone keypad) — chosen by the owner, must not be
  "helpfully" changed.

## 3. Endpoints (`/v1`)

| Call | Body | Returns |
|---|---|---|
| `GET /v1/health` | — | `{status, model}` — backs the Settings test button |
| `POST /v1/goals/parse` | `{rawText}` | `GoalContext` (TRD-002) |
| `POST /v1/escalations` | `EscalationRequest` (TRD-003) | `CalloutResult` (TRD-003) |

- Images, when attached, travel base64-in-JSON for the MVP (recorded
  upgrade path: multipart). Request cap 5 MB *(reversible)*.
- **API-04** An escalation is safe to lose: neither side mutates state
  over a dropped request or response.
- **API-05** The server independently enforces a per-session minimum
  interval mirroring CLS-07 and answers excess load with
  `noCallout("rate_limited")` *without* calling the model — defence in
  depth against a buggy client talking to itself in public.

## 4. Errors and versioning

Uniform shape: `{"error": {"code", "message"}}` with codes `bad_request`,
`payload_too_large`, `unauthorised`, `model_unavailable`, `rate_limited`,
`internal`. The client speaks a given code's message at most once per
session. Breaking changes move to `/v2`; within `/v1` only additive
optional fields. `skillID` is reserved-and-ignored now so programmable
skills (post-MVP) don't force a v2. `GoalContext` likewise gains
`kind` (watch/question/describe) and `verbosity` as additive optional
fields with defaults (`watch`, `notable`), so describe goals
(TRD-002 §5) ride `/v1` without a version bump; older payloads mean
exactly what they meant before.

## 5. Security, honestly scoped

No accounts in the MVP. An optional shared API key travels as a Bearer
header; over plain HTTP at home that is a courtesy lock, not security,
and the UI copy must say so. TLS/tunnels are the operator's choice.
Escalated images are never written to disk outside explicit debug
logging, and go nowhere except the configured model API.

## 6. Running and tests

```sh
uv run proper-dave-server            # 0.0.0.0:3283
curl localhost:3283/v1/health
```

Schema contract tests in both directions; end-to-end against a fake
model (no API key needed); a flood test proving API-05, not the model,
absorbs abuse. If the MVP ships with hackathon time to spare, the
agreed stretch order is: BYOK first, then accounts.
