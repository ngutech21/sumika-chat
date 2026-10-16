"""Host-side validation for native output and retained evidence; never uploaded to tasks."""

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, JsonValue


class NativeResult(BaseModel):
    # Preserve additional native metadata while validating the fields the adapter consumes.
    model_config = ConfigDict(strict=True, extra="allow")

    modelID: str = Field(min_length=1)
    outcome: Literal["completed", "needs_user", "failed", "cancelled", "timed_out"]
    turnID: Annotated[str, Field(min_length=1)] | None = None
    finishTaskStatus: Literal["done", "blocked", "needs_user"] | None = None
    errorMessage: str | None = None
    maxToolLoopIterations: Annotated[int, Field(ge=0)] | None = None
    contextTokenLimit: Annotated[int, Field(gt=0)] | None = None


class CheckpointResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    checkpointID: str = Field(min_length=1)
    result: NativeResult


class CompletenessReport(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: int = Field(ge=1, le=1)
    complete: bool
    issues: list[str]
    files: dict[str, dict[str, JsonValue]]
    trace_requests: int = Field(default=0, ge=0)
    trace_clipped_rows: int = Field(default=0, ge=0)
    steps: list[dict[str, JsonValue]] | None = None
