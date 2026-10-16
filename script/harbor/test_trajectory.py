"""ATIF projection tests using the native session and trace serialization shapes."""

import copy
import json
import tempfile
import unittest
from pathlib import Path

try:
    from harbor.models.trajectories import Trajectory
    from script.harbor.trajectory import build_trajectory, export_trajectory
except ModuleNotFoundError as error:
    if not error.name.startswith("harbor"):
        raise
    Trajectory = None


def message(kind, content, identifier, **fields):
    return {"kind": kind, "payload": {"id": identifier, "content": content, **fields}}


def assistant(content="", identifier="assistant", **fields):
    return message("assistantMessage", content, identifier, deliveryStatus="complete", **fields)


def tool(identifier="call", name="run_command", state="completed", **arguments):
    return {
        "kind": "tool",
        "payload": {
            "request": {"raw": {"id": identifier, "toolName": name, "arguments": arguments, "createdAt": 1}},
            "state": {
                "kind": state,
                "payload": {
                    "kind": "runCommand",
                    "payload": {
                        "exitCode": 1 if state == "failed" else 0,
                        "stdout": {"text": "output", "truncated": False},
                        "stderr": {"text": "AssertionError" if state == "failed" else ""},
                    },
                },
            },
            "modelFollowUpNotice": "Use the result.",
        },
    }


def session(*items):
    return {
        "id": "session",
        "turns": [
            {
                "id": "turn",
                "createdAt": 0,
                "status": "completed",
                "items": [message("userMessage", "Repair", "user"), *items],
            }
        ],
    }


def generation(identifier="generation", prompt=100, cached=0, output=20, turn="turn"):
    common = {"kind": "turn_trace", "generationID": identifier, "turnID": turn, "timestamp": "2026-10-14T12:00:00Z"}
    return [
        {**common, "phase": "runtime_stream_start"},
        {"kind": "mlx_request", "id": identifier, "settings": {"effectiveReasoningSelection": "medium"}},
        {
            **common,
            "phase": "runtime_prefill",
            "fullPromptTokens": prompt,
            "promptTokens": prompt - cached,
            "reusedPromptTokens": cached,
            "cacheMode": "append_delta",
        },
        {"kind": "mlx_response", "id": identifier},
        {
            **common,
            "phase": "runtime_stream_end",
            "generatedTokenCount": output,
            "generatedTokenCountIsEstimate": False,
            "reasoningTokenCount": 5,
            "answerTokenCount": output - 5,
            "runtimeStreamOutcome": "tool_call_boundary",
        },
    ]


