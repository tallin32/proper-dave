

from proper_dave.cloud import FakeCloudModel


def test_fake_prefilters_scene_interest_question():
    goal = FakeCloudModel().parse_goal("Anything interesting to see here?")
    assert goal.kind == "question"


def test_fake_distinguishes_continuing_from_one_shot():
    assert FakeCloudModel().parse_goal("Continue telling me what is in front of this camera.").kind == "describe"
    assert FakeCloudModel().parse_goal("What is currently in front of this camera?").kind == "question"
