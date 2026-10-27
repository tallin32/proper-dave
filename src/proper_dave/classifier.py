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

Reason = Literal["noMaterialChange", "notRelevant", "alreadyReported", "cooldown", "classifierError"]


@dataclass(frozen=True)
class Decision:
    kind: Literal["suppress", "escalateDigest", "escalateFrame"]
    reason: Reason | None = None
    confidence: float = 0.0
    change: float = 0.0
    relevance: float = 0.0
    landmark: str | None = None


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


def evaluate(digest, window, goal, *, last_callout=None, since_escalation=None,
             reported=frozenset(), cooldown_s=COOLDOWN_S) -> Decision:
    try:
        return _run(digest, window, goal, last_callout, since_escalation, reported, cooldown_s)
    except Exception:  # CLS-11: fail closed
        return Decision("suppress", "classifierError")


def _run(digest, window, goal, last_callout, since, reported, cooldown_s):
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