@unittest.skipIf(Trajectory is None, "Harbor is not installed in this Python interpreter")
class TrajectoryTests(unittest.TestCase):
    def build(self, value, rows):
        return build_trajectory(value, rows, "fixture-model", "eval-1")

    def test_batches_reasoning_failures_and_direct_summary_round_trip(self):
        value = session(
            assistant("\n\n", "assistant-1"),
            message("assistantThinking", "Check the test", "thinking", deliveryStatus="complete"),
            tool("read", "read_file", path="/app/test.py"),
            tool("test", state="failed", command="python test.py"),
            assistant("", "assistant-2"),
            tool("finish", "finish_task", status="blocked", summary="Test still fails"),
            assistant(
                "Test still fails",
                "summary",
                modelProjectionPolicy={
                    "kind": "override",
                    "content": "Delivered finish_task summary directly to the user.",
                },
            ),
        )
        before = copy.deepcopy(value)
        result = self.build(value, generation("first") + generation("second", 150, 120, 30))
        result = Trajectory.model_validate_json(result.model_dump_json(exclude_none=True))
        self.assertEqual(value, before)
        self.assertEqual([s.step_id for s in result.steps], [1, 2, 3, 4])
        self.assertEqual(result.steps[0].timestamp, "2001-01-01T00:00:00+00:00")
        first = result.steps[1]
        self.assertEqual(first.reasoning_content, "Check the test")
        self.assertEqual([t.tool_call_id for t in first.tool_calls], ["read", "test"])
        self.assertEqual([o.source_call_id for o in first.observation.results], ["read", "test"])
        failure = json.loads(first.observation.results[1].content)
        self.assertEqual(failure["kind"], "failed")
        self.assertEqual(failure["payload"]["payload"]["stderr"]["text"], "AssertionError")
        self.assertEqual(first.extra["generation_id"], "first")
        self.assertEqual(result.steps[2].extra["generation_id"], "second")
        self.assertEqual(result.steps[3].llm_call_count, 0)
        self.assertIsNone(result.steps[3].metrics)
        self.assertEqual(result.final_metrics.total_prompt_tokens, 250)
        self.assertEqual(result.final_metrics.total_cached_tokens, 120)
        self.assertEqual(result.final_metrics.total_completion_tokens, 50)
        self.assertIsNone(result.final_metrics.total_cost_usd)
        self.assertEqual(result.extra["issues"], [])

    def test_leaked_tool_protocol_remains_text(self):
        text = "<tool_call><function=run_command><parameter=command>echo hi</parameter></function></tool_call>"
        result = self.build(session(assistant(text)), generation())
        self.assertEqual(result.steps[1].message, text)
        self.assertIsNone(result.steps[1].tool_calls)
        self.assertIsNone(result.steps[1].observation)

    def test_nonexecuted_tool_states_are_preserved(self):
        for state in ("denied", "invalid", "awaitingApproval", "awaitingUserAnswer", "cancelled"):
            with self.subTest(state=state):
                record = tool(state=state)
                record["payload"]["state"] = {"kind": state}
                result = self.build(session(assistant(), record), generation())
                self.assertEqual(json.loads(result.steps[1].observation.results[0].content), {"kind": state})

    def test_incomplete_and_estimated_counts_stay_unknown(self):
        for change in ("missing_end", "estimated", "missing_cache"):
            with self.subTest(change=change):
                rows = generation()
                if change == "missing_end":
                    rows.pop()
                elif change == "estimated":
                    rows[-1]["generatedTokenCountIsEstimate"] = True
                else:
                    rows[2].pop("reusedPromptTokens")
                result = self.build(session(assistant()), rows)
                self.assertEqual(result.final_metrics.total_prompt_tokens, 100)
                if change == "missing_cache":
                    self.assertIsNone(result.final_metrics.total_cached_tokens)
                    self.assertEqual(result.final_metrics.total_completion_tokens, 20)
                else:
                    self.assertIsNone(result.final_metrics.total_completion_tokens)
                self.assertTrue(result.extra["issues"])

    def test_missing_or_misaligned_trace_does_not_guess_metrics(self):
        value = session(assistant(identifier="one"), assistant(identifier="two"))
        for rows in ([], generation(), generation() + generation("orphan", turn="other")):
            with self.subTest(rows=len(rows)):
                result = self.build(value, rows)
                self.assertIsNone(result.steps[1].metrics)
                self.assertIsNone(result.steps[2].metrics)
                self.assertIsNone(result.final_metrics.total_completion_tokens)
                self.assertTrue(result.extra["issues"])

    def test_trace_alignment_is_scoped_to_each_turn(self):
        value = session(assistant())
        second = copy.deepcopy(value["turns"][0])
        second["id"] = "second-turn"
        value["turns"].append(second)
        rows = generation("second", 200, turn="second-turn") + generation("first", 100)
        result = self.build(value, rows)
        self.assertEqual(result.steps[1].metrics.prompt_tokens, 100)
        self.assertEqual(result.steps[3].metrics.prompt_tokens, 200)

    def test_current_turn_projection_counts_only_the_resumed_checkpoint(self):
        value = session(assistant("Earlier work", "prior"), tool())
        current = copy.deepcopy(value["turns"][0])
        current["id"] = "current"
        current["items"] = [message("userMessage", "Next checkpoint", "next-user"), assistant("New work", "new")]
        value["turns"].append(current)
        before = copy.deepcopy(value)
        result = build_trajectory(
            value,
            generation("new-generation", 200, 150, 30, turn="current"),
            "fixture-model",
            "eval-1",
            turn_id="current",
        )
        self.assertEqual(value, before)
        self.assertEqual([step.message for step in result.steps], ["Next checkpoint", "New work"])
        self.assertEqual(result.extra["turn_id"], "current")
        self.assertEqual(result.extra["issues"], [])
        self.assertEqual(result.final_metrics.total_prompt_tokens, 200)
        self.assertEqual(result.final_metrics.total_cached_tokens, 150)
        self.assertEqual(result.final_metrics.total_completion_tokens, 30)

    def test_current_turn_projection_rejects_missing_reordered_duplicate_and_foreign_traces(self):
        value = session(assistant())
        current = copy.deepcopy(value["turns"][0])
        current["id"] = "current"
        value["turns"].append(current)
        rows = generation(turn="current")
        for turn_id in ("absent", "turn"):
            with self.subTest(turn_id=turn_id), self.assertRaises(ValueError):
                build_trajectory(value, rows, "fixture-model", "eval-1", turn_id=turn_id)
        value["turns"].insert(0, copy.deepcopy(current))
        with self.assertRaises(ValueError):
            build_trajectory(value, rows, "fixture-model", "eval-1", turn_id="current")
        value["turns"].pop(0)
        value["turns"][-1]["items"].append(assistant("Untraced generation", "missing"))
        with self.assertRaisesRegex(ValueError, "does not match"):
            build_trajectory(value, rows, "fixture-model", "eval-1", turn_id="current")
        value["turns"][-1]["items"].pop()
        for changed in (
            [],
            rows[:-1],
            rows[:3] + rows[4:],
            rows[1:],
            rows + generation("old", turn="turn"),
            rows + [{"kind": "mlx_response", "id": "foreign"}],
            rows + [{"kind": "turn_trace", "phase": "runtime_memory", "turnID": "turn"}],
            [{**row, "turnID": "turn"} if row.get("kind") == "mlx_response" else row for row in rows],
        ):
            with self.subTest(rows=len(changed)), self.assertRaises(ValueError):
                build_trajectory(value, changed, "fixture-model", "eval-1", turn_id="current")

    def test_export_uses_native_result_turn_and_never_mutates_cumulative_session(self):
        value = session(assistant("Previous", "old"))
        current = copy.deepcopy(value["turns"][0])
        current["id"] = "current"
        current["items"] = [message("userMessage", "Continue", "next"), assistant("Current", "new")]
        value["turns"].append(current)
        with tempfile.TemporaryDirectory(prefix="sumika-resume-trajectory-") as directory:
            logs = Path(directory)
            (logs / "session.json").write_text(json.dumps(value))
            (logs / "mlx-trace.jsonl").write_text("\n".join(json.dumps(row) for row in generation(turn="current")))
            with self.assertRaisesRegex(ValueError, "requires a native result"):
                export_trajectory(logs, "fixture-model", "eval-1")
            (logs / "result.json").write_text(json.dumps({"turnID": "current"}))
            before = {path.name: path.read_bytes() for path in logs.iterdir()}
            result = export_trajectory(logs, "fixture-model", "eval-1")
            self.assertEqual([step.message for step in result.steps], ["Continue", "Current"])
            self.assertEqual(result.final_metrics.total_completion_tokens, 20)
            for name, data in before.items():
                self.assertEqual((logs / name).read_bytes(), data)
            (logs / "result.json").write_text("{}")
            with self.assertRaisesRegex(ValueError, "no current turn"):
                export_trajectory(logs, "fixture-model", "eval-1")

    def test_duplicate_or_invalid_metrics_are_rejected(self):
        for rows in (generation() + generation(), generation(prompt=-1), generation(cached=101)):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.build(session(assistant()), rows)

    def test_export_rejects_symlinked_current_turn_evidence(self):
        with tempfile.TemporaryDirectory(prefix="sumika-trajectory-links-") as directory:
            logs = Path(directory)
            for name, contents in (
                ("session.json", json.dumps(session(assistant()))),
                ("result.json", json.dumps({"turnID": "turn"})),
                ("mlx-trace.jsonl", "\n".join(json.dumps(row) for row in generation())),
            ):
                (logs / name).write_text(contents)
            for name in ("session.json", "result.json", "mlx-trace.jsonl"):
                path = logs / name
                retained = logs / "retained"
                path.rename(retained)
                path.symlink_to(retained)
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "regular file"):
                    export_trajectory(logs, "fixture-model", "eval-1")
                path.unlink()
                retained.rename(path)

    def test_export_is_atomic_and_keeps_native_files_unchanged(self):
        with tempfile.TemporaryDirectory(prefix="sumika-trajectory-test-") as directory:
            logs = Path(directory)
            self.assertIsNone(export_trajectory(logs, "fixture-model", "eval-1"))
            self.assertFalse((logs / "trajectory.json").exists())
            (logs / "session.json").write_text(json.dumps(session(assistant())), encoding="utf-8")
            (logs / "mlx-trace.jsonl").write_text("\n".join(json.dumps(r) for r in generation()), encoding="utf-8")
            before = {p.name: p.read_bytes() for p in logs.iterdir()}
            result = export_trajectory(logs, "fixture-model", "eval-1")
            self.assertEqual(Trajectory.model_validate_json((logs / "trajectory.json").read_text()), result)
            for name, data in before.items():
                self.assertEqual((logs / name).read_bytes(), data)
            self.assertFalse((logs / "trajectory.json.tmp").exists())
            exported = (logs / "trajectory.json").read_bytes()
            (logs / "mlx-trace.jsonl").write_text('{"kind":', encoding="utf-8")
            with self.assertRaises(ValueError):
                export_trajectory(logs, "fixture-model", "eval-1")
            self.assertEqual((logs / "trajectory.json").read_bytes(), exported)


if __name__ == "__main__":
    unittest.main()
