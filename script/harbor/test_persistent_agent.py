"""Persistent adapter tests use a real Python child, without Docker or MLX."""

import asyncio
import contextlib
import json
import os
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from script.harbor import test_agent as lifecycle_tests

NATIVE_STUB = """
import argparse
import json
import os
from pathlib import Path
import signal
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--worker", action="store_true")
parser.add_argument("--prompt-file", type=Path)
parser.add_argument("--output-dir", type=Path)
args, _ = parser.parse_known_args()
events = Path(__file__).with_suffix(".events.jsonl")
mode = Path(__file__).with_suffix(".mode").read_text()
turns = []

def record(kind, **fields):
    with events.open("a") as log:
        log.write(json.dumps({"kind": kind, "pid": os.getpid(), **fields}) + "\\n")

def terminate(number, _frame):
    record("signal", number=number)
    sys.exit(0)

signal.signal(signal.SIGTERM, terminate)
record("start", args=sys.argv[1:])

def respond(checkpoint, policy=None):
    instruction = args.prompt_file.read_text()
    record("request", checkpointID=checkpoint, instruction=instruction, networkPolicy=policy)
    if mode == "fail_second" and turns:
        record("validation_failure")
        print("Native checkpoint validation failed", flush=True)
        sys.exit(64)
    if mode == "block":
        while True:
            signal.pause()
    if mode == "eof":
        sys.exit(9)
    turns.append({"checkpointID": checkpoint, "instruction": instruction})
    result = {"modelID": "fixture", "outcome": "failed" if mode == "failed" else "completed",
              "turnID": checkpoint, "sessionID": "same-session", "pid": os.getpid()}
    if mode == "duplicate_turn" and len(turns) > 1:
        result["turnID"] = turns[0]["checkpointID"]
    if mode == "missing_turn":
        result.pop("turnID")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "result.json").write_text(json.dumps(result))
    (args.output_dir / "session.json").write_text(json.dumps({"turns": turns}))
    if args.worker:
        if mode == "retained_mismatch":
            result["sessionID"] = "different-session"
        payload = "{" if mode == "bad_json" else json.dumps({
            "checkpointID": "wrong-checkpoint" if mode == "wrong_id" else checkpoint,
            "result": result})
        print("SUMIKA_EVAL_WORKER " + payload, flush=True)

if args.worker:
    for line in sys.stdin:
        request = json.loads(line)
        respond(request["checkpointID"], request["networkPolicy"])
        if mode == "exit_after_ack":
            record("unexpected_exit")
            sys.exit(0)
    record("eof")
else:
    respond("one-shot")
"""


class StubBridge:
    def __init__(self):
        self.token = "test-token"
        self.url = "http://127.0.0.1:1"
        self.suspended = False
        self.closed = False
        self.start = AsyncMock()
        self.suspend = AsyncMock(side_effect=self._suspend)
        self.resume = Mock(side_effect=self._resume)
        self.close = AsyncMock(side_effect=self._close)

    async def _suspend(self):
        self.suspended = True

    def _resume(self):
        if self.closed:
            raise RuntimeError("Bridge closed")
        self.suspended = False

    async def _close(self, **_options):
        self.closed = True
        self.suspended = True


