# Proper Dave — Technical Requirements Documents

Written 2026-10-26 from [the back-of-napkin sketch](../back-of-napkin-sketch.md).
Nothing here is code; implementation starts only after this set is reviewed.

## Settled starting decisions

| Topic | Decision |
|---|---|
| Client | iOS app, Swift. Meta glasses and phone camera are both first-class frame sources for the MVP (this is a Meta hackathon). |
| Server / harness | Python + FastAPI, runnable on a local machine and reachable over a consumer connection by port forwarding. |
| Cloud access | An adapter with two interchangeable back ends: a direct-to-model library for early development, and the MVP server. One payload shape for both. |
| Prompt entry | Typed text is a first-class entry path. Dictation is optional, never the only way in (noise, privacy, being on a call). |
| Debug affordances | Log viewer, critical-error modal, and the Easter egg live in debug/test builds only and are compiled out of production. |

## Index

| Doc | Covers |
|---|---|
| [TRD-000](000-overview.md) | System shape, vocabulary, MVP bar, build order |
| [TRD-001](001-image-capture.md) | Frame sources (phone, Meta DAT glasses), sampling, on-device digest |
| [TRD-002](002-classifier.md) | The on-device gate that decides speak-vs-silence |
| [TRD-003](003-cloud-adapter.md) | Turning an escalation into at most one callout |
| [TRD-004](004-api-contract.md) | The MVP server contract |
| [TRD-005](005-instrumentation.md) | Debug logging, critical-error reporting, Easter egg |
| [TRD-006](006-conversation.md) | Conversation mode, wake-word-only listening state, Dave's voice |

Conventions: *shall* is normative; every `XXX-nn` requirement is testable on its own;
defaults flagged *(reversible)* can be changed in one place without redesign.
