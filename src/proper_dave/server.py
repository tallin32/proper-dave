"""MVP server (TRD-004). Run: uv run proper-dave-server  (0.0.0.0:3283)
Env: PROPER_DAVE_PORT, PROPER_DAVE_API_KEY, PROPER_DAVE_SERVER_LOG,
PROPER_DAVE_MODEL_BACKEND (fake|local|frontier, default fake) plus
PROPER_DAVE_LOCAL_* / PROPER_DAVE_FRONTIER_* (see model_backends.py).
The client never sees which back end is live (CLD-04).
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .cloud import CloudModelClient, FakeCloudModel
from .model_backends import ModelUnavailable, model_from_env
from .models import CalloutResult, EscalationRequest, ParseGoalRequest

MAX_IMAGE_BYTES = 5 * 1024 * 1024
MIN_INTERVAL_S = 10.0  # API-05 backstop mirroring the client cooldown


def _err(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status,
                        content={"error": {"code": code, "message": message}})


def create_app(client: CloudModelClient | None = None, *, api_key: str | None = None,
               min_interval_s: float = MIN_INTERVAL_S,
               log_path: str | None = None) -> FastAPI:
    model = client or FakeCloudModel()
    last_seen: dict[str, float] = {}
    app = FastAPI(title="Proper Dave MVP server", version="0.1.0")

    def log(event: dict) -> None:
        if log_path:
            with Path(log_path).open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({"ts": time.time(), **event}) + "\n")

    @app.middleware("http")
    async def auth(request: Request, call_next):
        if api_key and request.url.path != "/v1/health":
            if request.headers.get("authorization") != f"Bearer {api_key}":
                return _err(401, "unauthorised", "Missing or wrong API key.")
        return await call_next(request)

    @app.get("/v1/health")
    def health():
        return {"status": "ok", "model": getattr(model, "model_name", "unknown")}

    @app.post("/v1/goals/parse")
    def parse(body: ParseGoalRequest):
        if not body.raw_text.strip():
            return _err(400, "bad_request", "Goal text is empty.")
        try:
            return model.parse_goal(body.raw_text)
        except ModelUnavailable as exc:
            # Unparseable/unreachable model: the goal does not start.
            log({"component": "cloud", "event": "parse_model_unavailable",
                 "detail": str(exc)[:200]})
            return _err(502, "model_unavailable", "The model could not parse that goal.")

    @app.post("/v1/escalations")
    def escalate(body: EscalationRequest):
        if body.image is not None:
            try:
                size = len(base64.b64decode(body.image, validate=True))
            except (binascii.Error, ValueError):
                return _err(400, "bad_request", "Image is not valid base64.")
            if size > MAX_IMAGE_BYTES:
                return _err(413, "payload_too_large", "Image is too large.")
        session = str(body.session_id)
        now = time.monotonic()
        if now - last_seen.get(session, -1e9) < min_interval_s:
            log({"component": "server", "event": "rate_limited", "sessionID": session})
            return CalloutResult.no_callout("rate_limited")
        last_seen[session] = now
        started = time.monotonic()
        try:
            result = model.evaluate(body)
        except ModelUnavailable as exc:
            # Timeout/malformed output counts as no-callout (TRD-003 §4):
            # silence, never a crash in the watching loop.
            log({"component": "cloud", "event": "model_unavailable",
                 "sessionID": session, "detail": str(exc)[:200]})
            return CalloutResult.no_callout("model_unavailable")
        log({"component": "cloud",
             "event": "callout_received" if result.kind == "callout" else "no_callout",
             "sessionID": session,
             "latencyMs": round((time.monotonic() - started) * 1000)})
        return result

    return app


def _configured_app() -> FastAPI:
    return create_app(client=model_from_env(),
                      api_key=os.environ.get("PROPER_DAVE_API_KEY") or None,
                      log_path=os.environ.get("PROPER_DAVE_SERVER_LOG") or None)


def main() -> None:
    import sys

    import uvicorn

    try:
        configured = _configured_app()
    except ValueError as exc:
        print(f"proper-dave-server: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    uvicorn.run(configured, host="0.0.0.0",
                port=int(os.environ.get("PROPER_DAVE_PORT", "3283")))


if __name__ == "__main__":
    main()
