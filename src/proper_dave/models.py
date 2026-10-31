"""One wire contract for client, harness, and server (TRD-001 CAP-08).

On the wire, field names match the TRD Swift sketches (``sessionID``,
``ocrText``, ...) so digests replay identically across implementations.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class Wire(BaseModel):
    model_config = ConfigDict(populate_by_name=True)


class ScoredLabel(Wire):
    name: str
    confidence: float = 1.0


class OCRSpan(Wire):
    text: str
    confidence: float = 1.0


class ChangeMetrics(Wire):
    pixel_diff: float = Field(default=0.0, alias="pixelDiff")
    label_delta: float = Field(default=0.0, alias="labelDelta")


class FrameDigest(Wire):
    session_id: UUID = Field(alias="sessionID")
    sequence: int
    captured_at: datetime = Field(alias="capturedAt")
    source_id: str = Field(alias="sourceID")
    labels: list[ScoredLabel] = []
    ocr_text: list[OCRSpan] = Field(default=[], alias="ocrText")
    scene_change: ChangeMetrics = Field(default=ChangeMetrics(), alias="sceneChange")
    image_ref: str | None = Field(default=None, alias="imageRef")


class GoalContext(Wire):
    raw_text: str = Field(alias="rawText")
    # Additive /v1 fields (TRD-004): older payloads omit them and mean
    # exactly what they meant before describe goals existed.
    kind: Literal["watch", "question", "describe"] = "watch"
    verbosity: Literal["landmarks", "notable", "detailed"] = "notable"
    targets: list[str]
    exclusions: list[str] = []
    progress_landmarks: str | None = Field(default=None, alias="progressLandmarks")
    expires_at: datetime | None = Field(default=None, alias="expiresAt")


class EscalationRequest(Wire):
    session_id: UUID = Field(alias="sessionID")
    goal: GoalContext
    digest: FrameDigest
    recent_digests: list[FrameDigest] = Field(default=[], alias="recentDigests")
    image: str | None = None
    last_callout: str | None = Field(default=None, alias="lastCallout")
    skill_id: str | None = Field(default=None, alias="skillID")


class CalloutResult(Wire):
    kind: Literal["callout", "noCallout"]
    text: str | None = None
    relevance: float | None = None
    reason: str | None = None

    @classmethod
    def callout(cls, text: str, relevance: float = 1.0) -> "CalloutResult":
        return cls(kind="callout", text=text, relevance=relevance)

    @classmethod
    def no_callout(cls, reason: str) -> "CalloutResult":
        return cls(kind="noCallout", reason=reason)


class ParseGoalRequest(Wire):
    raw_text: str = Field(alias="rawText")


class RefineGoalRequest(Wire):
    goal: GoalContext
    refinement: str


class ErrorResponse(Wire):
    error: dict
