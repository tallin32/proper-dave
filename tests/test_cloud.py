

from proper_dave.cloud import FakeCloudModel


def test_fake_prefilters_scene_interest_question():
    goal = FakeCloudModel().parse_goal("Anything interesting to see here?")
    assert goal.kind == "question"
