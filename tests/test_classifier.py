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


def dgoal(targets=(), verbosity="notable"):
    return GoalContext(rawText="describe", targets=list(targets),
                       kind="describe", verbosity=verbosity)


def test_describe_storefront_escalates():
    d = evaluate(digest(labels=["storefront"], ocr=["Verizon"], pixel=0.6),
                 [digest(ocr=["Concourse B"])], dgoal())
    assert d.kind == "escalateDigest" and "verizon" in d.topics


def test_describe_candy_wrapper_is_beneath_notice():
    d = evaluate(digest(labels=["wrapper"], pixel=0.6),
                 [digest(ocr=["Fifth Avenue"])], dgoal())
    assert (d.kind, d.reason) == ("suppress", "notSalient")


def test_describe_wrapper_matters_on_a_floor_check():
    d = evaluate(digest(labels=["wrapper"], pixel=0.6),
                 [digest(labels=["floor"], pixel=0.1)],
                 dgoal(["small items on the floor"]))
    assert d.kind == "escalateDigest" and d.saliency == 0.85


def test_describe_announced_topic_not_repeated():
    d = evaluate(digest(labels=["storefront"], ocr=["Verizon"], pixel=0.6),
                 [digest(ocr=["Concourse B"])], dgoal(),
                 announced=frozenset({"verizon", "storefront"}))
    assert (d.kind, d.reason) == ("suppress", "alreadyAnnounced")


def test_describe_people_watching_focus():
    d = evaluate(digest(labels=["person"], pixel=0.6),
                 [digest(labels=["platform"])], dgoal(["people"]))
    assert d.kind == "escalateDigest"


def test_describe_landmarks_verbosity_is_stricter():
    d = evaluate(digest(ocr=["Bakery"], pixel=0.6),
                 [digest(ocr=["Street"])], dgoal(verbosity="landmarks"))
    assert (d.kind, d.reason) == ("suppress", "notSalient")


def test_fake_parser_classifies_describe():
    from proper_dave.cloud import FakeCloudModel
    g = FakeCloudModel().parse_goal("Tell me what I see as I pass. Watch the shops")
    assert g.kind == "describe" and g.targets == ["shops"] and g.verbosity == "notable"
    g2 = FakeCloudModel().parse_goal("Describe what's interesting, just the landmarks")
    assert g2.kind == "describe" and g2.verbosity == "landmarks"


def test_describe_first_digest_always_escalates_baseline():
    d = evaluate(digest(labels=["wrapper"], pixel=0.6), [], dgoal())
    assert d.kind in ("escalateDigest", "escalateFrame")


def test_fake_parser_classifies_front_of_camera_as_question():
    from proper_dave.cloud import FakeCloudModel
    g = FakeCloudModel().parse_goal("Tell me what's in front of the camera.")
    assert g.kind == "question"
