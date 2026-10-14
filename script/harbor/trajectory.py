"""Derive Harbor ATIF from Sumika's canonical session and existing MLX trace."""

from collections import defaultdict
from datetime import datetime, timedelta, timezone
import json

from harbor.models.trajectories import Trajectory

from script.harbor.evidence import write_json


def export_trajectory(logs_dir, model_name, agent_version):
    session_path = logs_dir / "session.json"
    if not session_path.exists():
        return None
    session = json.loads(session_path.read_text(encoding="utf-8"))
    trace_path = logs_dir / "mlx-trace.jsonl"
    rows = []
    if trace_path.exists():
        with trace_path.open(encoding="utf-8") as trace:
            rows = [json.loads(line) for line in trace if line.strip()]
    trajectory = build_trajectory(session, rows, model_name, agent_version)
    write_json(logs_dir / "trajectory.json", trajectory.to_json_dict())
    return trajectory


def _timestamp(value):
    if value is None:
        return None
    # JSONEncoder's default Date representation uses the 2001 reference epoch.
    return (datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=value)).isoformat()


def _direct_summary(message):
    return message.get("modelProjectionPolicy") == {
        "kind": "override", "content": "Delivered finish_task summary directly to the user."
    }


def _trace_generations(rows):
    generations = {}
    starts = defaultdict(list)
    for row in rows:
        if row.get("kind") == "turn_trace" and row.get("phase") in (
                "runtime_stream_start", "runtime_prefill", "runtime_stream_end"):
            identifier = row["generationID"]
            generation = generations.setdefault(identifier, {})
            phase = row["phase"]
            if phase in generation:
                raise ValueError(f"Duplicate {phase} for generation {identifier}")
            generation[phase] = row
            if phase == "runtime_stream_start":
                starts[row["turnID"]].append(identifier)
        elif row.get("kind") == "mlx_request":
            generation = generations.setdefault(row["id"], {})
            if "request" in generation:
                raise ValueError(f"Duplicate model request {row['id']}")
            generation["request"] = row
    return generations, starts


def _token_count(row, key):
    value = row.get(key)
    if value is not None and (type(value) is not int or value < 0):
        raise ValueError(f"Invalid token count: {key}")
    return value


def _generation_fields(identifier, generation):
    start = generation["runtime_stream_start"]
    prefill = generation.get("runtime_prefill", {})
    end = generation.get("runtime_stream_end", {})
    request = generation.get("request", {})
    for row in (prefill, end):
        if row and row.get("turnID") != start["turnID"]:
            raise ValueError(f"Inconsistent turn for generation {identifier}")
    prompt = _token_count(prefill, "fullPromptTokens")
    cached = _token_count(prefill, "reusedPromptTokens")
    if prompt is not None and cached is not None and cached > prompt:
        raise ValueError(f"Cached tokens exceed prompt tokens for generation {identifier}")
    completion = _token_count(end, "generatedTokenCount")
    if end.get("generatedTokenCountIsEstimate") is not False:
        completion = None
    return {
        "timestamp": start.get("timestamp"),
        "reasoning_effort": request.get("settings", {}).get("effectiveReasoningSelection"),
        "metrics": {
            "prompt_tokens": prompt,
            "cached_tokens": cached,
            "completion_tokens": completion,
            "extra": {key: end[key] for key in (
                "durationMs", "reasoningTokenCount", "answerTokenCount",
                "tokensPerSecond", "generatedTokenCountIsEstimate"
            ) if key in end},
        },
        "extra": {
            "generation_id": identifier,
            "runtime_outcome": end.get("runtimeStreamOutcome"),
            "cache_mode": prefill.get("cacheMode"),
        },
    }


