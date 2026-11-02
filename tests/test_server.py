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
    # The server's own anti-storm backstop reports too_soon, never
    # rate_limited: that reason is reserved for a real upstream 429
    # (field log 05:56 conflated the two).
    c = client(min_interval_s=60)
    c.post("/v1/escalations", json=escalation(["Gate B62"]))
    assert c.post("/v1/escalations", json=escalation(["Gate B62"])).json()["reason"] == "too_soon"


def test_upstream_429_reports_rate_limited():
    from proper_dave.model_backends import ModelUnavailable

    class _Throttled:
        model_name = "frontier:stub-m"

        def evaluate(self, request):
            raise ModelUnavailable("Model endpoint answered 429: slow down")

    c = client(client=_Throttled())
    assert c.post("/v1/escalations", json=escalation(["Gate B62"])).json()["reason"] == "rate_limited"


def test_auth_when_key_set():
    c = client(api_key="k")
    assert c.post("/v1/goals/parse", json={"rawText": "gate B62"}).status_code == 401
    assert c.get("/v1/health").status_code == 200


class _NamedStubModel:
    """Minimal client double: identity is what these tests assert."""

    model_name = "frontier:stub-m"

    def evaluate(self, request):
        from proper_dave.models import CalloutResult
        return CalloutResult.callout("Gate B62 is in view.", relevance=0.9)


def test_health_reports_configured_model():
    r = client(client=_NamedStubModel()).get("/v1/health")
    assert r.json() == {"status": "ok", "model": "frontier:stub-m"}


def test_escalation_log_names_the_answering_model(tmp_path):
    log_file = tmp_path / "server.jsonl"
    c = client(client=_NamedStubModel(), log_path=str(log_file))
    assert c.post("/v1/escalations", json=escalation(["Gate B62"])).json()["kind"] == "callout"
    import json as _json
    events = [_json.loads(line) for line in log_file.read_text().splitlines()]
    received = [e for e in events if e["event"] == "callout_received"]
    assert received and received[-1]["model"] == "frontier:stub-m"


def test_main_announces_model_and_warns_on_fake(monkeypatch, capsys):
    import uvicorn

    from proper_dave.server import main

    monkeypatch.setenv("PROPER_DAVE_MODEL_BACKEND", "fake")
    monkeypatch.setattr(uvicorn, "run", lambda *a, **k: None)
    main()
    err = capsys.readouterr().err
    assert "model = fake-cloud-model" in err
    assert "WARNING: fake backend" in err


def test_dev_upload_disabled_by_default(tmp_path):
    c = client()
    r = c.post(f"/v1/dev/sessions/{SID}/files/meta.json", content=b"{}")
    assert r.status_code == 404


def test_dev_upload_stores_bundle_files(tmp_path):
    c = client(dev_upload_dir=str(tmp_path))
    r = c.post(f"/v1/dev/sessions/{SID}/files/digests.jsonl", content=b"{}\n")
    assert r.status_code == 200 and r.json()["bytes"] == 3
    r = c.post(f"/v1/dev/sessions/{SID}/files/frames/000001.jpg", content=b"\xff\xd8jpeg")
    assert r.status_code == 200
    assert (tmp_path / SID / "frames" / "000001.jpg").read_bytes() == b"\xff\xd8jpeg"
    # Traversal and non-bundle paths are refused, nothing escapes.
    r = c.post(f"/v1/dev/sessions/{SID}/files/../evil.jpg", content=b"x")
    assert r.status_code in (400, 404)
    r = c.post(f"/v1/dev/sessions/{SID}/files/notes.txt", content=b"x")
    assert r.status_code == 400
    assert not (tmp_path / "evil.jpg").exists()
