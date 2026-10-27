"""TRD-004 contract tests; run against the fake model, no API key needed."""

from datetime import datetime, timezone
from uuid import uuid4

from fastapi.testclient import TestClient

from proper_dave.server import create_app

SID = str(uuid4())


def client(**kw):
    kw.setdefault("min_interval_s", 0)
    return TestClient(create_app(**kw))


def escalation(ocr):
    return {
        "sessionID": SID,
        "goal": {"rawText": "find gate B62", "targets": ["Gate B62"]},
        "digest": {
            "sessionID": SID, "sequence": 1,
            "capturedAt": datetime.now(timezone.utc).isoformat(),
            "sourceID": "test", "labels": [],
            "ocrText": [{"text": t} for t in ocr],
            "sceneChange": {"pixelDiff": 0.5, "labelDelta": 0.0},
        },
        "recentDigests": [],
    }


def test_health():
    r = client().get("/v1/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_parse_gate_goal_adds_progress():
    r = client().post("/v1/goals/parse", json={"rawText": "Tell me when I reach gate B62"})
    assert r.json()["progressLandmarks"] == "gate numbers"


def test_empty_goal_rejected():
    r = client().post("/v1/goals/parse", json={"rawText": " "})
    assert r.status_code == 400 and r.json()["error"]["code"] == "bad_request"


def test_escalation_callout_and_silence():
    c = client()
    assert c.post("/v1/escalations", json=escalation(["Gate B62"])).json()["kind"] == "callout"
    assert c.post("/v1/escalations", json=escalation(["Coffee"])).json()["kind"] == "noCallout"


def test_rate_limit_never_reaches_model():
    c = client(min_interval_s=60)
    c.post("/v1/escalations", json=escalation(["Gate B62"]))
    assert c.post("/v1/escalations", json=escalation(["Gate B62"])).json()["reason"] == "rate_limited"


def test_auth_when_key_set():
    c = client(api_key="k")
    assert c.post("/v1/goals/parse", json={"rawText": "gate B62"}).status_code == 401
    assert c.get("/v1/health").status_code == 200