def build_trajectory(session, rows, model_name, agent_version):
    generations, starts = _trace_generations(rows)
    steps = []
    model_steps = []
    matched = set()
    issues = []
    for turn in session["turns"]:
        turn_id = turn["id"]
        turn_model_steps = []
        current = None
        for item in turn["items"]:
            payload = item["payload"]
            kind = item["kind"]
            if kind in ("userMessage", "assistantMessage"):
                is_agent = kind == "assistantMessage"
                direct = is_agent and _direct_summary(payload)
                current = {
                    "step_id": len(steps) + 1,
                    "source": "agent" if is_agent else "user",
                    "message": payload["content"],
                    "extra": {"turn_id": turn_id, "item_id": payload["id"],
                              "turn_status": turn["status"]},
                }
                if is_agent:
                    current["llm_call_count"] = 0 if direct else 1
                    current["extra"]["delivery_status"] = payload["deliveryStatus"]
                    current["extra"]["model_projection_policy"] = payload.get("modelProjectionPolicy")
                    if not direct:
                        turn_model_steps.append(current)
                else:
                    current["timestamp"] = _timestamp(turn.get("createdAt"))
                steps.append(current)
            elif kind == "assistantThinking":
                if not current or current["source"] != "agent" or not current["llm_call_count"]:
                    raise ValueError("Reasoning has no model-generated assistant message")
                current["reasoning_content"] = current.get("reasoning_content", "") + payload["content"]
                current["extra"]["reasoning_status"] = payload["deliveryStatus"]
            elif kind == "tool":
                if not current or current["source"] != "agent":
                    raise ValueError("Tool has no assistant message")
                raw = payload["request"]["raw"]
                current.setdefault("tool_calls", []).append({
                    "tool_call_id": raw["id"], "function_name": raw["toolName"],
                    "arguments": raw["arguments"],
                    "extra": {"created_at": _timestamp(raw.get("createdAt"))},
                })
                # Only persisted tool records are actions; never parse assistant text here.
                current.setdefault("observation", {"results": []})["results"].append({
                    "source_call_id": raw["id"],
                    "content": json.dumps(payload["state"], ensure_ascii=False, indent=2),
                    "extra": {key: payload[key] for key in (
                        "evaluation", "approvalSource", "modelFollowUpNotice"
                    ) if key in payload},
                })
            else:
                raise ValueError(f"Unsupported turn item: {kind}")

        identifiers = starts.get(turn_id, [])
        # Session items have no generation ID. Only align complete per-turn sequences.
        if len(identifiers) != len(turn_model_steps):
            issues.append(f"Unmatched model generations for turn {turn_id}; step metrics omitted.")
        else:
            for step, identifier in zip(turn_model_steps, identifiers):
                fields = _generation_fields(identifier, generations[identifier])
                step["extra"].update(fields.pop("extra"))
                step.update(fields)
                matched.add(identifier)
        model_steps.extend(turn_model_steps)

    if set(generations) != matched:
        issues.append("Trace contains missing or unmatched generation boundaries; totals omitted.")
    totals = {}
    for name, field in (("prompt", "prompt_tokens"), ("cached", "cached_tokens"),
                        ("completion", "completion_tokens")):
        counts = [step.get("metrics", {}).get(field) for step in model_steps]
        totals[f"total_{name}_tokens"] = (
            sum(counts) if counts and not issues and all(c is not None for c in counts) else None
        )
    if any(value is None for value in totals.values()):
        issues.append("Unavailable or estimated token counts are omitted, not treated as zero.")
    return Trajectory.model_validate({
        "schema_version": "ATIF-v1.8",
        "session_id": session["id"],
        "agent": {"name": "sumika", "version": agent_version, "model_name": model_name},
        "steps": steps,
        "final_metrics": {**totals, "total_steps": len(steps)},
        "notes": "Derived from session.json and mlx-trace.jsonl. Assistant steps are paired "
                 "with trace generations in order within each turn; direct finish_task summaries "
                 "are not model calls. Prompt tokens include cache hits; completion tokens include "
                 "reasoning and tool calls. Raw files remain authoritative.",
        "extra": {"issues": issues},
    })
