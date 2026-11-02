"""Cloud adapter seam (TRD-003). Real models drop in behind this protocol;
switching direct-vs-server stays a configuration choice (CLD-04).
"""

from __future__ import annotations

import re
from typing import Protocol

from .models import CalloutResult, EscalationRequest, GoalContext


def apply_refinement(current: GoalContext, refinement: str) -> GoalContext:
    """Deterministic goal patcher — demo/no-model fallback ONLY
    (TRD-003 §2). Mirrors GoalPatch.deterministic in Swift."""
    low = refinement.strip().lower()
    # Strip discourse filler ("while you're at it, …") so the
    # operative clause leads; mirrors GoalPatch.deterministic.
    for filler in ("while you're at it ", "while you are at it ",
                   "while you were at it "):
        if low.startswith(filler):
            low = low[len(filler):]
            break
    patched = current.model_copy(deep=True)
    changed = False
    if "landmark" in low and ("just" in low or "only" in low):
        patched.verbosity = "landmarks"; changed = True
    elif "more detail" in low or "detailed" in low or "everything" in low:
        patched.verbosity = "detailed"; changed = True
    elif "less detail" in low or "fewer" in low:
        patched.verbosity = "landmarks"; changed = True
    for marker in ("skip ", "exclude ", "no more ", "ignore "):
        if low.startswith(marker):
            item = low[len(marker):].strip(" .!?\n\t")
            if item:
                patched.exclusions.append(item)
                patched.targets = [t for t in patched.targets if t.lower() != item]
                changed = True
    if low.startswith("only "):
        item = low[5:].strip(" .!?\n\t")
        if item:
            patched.targets = [item]; changed = True
    for marker in ("include ", "add "):
        if low.startswith(marker):
            item = low[len(marker):].strip(" .!?\n\t")
            if item:
                patched.targets.append(item); changed = True
    for marker in ("keep an eye out for ", "keep an eye on ",
                   "look out for ", "watch out for ",
                   "also watch for ", "eye out for ", "watch for "):
        idx = low.find(marker)
        if idx >= 0:
            item = low[idx + len(marker):].strip(" .!?\n\t")
            for prefix in ("the ", "a ", "an "):
                if item.startswith(prefix):
                    item = item[len(prefix):]
                    break
            if item:
                patched.targets.append(item); changed = True
            break
    if not changed:
        raise ValueError("unparseable refinement")
    return patched


class CloudModelClient(Protocol):
    def parse_goal(self, raw_text: str) -> GoalContext: ...

    def evaluate(self, request: EscalationRequest) -> CalloutResult: ...

    def refine_goal(self, current: GoalContext, refinement: str) -> GoalContext:
        return apply_refinement(current, refinement)


def _compound_targets(low: str) -> list[str]:
    """Narration + named watch targets, retained together (mirrors
    GoalIntent.compoundTargets in the Swift core)."""
    out: list[str] = []

    def clean(piece: str) -> str:
        s = piece.strip().strip(".;").strip()
        for prefix in ("the ", "my ", "a ", "an "):
            if s.startswith(prefix):
                s = s[len(prefix):]
                break
        return s.strip()

    def add(piece: str) -> None:
        value = clean(piece)
        if len(value) > 1 and value not in out:
            out.append(value)

    if "including " in low:
        tail = low.split("including ", 1)[1]
        for stop in (";", " tell me when", " let me know when"):
            tail = tail.split(stop)[0]
        for part in tail.split(","):
            for piece in part.split(" and "):
                add(piece)
    for marker in ("tell me when i approach ", "tell me when i reach ",
                   "tell me when i get to ", "tell me when you see ",
                   "let me know when i approach ", "let me know when i reach ",
                   "let me know when you see "):
        if marker in low:
            tail = low.split(marker, 1)[1]
            cut = len(tail)
            for stop in (",", ";", ".", " and tell", " and let"):
                idx = tail.find(stop)
                if idx != -1:
                    cut = min(cut, idx)
            add(tail[:cut])
    return out[:6]


class FakeCloudModel:
    """Deterministic, offline, labelled fake via /v1/health. Proves the
    contract end-to-end before any real model is wired up."""

    model_name = "fake-cloud-model"

    def refine_goal(self, current: GoalContext, refinement: str) -> GoalContext:
        return apply_refinement(current, refinement)

    _DESCRIBE_MARKERS = ("what do i see", "tell me what i see", "describe",
                         "what's interesting", "what is interesting", "as i pass",
                         "as i stroll", "as i walk", "people watching",
                         "people-watching", "what i see")
    _FOCUS = (("shop", "shops"), ("store", "shops"), ("building name", "building names"),
              ("people", "people"), ("sign", "signs"), ("landmark", "landmarks"))

    _QUESTION_MARKERS = ("what's in front", "what is in front", "what do you see", "what you see",
                         "in front of the camera", "in front of this camera", "in front of me",
                         "anything interesting", "anything notable",
                         "anything to see", "anything worth seeing",
                         "something interesting",
                         "what's interesting here", "what is interesting here")
    _SCENE_CHANGE_MARKERS = ("when the scene changes", "when anything changes",
                             "when things change", "when the view changes",
                             "as the scene changes", "as things change",
                             "keep letting me know")
    _CONTINUING_MARKERS = ("as i pass", "as i walk", "as i stroll", "as we go",
                           "while i walk", "while i stroll",
                           "keep telling", "keep describing", "keep me posted",
                           "keep me updated", "continue telling",
                           "continue describing", "continue to tell",
                           "continuously")

    def parse_goal(self, raw_text: str) -> GoalContext:
        text = raw_text.strip()
        low = text.lower()
        if any(m in low for m in self._SCENE_CHANGE_MARKERS):
            return GoalContext(rawText=text, targets=["scene changes"], kind="describe")
        if any(m in low for m in self._QUESTION_MARKERS):
            if any(m in low for m in self._CONTINUING_MARKERS):
                return GoalContext(rawText=text, targets=_compound_targets(low),
                                   kind="describe", verbosity="detailed")
            # One-shot question about the current scene: answer from
            # the first frame, do not set up a watch (TRD-000 §6).
            return GoalContext(rawText=text, targets=["the scene in front of the camera"],
                               kind="question")
        if any(m in low for m in self._DESCRIBE_MARKERS):
            focus = sorted({label for needle, label in self._FOCUS if needle in low}
                           | set(_compound_targets(low)))
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
        if request.goal.kind == "question":
            if visible:
                return CalloutResult.callout(
                    ", ".join(visible[:3]) + " in view.", relevance=0.9)
            return CalloutResult.no_callout("not_relevant")
        if request.goal.kind == "describe":
            # The fake narrates the salient digest plainly; real models
            # summarise. Silence only when nothing is visible at all.
            if visible:
                return CalloutResult.callout(
                    ", ".join(visible[:3]) + " in view.", relevance=0.7)
            return CalloutResult.no_callout("not_relevant")
        for target in request.goal.targets:
            needle = target.lower().removeprefix("gate ").strip()
            for item in visible:
                if needle and needle in item.lower():
                    return CalloutResult.callout(f"{item.strip()} in view.", relevance=0.9)
        return CalloutResult.no_callout("not_relevant")
