"""Cloud adapter seam (TRD-003). Real models drop in behind this protocol;
switching direct-vs-server stays a configuration choice (CLD-04).
"""

from __future__ import annotations

import re
from typing import Protocol

from .models import CalloutResult, EscalationRequest, GoalContext


class CloudModelClient(Protocol):
    def parse_goal(self, raw_text: str) -> GoalContext: ...

    def evaluate(self, request: EscalationRequest) -> CalloutResult: ...


class FakeCloudModel:
    """Deterministic, offline, labelled fake via /v1/health. Proves the
    contract end-to-end before any real model is wired up."""

    model_name = "fake-cloud-model"

    _DESCRIBE_MARKERS = ("what do i see", "tell me what i see", "describe",
                         "what's interesting", "what is interesting", "as i pass",
                         "as i stroll", "as i walk", "people watching",
                         "people-watching", "what i see")
    _FOCUS = (("shop", "shops"), ("store", "shops"), ("building name", "building names"),
              ("people", "people"), ("sign", "signs"), ("landmark", "landmarks"))

    def parse_goal(self, raw_text: str) -> GoalContext:
        text = raw_text.strip()
        low = text.lower()
        if any(m in low for m in self._DESCRIBE_MARKERS):
            focus = sorted({label for needle, label in self._FOCUS if needle in low})
            verbosity = "notable"
            if "landmark" in low and ("just" in low or "only" in low):
                verbosity = "landmarks"
            if "everything" in low or "detail" in low:
                verbosity = "detailed"
            return GoalContext(rawText=text, targets=focus,
                               kind="describe", verbosity=verbosity)
        targets: list[str] = []
        progress = None
        gate = re.search(r"\bgate\s+([a-z]\d{1,3})\b", low)
        if gate:
            targets.append(f"Gate {gate.group(1).upper()}")
            progress = "gate numbers"
        if "elevator" in low or "lift" in low:
            targets += ["elevator", "floor indicator"]
        for word in ("verizon", "metro", "station", "coffee", "restaurant", "train"):
            if word in low:
                targets.append(word)
        return GoalContext(rawText=text, targets=targets or [text],
                           progressLandmarks=progress)

    def evaluate(self, request: EscalationRequest) -> CalloutResult:
        visible = [x.name for x in request.digest.labels] + [x.text for x in request.digest.ocr_text]
        for target in request.goal.targets:
            needle = target.lower().removeprefix("gate ").strip()
            for item in visible:
                if needle and needle in item.lower():
                    return CalloutResult.callout(f"{item.strip()} in view.", relevance=0.9)
        return CalloutResult.no_callout("not_relevant")
