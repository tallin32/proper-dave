"""Golden vectors from TRD-002 section 3. The Swift classifier will be
required to pass these same cases (CLS-03)."""

from datetime import datetime, timezone
from uuid import uuid4

from proper_dave.classifier import evaluate
from proper_dave.models import FrameDigest, GoalContext

SESSION = uuid4()
n = 0


def digest(labels=(), ocr=(), pixel=0.0):
    global n
    n += 1
    return FrameDigest(
        sessionID=SESSION, sequence=n, capturedAt=datetime.now(timezone.utc),
        sourceID="test",
        labels=[{"name": x, "confidence": 0.9} for x in labels],
        ocrText=[{"text": x, "confidence": 0.9} for x in ocr],
        sceneChange={"pixelDiff": pixel, "labelDelta": 0.0},
    )


def goal(targets, progress=None):
    return GoalContext(rawText="t", targets=targets, progressLandmarks=progress)


def test_static_concourse_stays_silent():
    g = goal(["Gate B62"])
    window = [digest(ocr=["Concourse B"], pixel=0.02) for _ in range(5)]
    assert evaluate(digest(ocr=["Concourse B"], pixel=0.02), window, g).kind == "suppress"


def test_new_gate_sign_escalates():
    g = goal(["Gate B62"])
    d = evaluate(digest(ocr=["Gate B62"], pixel=0.6), [digest(ocr=["Concourse B"])], g)
    assert d.kind == "escalateDigest"


def test_people_crossing_elevator_watch_suppressed():
    g = goal(["elevator", "floor indicator"])
    d = evaluate(digest(labels=["person"], pixel=0.7), [digest(labels=["door"])], g)
    assert (d.kind, d.reason) == ("suppress", "notRelevant")


def test_cooldown_blocks_repeat():
    g = goal(["Gate B62"])
    d = evaluate(digest(ocr=["Gate B62"], pixel=0.6), [digest(ocr=["Concourse B"])],
                 g, since_escalation=2.0)
    assert (d.kind, d.reason) == ("suppress", "cooldown")


def test_progress_gate_reported_once():
    g = goal(["Gate B62"], progress="gate numbers")
    d = evaluate(digest(ocr=["Gate B40"], pixel=0.6), [digest(ocr=["Concourse B"])], g)
    assert d.kind == "escalateDigest" and d.landmark == "B40"


def test_malformed_input_fails_closed():
    assert evaluate(None, [], goal(["x"])).reason == "classifierError"