@unittest.skipIf(lifecycle_tests.SumikaAgent is None, "Harbor is not installed in this Python interpreter")
class PersistentAgentTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="sumika-persistent-agent-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name).resolve()
        self.cases = []
        self.bridges = []
        self.patches = contextlib.ExitStack()
        self.addCleanup(self.patches.close)
        launch = asyncio.create_subprocess_exec
        self.launch = self.patches.enter_context(
            patch("script.harbor.agent.asyncio.create_subprocess_exec", AsyncMock(side_effect=launch))
        )
        self.make_bridge = self.patches.enter_context(
            patch("script.harbor.agent.SandboxBridge", side_effect=self._bridge)
        )
        self.patches.enter_context(patch("script.harbor.agent.capture_environment", AsyncMock()))
        self.export = self.patches.enter_context(patch("script.harbor.agent.export_trajectory", return_value=None))
        self.capture = self.patches.enter_context(
            patch("script.harbor.agent.capture_legacy_artifacts", AsyncMock(side_effect=self._capture_while_idle))
        )

    async def asyncTearDown(self):
        for case in self.cases:
            await lifecycle_tests.SumikaAgent.close_trial_worker(case.logs.parent)

    def _bridge(self, *_args):
        bridge = StubBridge()
        self.bridges.append(bridge)
        return bridge

    async def _capture_while_idle(self, *_args, **_options):
        self.assertTrue(self.bridges[-1].suspended or self.bridges[-1].closed)

    def case(self, *, steps=2, resume=True, mode="normal"):
        root = self.directory / str(len(self.cases))
        logs = lifecycle_tests.AgentLifecycleTests.trial_logs(self, root, agent={"resume_trajectory": resume})
        with (root / "provenance/task/task.toml").open("a") as task:
            for index in range(steps):
                task.write(f'\n[[steps]]\nname = "checkpoint_{index + 1}"\nartifacts = ["/app"]\n')
        native = root / "native"
        native.write_text(f"#!{sys.executable}\n" + NATIVE_STUB)
        native.chmod(0o755)
        native.with_suffix(".mode").write_text(mode)
        agent = lifecycle_tests.SumikaAgent(logs_dir=logs, model_name="fixture", binary=native, reasoning_effort="low")
        agent.workspace_root = "/app"
        case = SimpleNamespace(
            agent=agent,
            logs=logs,
            native=native,
            environment=SimpleNamespace(network_policy=lifecycle_tests.NetworkPolicy(network_mode="no-network")),
        )
        self.cases.append(case)
        return case

    def events(self, case, kind=None):
        path = case.native.with_suffix(".events.jsonl")
        records = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [record for record in records if kind is None or record["kind"] == kind]

    async def wait_for_event(self, case, kind):
        async with asyncio.timeout(3):
            while not (records := self.events(case, kind)):
                await asyncio.sleep(0.01)
        return records[-1]

    def assert_exited(self, pid):
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def archive_checkpoint(self, case, *, preserve_agent=False):
        trial = object.__new__(lifecycle_tests.MultiStepTrial)
        trial.paths = lifecycle_tests.TrialPaths(trial_dir=case.logs.parent)
        trial.agent_env_paths = lifecycle_tests.EnvironmentPaths()
        trial._artifact_handler = lifecycle_tests.ArtifactHandler(artifacts=[], logger=case.agent.logger)
        trial.paths.mkdir()
        task = lifecycle_tests.TaskConfig.model_validate_toml(
            (case.logs.parent / "provenance/task/task.toml").read_text()
        )
        trial._archive_step_outputs(task.steps[0], preserve_agent=preserve_agent)
        return trial.paths

    async def test_two_checkpoints_reuse_one_process_bridge_and_canonical_session(self):
        case = self.case()
        first = lifecycle_tests.AgentContext()
        await case.agent.run("First instruction", case.environment, first)
        bridge = self.bridges[-1]
        self.assertTrue(bridge.suspended)
        self.assertFalse(bridge.closed)
        self.assertEqual(first.metadata["sumika"]["turnID"], "checkpoint_1")
        first_session = json.loads((case.logs / "session.json").read_text())
        self.assertEqual([turn["instruction"] for turn in first_session["turns"]], ["First instruction"])

        paths = self.archive_checkpoint(case)

        second = lifecycle_tests.AgentContext()
        await case.agent.resume("Second instruction", case.environment, second)
        sessions = json.loads((case.logs / "session.json").read_text())
        self.assertEqual(
            [turn["instruction"] for turn in sessions["turns"]], ["First instruction", "Second instruction"]
        )
        self.assertEqual(first.metadata["sumika"]["pid"], second.metadata["sumika"]["pid"])
        self.assertEqual(self.launch.await_count, 1)
        self.assertEqual(self.make_bridge.call_count, 1)
        bridge.start.assert_awaited_once()
        self.assertEqual(bridge.suspend.await_count, 1)
        self.assertTrue(bridge.closed)
        self.assertGreaterEqual(bridge.resume.call_count, 1)
        bridge.close.assert_awaited_once()
        self.assertEqual(self.capture.await_count, 2)
        self.assertEqual(self.export.call_count, 2)
        requests = self.events(case, "request")
        self.assertEqual([request["checkpointID"] for request in requests], ["checkpoint_1", "checkpoint_2"])
        self.assertTrue(
            all(
                request["networkPolicy"] == case.environment.network_policy.model_dump(mode="json")
                for request in requests
            )
        )
        self.assertEqual(len(self.events(case, "start")), 1)
        self.assertEqual(len(self.events(case, "eof")), 1)
        self.assert_exited(requests[0]["pid"])
        arguments = self.launch.call_args.args
        self.assertEqual(arguments.count("--worker"), 1)
        self.assertEqual(arguments[arguments.index("--prompt-file") + 1], str(case.logs / "instruction.md"))
        self.assertEqual(arguments[arguments.index("--output-dir") + 1], str(case.logs))
        self.assertEqual(arguments[arguments.index("--timeout-seconds") + 1], "harbor")
        self.assertEqual(arguments[arguments.index("--reasoning-level") + 1], "low")
        self.assertEqual(json.loads((paths.step_agent_dir("checkpoint_1") / "session.json").read_text()), first_session)

    async def test_early_checkpoint_failure_cannot_export_preserved_prior_usage(self):
        case = self.case(mode="fail_second")

        def export_first_checkpoint(*_args):
            (case.logs / "trajectory.json").write_text('{"checkpointID":"checkpoint_1"}')
            return SimpleNamespace(
                final_metrics=SimpleNamespace(
                    total_prompt_tokens=251, total_cached_tokens=127, total_completion_tokens=19
                )
            )

        self.export.side_effect = export_first_checkpoint
        first = lifecycle_tests.AgentContext()
        await case.agent.run("First instruction", case.environment, first)
        self.assertEqual((first.n_input_tokens, first.n_cache_tokens, first.n_output_tokens), (251, 127, 19))
        (case.logs / "mlx-trace.jsonl").write_text('{"kind":"turn_trace","turnID":"checkpoint_1"}\n')
        preserved = {
            name: (case.logs / name).read_bytes() for name in ("result.json", "session.json", "mlx-trace.jsonl")
        }
        prior_trajectory = (case.logs / "trajectory.json").read_bytes()
        paths = self.archive_checkpoint(case, preserve_agent=True)
        second = lifecycle_tests.AgentContext()
        with (
            self.assertLogs(case.agent.logger, level="ERROR"),
            self.assertRaisesRegex(RuntimeError, "closed its output"),
        ):
            await case.agent.resume("Invalid second instruction", case.environment, second)
        self.assertEqual(self.export.call_count, 1)
        self.assertTrue(second.is_empty())
        self.assertTrue(all((case.logs / name).read_bytes() == contents for name, contents in preserved.items()))
        self.assertFalse((case.logs / "trajectory.json").exists())
        self.assertEqual((paths.step_agent_dir("checkpoint_1") / "trajectory.json").read_bytes(), prior_trajectory)
        diagnostic = json.loads((case.logs / "trajectory-error.json").read_text())
        self.assertIn("No current checkpoint acknowledgement", diagnostic["error"])
        self.assertEqual(len(self.events(case, "validation_failure")), 1)
        self.assertEqual(self.capture.await_count, 2)
        self.assertEqual(self.launch.await_count, 1)
        self.assert_exited(self.events(case, "start")[0]["pid"])

    async def test_successful_resume_replaces_prior_trajectory_and_clears_old_diagnostics(self):
        case = self.case()

        def export_current_checkpoint(*_args):
            self.assertFalse((case.logs / "trajectory-error.json").exists())
            self.assertFalse((case.logs / "artifact-error.json").exists())
            result = json.loads((case.logs / "result.json").read_text())
            (case.logs / "trajectory.json").write_text(json.dumps({"turnID": result["turnID"]}))

        self.export.side_effect = export_current_checkpoint
        await case.agent.run("First instruction", case.environment, lifecycle_tests.AgentContext())
        for name in ("trajectory-error.json", "artifact-error.json"):
            (case.logs / name).write_text('{"error":"first-checkpoint-only"}')
        paths = self.archive_checkpoint(case, preserve_agent=True)
        archived = paths.step_agent_dir("checkpoint_1")
        snapshot = {path.relative_to(archived): path.read_bytes() for path in archived.rglob("*") if path.is_file()}
        second = lifecycle_tests.AgentContext()
        await case.agent.resume("Second instruction", case.environment, second)
        self.assertEqual(second.metadata["sumika"]["turnID"], "checkpoint_2")
        self.assertEqual(json.loads((case.logs / "trajectory.json").read_text()), {"turnID": "checkpoint_2"})
        self.assertFalse((case.logs / "trajectory-error.json").exists())
        self.assertFalse((case.logs / "artifact-error.json").exists())
        self.assertEqual(
            {path.relative_to(archived): path.read_bytes() for path in archived.rglob("*") if path.is_file()}, snapshot
        )
        self.assertEqual(self.export.call_count, 2)
        self.assertEqual(self.launch.await_count, 1)

    async def test_repeated_prior_turn_id_is_not_a_current_checkpoint_acknowledgement(self):
        case = self.case(mode="duplicate_turn")
        self.export.return_value = SimpleNamespace(
            final_metrics=SimpleNamespace(total_prompt_tokens=251, total_cached_tokens=127, total_completion_tokens=19)
        )
        await case.agent.run("First instruction", case.environment, lifecycle_tests.AgentContext())
        second = lifecycle_tests.AgentContext()
        with self.assertLogs(case.agent.logger, level="ERROR"), self.assertRaisesRegex(RuntimeError, "current turn"):
            await case.agent.resume("Second instruction", case.environment, second)
        self.assertEqual(json.loads((case.logs / "result.json").read_text())["turnID"], "checkpoint_1")
        self.assertEqual(self.export.call_count, 1)
        self.assertTrue(second.is_empty())
        self.assertEqual(
            [event["checkpointID"] for event in self.events(case, "request")], ["checkpoint_1", "checkpoint_2"]
        )
        self.assertEqual(self.launch.await_count, 1)
        self.assert_exited(self.events(case, "start")[0]["pid"])

    async def test_worker_requires_multiple_checkpoints_and_explicit_resume(self):
        for steps in (0, 1, 2):
            for resume in (False, True):
                with self.subTest(steps=steps, resume=resume):
                    case = self.case(steps=steps, resume=resume)
                    await case.agent.run("Instruction", case.environment, lifecycle_tests.AgentContext())
                    arguments = self.events(case, "start")[0]["args"]
                    self.assertEqual("--worker" in arguments, steps > 1 and resume)
                    await lifecycle_tests.SumikaAgent.close_trial_worker(case.logs.parent)
                    self.assert_exited(self.events(case, "start")[0]["pid"])

    async def test_resume_rejects_unconfigured_and_missing_active_worker(self):
        for resume in (False, True):
            with self.subTest(resume=resume):
                case = self.case(resume=resume)
                with self.assertRaises((RuntimeError, ValueError)):
                    await case.agent.resume("Unexpected resume", case.environment, lifecycle_tests.AgentContext())
                self.assertFalse(self.events(case))
        self.launch.assert_not_awaited()
        self.make_bridge.assert_not_called()

    async def test_protocol_errors_drain_and_do_not_restart_worker(self):
        for mode in ("wrong_id", "bad_json", "eof", "failed", "missing_turn", "retained_mismatch"):
            with self.subTest(mode=mode):
                case = self.case(mode=mode)
                before = self.launch.await_count
                diagnostics = (
                    self.assertLogs(case.agent.logger, level="ERROR") if mode != "failed" else contextlib.nullcontext()
                )
                with diagnostics, self.assertRaises((RuntimeError, ValueError)):
                    await case.agent.run("Failing instruction", case.environment, lifecycle_tests.AgentContext())
                self.assert_exited(self.events(case, "start")[0]["pid"])
                self.bridges[-1].close.assert_awaited_once()
                with self.assertRaises((RuntimeError, ValueError)):
                    await case.agent.resume("Cannot restart", case.environment, lifecycle_tests.AgentContext())
                self.assertEqual(self.launch.await_count, before + 1)

    async def test_worker_exit_between_checkpoints_does_not_spawn_replacement(self):
        case = self.case(mode="exit_after_ack")
        await case.agent.run("First instruction", case.environment, lifecycle_tests.AgentContext())
        await self.wait_for_event(case, "unexpected_exit")
        with self.assertLogs(case.agent.logger, level="ERROR"), self.assertRaises((RuntimeError, ValueError)):
            await case.agent.resume("Second instruction", case.environment, lifecycle_tests.AgentContext())
        self.assertEqual(self.launch.await_count, 1)
        self.assert_exited(self.events(case, "start")[0]["pid"])

    async def test_network_policy_change_fails_before_next_checkpoint_execution(self):
        case = self.case()
        await case.agent.run("First instruction", case.environment, lifecycle_tests.AgentContext())
        case.environment.network_policy = lifecycle_tests.NetworkPolicy(network_mode="public")
        with self.assertRaises((RuntimeError, ValueError)):
            await case.agent.resume("Changed policy", case.environment, lifecycle_tests.AgentContext())
        self.assertEqual(len(self.events(case, "request")), 1)
        self.assertEqual(self.launch.await_count, 1)
        self.assert_exited(self.events(case, "start")[0]["pid"])

    async def test_mid_checkpoint_cancellation_terminates_before_evidence_capture(self):
        case = self.case(mode="block")

        async def capture_after_exit(*_args, **_options):
            self.assert_exited(self.events(case, "start")[0]["pid"])
            self.assertTrue(self.bridges[-1].closed)

        self.capture.side_effect = capture_after_exit
        running = asyncio.create_task(case.agent.run("Wait", case.environment, lifecycle_tests.AgentContext()))
        try:
            await self.wait_for_event(case, "request")
            running.cancel()
            with self.assertLogs(case.agent.logger, level="ERROR"), self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(running, timeout=6)
        finally:
            if not running.done():
                running.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await running
        self.assertEqual(self.events(case, "signal")[0]["number"], signal.SIGTERM)
        self.assert_exited(self.events(case, "start")[0]["pid"])
        self.bridges[-1].close.assert_awaited_once()
        self.capture.assert_awaited_once()

    async def test_trial_end_hook_closes_worker_after_early_stop(self):
        from script.harbor.evidence import EvidencePlugin

        case = self.case()
        await case.agent.run("Only attempted checkpoint", case.environment, lifecycle_tests.AgentContext())
        self.assertTrue(self.bridges[-1].suspended)
        event = SimpleNamespace(
            config=SimpleNamespace(trials_dir=case.logs.parent.parent), trial_name=case.logs.parent.name
        )
        with patch("script.harbor.evidence.save_assessment", return_value={"complete": True}) as assess:
            await EvidencePlugin().ended(event)
            assess.assert_not_called()
        self.assert_exited(self.events(case, "start")[0]["pid"])
        self.assertEqual(len(self.events(case, "eof")), 1)
        self.bridges[-1].close.assert_awaited_once_with(cleanup_environment=False)


if __name__ == "__main__":
    unittest.main()
