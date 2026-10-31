"""Model back-end tests (TRD-003): adapter contract, env selection, and
server failure mapping — all against an httpx mock transport, no network.
"""

import json
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

from proper_dave.cloud import FakeCloudModel
from proper_dave.model_backends import (
    ChatModelClient, ModelOutputError, ModelUnavailable, model_from_env)
from proper_dave.models import EscalationRequest
from proper_dave.server import create_app

SID = uuid4()


def make_client(handler, **kw):
    transport = httpx.MockTransport(handler)
    return ChatModelClient(
        base_url="http://model.test/v1", parse_model="parse-m",
        evaluate_model="eval-m", api_key="k",
        http=httpx.Client(transport=transport), backend="frontier", **kw)


def reply(payload: dict):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={
            "choices": [{"message": {"content": json.dumps(payload)}}]})
    return handler


def escalation(image=None):
    return EscalationRequest.model_validate({
        "sessionID": str(SID),
        "goal": {"rawText": "find gate B62", "targets": ["Gate B62"]},
        "digest": {
            "sessionID": str(SID), "sequence": 1,
            "capturedAt": datetime.now(timezone.utc).isoformat(),
            "sourceID": "test", "labels": [], "ocrText": [{"text": "Gate B62"}],
            "sceneChange": {"pixelDiff": 0.5, "labelDelta": 0.0},
        },
        "recentDigests": [], "image": image})


def test_parse_goal_structured():
    client = make_client(reply({
        "targets": ["Gate B62"], "exclusions": ["B40"],
        "progressLandmarks": "gate numbers"}))
    goal = client.parse_goal("Tell me when I reach gate B62")
    assert goal.targets == ["Gate B62"] and goal.exclusions == ["B40"]
    assert goal.progress_landmarks == "gate numbers"
    assert client.model_name == "frontier:eval-m"


def test_parse_uses_parse_tier_and_sends_key():
    seen = {}

    def handler(request):
        seen["auth"] = request.headers.get("authorization")
        seen["model"] = json.loads(request.content)["model"]
        return httpx.Response(200, json={"choices": [{"message": {
            "content": '{"targets": ["elevator"], "exclusions": [], "progressLandmarks": null}'}}]})

    make_client(handler).parse_goal("find the elevator")
    assert seen == {"auth": "Bearer k", "model": "parse-m"}


def test_parse_without_targets_is_unparseable():
    client = make_client(reply({"targets": [], "exclusions": []}))
    with pytest.raises(ModelOutputError):
        client.parse_goal("watch for stuff")


def test_evaluate_callout_with_image_attached():
    seen = {}

    def handler(request):
        body = json.loads(request.content)
        seen["model"] = body["model"]
        seen["content"] = body["messages"][1]["content"]
        return httpx.Response(200, json={"choices": [{"message": {
            "content": '{"kind": "callout", "text": "Gate B62 in view.", "relevance": 0.9}'}}]})

    result = make_client(handler).evaluate(escalation(image="aGVsbG8="))
    assert result.kind == "callout" and result.text == "Gate B62 in view."
    assert seen["model"] == "eval-m"
    assert seen["content"][1]["image_url"]["url"] == "data:image/jpeg;base64,aGVsbG8="
    assert "Gate B62" in seen["content"][0]["text"]


def test_evaluate_no_callout_passthrough():
    client = make_client(reply({"kind": "noCallout", "reason": "not_relevant"}))
    result = client.evaluate(escalation())
    assert result.kind == "noCallout" and result.reason == "not_relevant"


def test_evaluate_malformed_reply_raises():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "hello!"}}]})

    with pytest.raises(ModelOutputError):
        make_client(handler).evaluate(escalation())


def test_evaluate_overlong_callout_truncated():
    client = make_client(reply({
        "kind": "callout", "text": "word " * 200, "relevance": 2.5}))
    result = client.evaluate(escalation())
    assert len(result.text) <= 321 and result.relevance == 1.0


def test_timeout_and_http_error_are_unavailable():
    def timeout_handler(request):
        raise httpx.ReadTimeout("slow", request=request)

    with pytest.raises(ModelUnavailable):
        make_client(timeout_handler).evaluate(escalation())

    def error_handler(request):
        return httpx.Response(503, text="busy")

    with pytest.raises(ModelUnavailable):
        make_client(error_handler).evaluate(escalation())


# -- env selection ------------------------------------------------------


def test_env_defaults_to_fake():
    assert isinstance(model_from_env({}), FakeCloudModel)


def test_env_local_defaults_to_workstation_ollama():
    client = model_from_env({"PROPER_DAVE_MODEL_BACKEND": "local"})
    assert client.model_name == "local:llama3.2-vision:11b"


def test_env_frontier_needs_key_model_base():
    with pytest.raises(ValueError, match="PROPER_DAVE_FRONTIER_API_KEY"):
        model_from_env({"PROPER_DAVE_MODEL_BACKEND": "frontier",
                        "PROPER_DAVE_FRONTIER_BASE_URL": "https://x/v1",
                        "PROPER_DAVE_FRONTIER_MODEL": "m"})


def test_env_frontier_tier_override():
    client = model_from_env({
        "PROPER_DAVE_MODEL_BACKEND": "frontier",
        "PROPER_DAVE_FRONTIER_BASE_URL": "https://x/v1",
        "PROPER_DAVE_FRONTIER_MODEL": "big",
        "PROPER_DAVE_FRONTIER_PARSE_MODEL": "small",
        "PROPER_DAVE_FRONTIER_API_KEY": "k"})
    assert client.model_name == "frontier:big"


def test_env_unknown_backend_rejected():
    with pytest.raises(ValueError, match="Unknown"):
        model_from_env({"PROPER_DAVE_MODEL_BACKEND": "carrier-pigeon"})


# -- server failure mapping ----------------------------------------------


class BrokenModel:
    model_name = "broken:test"

    def parse_goal(self, raw_text):
        raise ModelOutputError("gibberish")

    def evaluate(self, request):
        raise ModelUnavailable("down")


def test_server_maps_model_failures():
    app = create_app(client=BrokenModel(), min_interval_s=0)
    c = TestClient(app, raise_server_exceptions=False)
    assert c.get("/v1/health").json()["model"] == "broken:test"
    r = c.post("/v1/goals/parse", json={"rawText": "gate B62"})
    assert r.status_code == 502 and r.json()["error"]["code"] == "model_unavailable"
    body = escalation().model_dump(by_alias=True, mode="json")
    r = c.post("/v1/escalations", json=body)
    assert r.json() == {"kind": "noCallout", "text": None,
                        "relevance": None, "reason": "model_unavailable"}


def test_refine_endpoint_patches_and_refuses():
    app = create_app(client=FakeCloudModel(), min_interval_s=0)
    c = TestClient(app, raise_server_exceptions=False)
    goal = {"rawText": "watch shops", "targets": ["shops"], "kind": "describe"}
    r = c.post("/v1/goals/refine", json={"goal": goal, "refinement": "skip shops"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["exclusions"] == ["shops"] and body["targets"] == []
    r = c.post("/v1/goals/refine", json={"goal": goal, "refinement": "make it nicer"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "refinement_unparseable"


def test_chat_refine_uses_model_reply():
    client = make_client(reply({
        "kind": "describe", "verbosity": "landmarks", "targets": ["shops"],
        "exclusions": [], "progressLandmarks": None}))
    current = client.parse_goal("describe the stroll")
    patched = client.refine_goal(current, "keep it to the big landmarks please")
    assert patched.verbosity == "landmarks" and patched.raw_text == current.raw_text
