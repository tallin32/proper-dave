

from proper_dave.cloud import FakeCloudModel


def test_fake_prefilters_scene_interest_question():
    goal = FakeCloudModel().parse_goal("Anything interesting to see here?")
    assert goal.kind == "question"


def test_fake_distinguishes_continuing_from_one_shot():
    assert FakeCloudModel().parse_goal("Continue telling me what is in front of this camera.").kind == "describe"
    assert FakeCloudModel().parse_goal("What is currently in front of this camera?").kind == "question"


def test_fake_scene_change_narration_is_describe():
    assert FakeCloudModel().parse_goal("Keep letting me know when the scene changes.").kind == "describe"
    assert FakeCloudModel().parse_goal("Let me know when the train arrives").kind == "watch"


def test_fake_continuing_what_you_see_is_detailed_describe():
    goal = FakeCloudModel().parse_goal("Keep telling me what you see")
    assert goal.kind == "describe" and goal.verbosity == "detailed"
