

from proper_dave.cloud import FakeCloudModel, apply_refinement
from proper_dave.models import GoalContext


def test_fake_prefilters_scene_interest_question():
    goal = FakeCloudModel().parse_goal("Anything interesting to see here?")
    assert goal.kind == "question"


def test_fake_distinguishes_continuing_from_one_shot():
    assert FakeCloudModel().parse_goal("Continue telling me what is in front of this camera.").kind == "describe"
    assert FakeCloudModel().parse_goal("What is currently in front of this camera?").kind == "question"
    # Field log 04:19: "keep watching" is continuing intent, not a one-shot.
    assert FakeCloudModel().parse_goal("Keep watching the camera and tell me what you see.").kind == "describe"


def test_fake_scene_change_narration_is_describe():
    assert FakeCloudModel().parse_goal("Keep letting me know when the scene changes.").kind == "describe"
    compound = FakeCloudModel().parse_goal(
        "Continue telling me what you see, including apartment numbers and elevators; "
        "tell me when I approach my building's gym")
    assert compound.kind == "describe"
    assert compound.targets == ["apartment numbers", "elevators", "building's gym"], compound.targets
    assert FakeCloudModel().parse_goal("Let me know when the train arrives").kind == "watch"


def test_refinement_floor_adds_watch_target():
    # Field log 03:17 mirror of the Swift deterministic floor.
    base = GoalContext(raw_text="Tell me what I see as I pass", kind="describe", targets=[])
    for text in ("While you were at it keep an eye out for an elevator",
                 "Fire at it keep an eye out for elevator",
                 "Also watch for the gym"):
        patched = apply_refinement(base, text)
        assert any("elevator" in t or "gym" in t for t in patched.targets), (text, patched.targets)


def test_fake_continuing_what_you_see_is_detailed_describe():
    goal = FakeCloudModel().parse_goal("Keep telling me what you see")
    assert goal.kind == "describe" and goal.verbosity == "detailed"
