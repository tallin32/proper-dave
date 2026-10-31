"""Real model back ends behind the TRD-003 seam.

The shipped client only ever talks to the TRD-004 server; which model
answers is a server-side configuration choice (CLD-04):

- ``fake``     — deterministic stand-in (default; no key, no network).
- ``local``    — a model on the operator's own machine, reached through
  an OpenAI-compatible chat endpoint (e.g. Ollama on the workstation
  running the dev server: ``llama3.2-vision``).
- ``frontier`` — a hosted OpenAI-compatible API. Its key lives only in
  the server's environment, never in the app (TRD-004 §5).

Model IDs are configuration, never call-site literals (TRD-003 §3).
Parse and evaluate may use different tiers: cheap/fast for goal
parsing, stronger only where escalation judgement needs it.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping

import httpx

from .cloud import CloudModelClient, FakeCloudModel
from .models import CalloutResult, EscalationRequest, GoalContext


class ModelUnavailable(Exception):
    """The configured model could not be reached or refused the call."""


class ModelOutputError(ModelUnavailable):
    """The model answered, but not in the contract's shape (CLD: malformed
    output counts as no-callout for evaluate, and blocks goal start)."""


MAX_CALLOUT_CHARS = 320  # ~25 spoken seconds (CLD-05); longer is truncated

PARSE_SYSTEM = """You convert a blind user's spoken goal into structured watch targets.
Reply with JSON only, no prose, in exactly this shape:
{"kind": "watch"|"question"|"describe", "verbosity": "landmarks"|"notable"|"detailed", "targets": ["..."], "exclusions": ["..."], "progressLandmarks": "..." or null}
kind is "describe" for open-ended narration ("tell me what I see as I pass",
"what's interesting here"), "question" for a one-shot question about the
current scene ("what's in front of the camera", "what do you see right
now") — a question is answered from the first frame and never becomes
a watch — else "watch". For describe, targets are focus categories
(shops, building names, people, signs, landmarks) and may be empty;
verbosity sets how much counts as notable. Otherwise targets are concrete
visible things: sign text, place names, gate or floor numbers.
progressLandmarks names a visible progression to report along the way
(e.g. "gate numbers") when the goal implies passing intermediate markers, else null."""

EVALUATE_SYSTEM = """You are the eyes for a blind user who asked you to watch for one goal.
You get a scene digest (machine labels, OCR text) and sometimes a photo.
Decide whether anything in view is worth saying out loud RIGHT NOW.
Silence is a first-class, respectable outcome: when in doubt, stay silent.
Never report mere absence ("still no sign of..."). Never restate the goal.
A callout is one or two short spoken sentences: concrete, signs read verbatim.
Reply with JSON only, no prose, in exactly one of these shapes:
{"kind": "callout", "text": "...", "relevance": 0.0-1.0}
{"kind": "noCallout", "reason": "not_relevant" | "already_reported" | "low_confidence"}
For "describe" goals: summarise only what is newly notable (named places
verbatim, entrances, obstacles), never an exhaustive inventory, never
transient litter unless verbosity is "detailed", never repeat covered
topics, and describe people only as aggregate activity."""


def _json_from_reply(content: str) -> dict:
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text.removeprefix("json").strip()
    try:
        parsed = json.loads(text)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ModelOutputError(f"Model reply was not JSON: {content[:120]!r}") from exc
    if not isinstance(parsed, dict):
        raise ModelOutputError(f"Model reply was not a JSON object: {content[:120]!r}")
    return parsed


class ChatModelClient:
    """One OpenAI-compatible chat endpoint serving both contract calls.

    ``parse_model`` and ``evaluate_model`` may differ (tiered cost,
    TRD-003 §3). ``http`` is injectable so tests run on a mock transport.
    """

    def __init__(self, *, base_url: str, parse_model: str, evaluate_model: str,
                 api_key: str = "", timeout_s: float = 15.0,
                 http: httpx.Client | None = None, backend: str = "chat"):
        self._base = base_url.rstrip("/")
        self._parse_model = parse_model
        self._evaluate_model = evaluate_model
        self._api_key = api_key
        self._http = http or httpx.Client(timeout=timeout_s)
        self.model_name = f"{backend}:{evaluate_model}"

    # -- transport -----------------------------------------------------
    def _chat(self, model: str, messages: list[dict]) -> str:
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        try:
            response = self._http.post(
                f"{self._base}/chat/completions", headers=headers,
                json={"model": model, "messages": messages,
                      "response_format": {"type": "json_object"}})
        except httpx.HTTPError as exc:
            raise ModelUnavailable(f"Model endpoint unreachable: {exc}") from exc
        if response.status_code != 200:
            raise ModelUnavailable(
                f"Model endpoint answered {response.status_code}: {response.text[:200]}")
        try:
            return response.json()["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise ModelOutputError("Model reply had no message content") from exc

    # -- CloudModelClient ----------------------------------------------
    def parse_goal(self, raw_text: str) -> GoalContext:
        reply = self._chat(self._parse_model, [
            {"role": "system", "content": PARSE_SYSTEM},
            {"role": "user", "content": raw_text}])
        data = _json_from_reply(reply)
        targets = [str(t).strip() for t in data.get("targets") or [] if str(t).strip()]
        landmarks = data.get("progressLandmarks")
        kind = data.get("kind") if data.get("kind") in ("watch", "question", "describe") else "watch"
        if kind != "describe" and not targets:
            # Unparseable output means the goal does not start (TRD-003 §2).
            # Describe goals are the exception: focus categories may be empty.
            raise ModelOutputError(f"Goal parse produced no targets: {reply[:120]!r}")
        verbosity = data.get("verbosity") if data.get("verbosity") in (
            "landmarks", "notable", "detailed") else "notable"
        return GoalContext(
            rawText=raw_text.strip(), targets=targets, kind=kind, verbosity=verbosity,
            exclusions=[str(e).strip() for e in data.get("exclusions") or [] if str(e).strip()],
            progressLandmarks=str(landmarks) if landmarks else None)

    REFINE_SYSTEM = """You patch a blind user's running watch goal from a free-form follow-up.
Reply with JSON only, in the same shape as goal parsing:
{"kind": "watch"|"question"|"describe", "verbosity": "landmarks"|"notable"|"detailed", "targets": ["..."], "exclusions": ["..."], "progressLandmarks": "..." or null}
Apply the follow-up to the current goal: "just the landmarks" sets
verbosity landmarks; "skip X" adds an exclusion and drops X from targets;
"only X" replaces targets; anything unclear leaves the goal unchanged.
Never invent a different goal."""

    def refine_goal(self, current: GoalContext, refinement: str) -> GoalContext:
        payload = {"currentGoal": current.model_dump(by_alias=True, mode="json"),
                   "followUp": refinement}
        reply = self._chat(self._parse_model, [
            {"role": "system", "content": self.REFINE_SYSTEM},
            {"role": "user", "content": json.dumps(payload)}])
        data = _json_from_reply(reply)
        kind = data.get("kind") if data.get("kind") in ("watch", "question", "describe") else current.kind
        verbosity = data.get("verbosity") if data.get("verbosity") in (
            "landmarks", "notable", "detailed") else current.verbosity
        landmarks = data.get("progressLandmarks")
        return GoalContext(
            rawText=current.raw_text,
            targets=[str(t).strip() for t in data.get("targets") or [] if str(t).strip()],
            kind=kind, verbosity=verbosity,
            exclusions=[str(e).strip() for e in data.get("exclusions") or [] if str(e).strip()],
            progressLandmarks=str(landmarks) if landmarks else current.progress_landmarks,
            expiresAt=current.expires_at)

    def evaluate(self, request: EscalationRequest) -> CalloutResult:
        digest = request.digest
        scene = {
            "goal": request.goal.raw_text,
            "kind": request.goal.kind,
            "verbosity": request.goal.verbosity,
            "targets": request.goal.targets,
            "exclusions": request.goal.exclusions,
            "labels": [{"name": x.name, "confidence": x.confidence} for x in digest.labels],
            "ocrText": [x.text for x in digest.ocr_text],
            "recentOcrText": [[x.text for x in d.ocr_text] for d in request.recent_digests],
            "lastCallout": request.last_callout,
        }
        content: list[dict] = [{"type": "text", "text": json.dumps(scene)}]
        if request.image:
            content.append({"type": "image_url", "image_url": {
                "url": f"data:image/jpeg;base64,{request.image}"}})
        reply = self._chat(self._evaluate_model, [
            {"role": "system", "content": EVALUATE_SYSTEM},
            {"role": "user", "content": content}])
        data = _json_from_reply(reply)
        if data.get("kind") == "callout" and str(data.get("text") or "").strip():
            text = str(data["text"]).strip()
            if len(text) > MAX_CALLOUT_CHARS:
                text = text[:MAX_CALLOUT_CHARS].rsplit(" ", 1)[0] + "…"
            try:
                relevance = float(data.get("relevance", 1.0))
            except (TypeError, ValueError):
                relevance = 1.0
            return CalloutResult.callout(text, relevance=min(max(relevance, 0.0), 1.0))
        if data.get("kind") == "noCallout":
            return CalloutResult.no_callout(str(data.get("reason") or "not_relevant"))
        raise ModelOutputError(f"Model reply matched neither shape: {reply[:120]!r}")


def model_from_env(env: Mapping[str, str] | None = None) -> CloudModelClient:
    """Build the configured back end. Defaults to the fake model so a
    bare `uv run proper-dave-server` still works with zero setup."""
    env = os.environ if env is None else env
    backend = (env.get("PROPER_DAVE_MODEL_BACKEND") or "fake").strip().lower()
    if backend == "fake":
        return FakeCloudModel()
    if backend not in ("local", "frontier"):
        raise ValueError(
            f"Unknown PROPER_DAVE_MODEL_BACKEND {backend!r}; use fake, local, or frontier.")
    prefix = "PROPER_DAVE_LOCAL" if backend == "local" else "PROPER_DAVE_FRONTIER"
    base_url = env.get(f"{prefix}_BASE_URL") or (
        "http://localhost:11434/v1" if backend == "local" else "")
    model = env.get(f"{prefix}_MODEL") or (
        "llama3.2-vision:11b" if backend == "local" else "")
    api_key = env.get(f"{prefix}_API_KEY") or ("ollama" if backend == "local" else "")
    missing = [name for name, value in
               (("BASE_URL", base_url), ("MODEL", model), ("API_KEY", api_key)) if not value]
    if missing:
        raise ValueError(
            f"Backend {backend!r} needs " +
            ", ".join(f"{prefix}_{name}" for name in missing) + " set in the environment.")
    return ChatModelClient(
        base_url=base_url,
        parse_model=env.get(f"{prefix}_PARSE_MODEL") or model,
        evaluate_model=env.get(f"{prefix}_EVALUATE_MODEL") or model,
        api_key=api_key, backend=backend)
