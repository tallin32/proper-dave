"""Reference classifier (TRD-002). Pure and replayable (CLS-01): the same
golden vectors must pass here and in the future Swift implementation.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

from .models import FrameDigest, GoalContext

CHANGE_THRESHOLD = 0.25
RELEVANCE_THRESHOLD = 0.30
MAJOR_CHANGE = 0.80
COOLDOWN_S = 10.0

Reason = Literal["noMaterialChange", "notRelevant", "alreadyReported", "cooldown",
                 "classifierError", "notSalient", "alreadyAnnounced"]

VERBOSITY_THRESHOLDS = {"landmarks": 0.85, "notable": 0.60, "detailed": 0.35}
_LITTER = {"wrapper", "litter", "trash", "leaf", "leaves", "paper", "cup", "straw", "crumb", "crumbs"}
_SMALL_FOCUS = {"small", "floor", "objects", "items", "anything", "left", "dropped"}
_HIGH = {"entrance", "exit", "station", "platform", "gate", "elevator", "lift",
         "escalator", "subway", "terminal", "museum", "library", "hospital",
         "stairs", "curb", "barrier", "construction", "detour", "caution"}


@dataclass(frozen=True)
class Decision:
    kind: Literal["suppress", "escalateDigest", "escalateFrame"]
    reason: Reason | None = None
    confidence: float = 0.0
    change: float = 0.0
    relevance: float = 0.0
    landmark: str | None = None
    saliency: float = 0.0
    topics: tuple[str, ...] = ()


def _texts(d: FrameDigest) -> set[str]:
    return {x.name.lower() for x in d.labels} | {x.text.lower() for x in d.ocr_text}


def _tokens(s: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", s.lower()))


def _hit_rate(gained: set[str], phrases: list[str]) -> float:
    if not phrases:
        return 0.0
    pool: set[str] = set()
    for g in gained:
        pool |= _tokens(g)
    return sum(1 for p in phrases if _tokens(p) & pool or p.lower() in gained) / len(phrases)


_GATE = re.compile(r"\b([a-z])\s?-?\s?(\d{1,3})\b", re.I)


def _gates(texts: set[str]) -> set[str]:
    out: set[str] = set()
    for t in texts:
        out |= {f"{a.upper()}{b}" for a, b in _GATE.findall(t)}
    return out


def _item_score(item: str, is_ocr: bool, focus: list[str], exclusions: list[str]) -> float:
    """Task-conditioned saliency of one gained item (CLS-13/17).
    Mirrored line-for-line in Classifier.swift."""
    tokens = _tokens(item)
    if any(_tokens(e) & tokens for e in exclusions):
        return 0.0
    focus_tokens: set[str] = set()
    for f in focus:
        focus_tokens |= _tokens(f)
    if tokens & _LITTER:
        # Beneath notice on a stroll; the whole point of a floor check.
        return 0.85 if focus_tokens & _SMALL_FOCUS else 0.05
    if tokens & _HIGH:
        score = 0.90
    elif is_ocr:
        score = 0.80  # readable sign text is inherently reportable
    elif "person" in tokens or "people" in tokens:
        score = 0.15
    elif tokens & {"car", "bus", "train", "vehicle", "truck"}:
        score = 0.45
    elif "building" in tokens:
        score = 0.55
    elif tokens & {"sign", "store", "shop", "restaurant", "cafe", "storefront"}:
        score = 0.75
    else:
        score = 0.40
    focused = bool(focus_tokens & tokens) or (
        ("people" in focus_tokens or "person" in focus_tokens)
        and bool(tokens & {"person", "people", "crowd"}))
    if focused:
        score = max(score, 0.70)
    elif focus_tokens:
        score -= 0.10
    return max(0.0, min(1.0, score))


def saliency(digest, gained, goal, announced=frozenset()):
    """(score, topics) over gained items not already announced."""
    is_ocr = {x.text.lower(): True for x in digest.ocr_text}
    for x in digest.labels:
        is_ocr.setdefault(x.name.lower(), False)
    scored = [(item, _item_score(item, is_ocr.get(item, False), goal.targets, goal.exclusions))
              for item in sorted(gained - set(announced))]
    threshold = VERBOSITY_THRESHOLDS[goal.verbosity]
    topics = tuple(item for item, s in scored if s >= threshold)
    return (max((s for _, s in scored), default=0.0), topics)


def evaluate(digest, window, goal, *, last_callout=None, since_escalation=None,
             reported=frozenset(), announced=frozenset(), cooldown_s=COOLDOWN_S) -> Decision:
    try:
        return _run(digest, window, goal, last_callout, since_escalation, reported,
                    announced, cooldown_s)
    except Exception:  # CLS-11: fail closed
        return Decision("suppress", "classifierError")


def _run(digest, window, goal, last_callout, since, reported, announced, cooldown_s):
    now = _texts(digest)
    seen: set[str] = set()
    for past in window:
        seen |= _texts(past)
    gained, lost = now - seen, seen - now
    change = min(1.0, 0.5 * digest.scene_change.pixel_diff
                 + 0.25 * min(1.0, len(gained) / 3) + 0.25 * min(1.0, len(lost) / 3))

    landmark = None
    if goal.progress_landmarks:
        fresh = _gates(now) - _gates(seen) - set(reported) - _gates(set(goal.targets))
        if fresh:
            landmark = sorted(fresh)[0]

    relevance = max(0.0, min(1.0, _hit_rate(gained, goal.targets)
                             - 0.5 * _hit_rate(gained, goal.exclusions)))
    if landmark:
        relevance = max(relevance, RELEVANCE_THRESHOLD)

    if goal.kind == "describe":
        sal, topics = saliency(digest, gained, goal, announced)
        kw = dict(change=change, relevance=sal, saliency=sal, topics=topics)
        if since is not None and since < cooldown_s and change < MAJOR_CHANGE:
            return Decision("suppress", "cooldown", **kw)
        if gained and not (gained - set(announced)):
            return Decision("suppress", "alreadyAnnounced", **kw)
        if change < CHANGE_THRESHOLD:
            return Decision("suppress", "noMaterialChange", **kw)
        if sal < VERBOSITY_THRESHOLDS[goal.verbosity]:
            return Decision("suppress", "notSalient", **kw)
        kind = "escalateFrame" if not topics and change >= MAJOR_CHANGE else "escalateDigest"
        return Decision(kind, confidence=sal, **kw)

    if since is not None and since < cooldown_s and change < MAJOR_CHANGE:
        return Decision("suppress", "cooldown", change=change, relevance=relevance)
    if last_callout and gained and all(g in last_callout.lower() for g in gained):
        return Decision("suppress", "alreadyReported", change=change, relevance=relevance)
    if change < CHANGE_THRESHOLD:
        return Decision("suppress", "noMaterialChange", change=change, relevance=relevance)
    if relevance < RELEVANCE_THRESHOLD:
        return Decision("suppress", "notRelevant", change=change, relevance=relevance)
    kind = "escalateFrame" if not gained and change >= MAJOR_CHANGE else "escalateDigest"
    return Decision(kind, confidence=relevance, change=change, relevance=relevance,
                    landmark=landmark)
