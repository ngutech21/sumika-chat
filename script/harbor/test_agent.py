"""Adapter lifecycle tests; run with the pinned Harbor Python environment."""

import asyncio
import contextlib
import json
from pathlib import Path
import signal
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

try:
    from harbor.models.agent.context import AgentContext
    from script.harbor.agent import SumikaAgent
except ModuleNotFoundError as error:
    if not error.name.startswith("harbor"):
        raise
    SumikaAgent = None


@unittest.skipIf(SumikaAgent is None, "Harbor is not installed in this Python interpreter")
class AgentLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_setup_reuses_python_or_provisions_then_checks_as_task_user(self):
        for installed in (True, False):
            with self.subTest(installed=installed), tempfile.TemporaryDirectory() as directory:
                logs = Path(directory)
                agent = SumikaAgent(logs_dir=logs, model_name="fixture", binary=sys.executable)
                ready = SimpleNamespace(return_code=0, stdout="/usr/bin/python3\n3.12.3\n", stderr=None)
                missing = SimpleNamespace(return_code=127, stdout="python3: command not found", stderr=None)
                results = [SimpleNamespace(return_code=0, stdout="/app\n", stderr=None)]
                results += [ready] if installed else [missing, ready, ready]
                environment = SimpleNamespace(type=lambda: "docker", exec=AsyncMock(side_effect=results))
                with patch("script.harbor.agent.capture_environment", AsyncMock()) as capture:
                    await agent.setup(environment)
                capture.assert_awaited_once_with(environment, logs)
                calls = environment.exec.await_args_list
                self.assertNotIn("user", calls[1].kwargs)
                if not installed:
                    self.assertEqual(calls[2].kwargs, {"user": "root", "timeout_sec": 180})
                    self.assertIn("--no-install-recommends python3", calls[2].args[0])
                    self.assertNotIn("user", calls[3].kwargs)
                    self.assertEqual(calls[1].args, calls[3].args)
                self.assertEqual(len(calls), 2 if installed else 4)
                log = (logs / "setup.log").read_text()
                self.assertIn("3.12.3", log)
                self.assertEqual("installation" in log, not installed)

    async def test_setup_failure_retains_probe_and_install_diagnostics(self):
        missing = SimpleNamespace(return_code=127, stdout="python3: command not found", stderr=None)
        installed = SimpleNamespace(return_code=0, stdout="package installed", stderr=None)
        failures = [
            [SimpleNamespace(return_code=100, stdout="repository unavailable", stderr="permission denied")],
            [SimpleNamespace(return_code=1, stdout=None, stderr="apt-get is unavailable")],
            [TimeoutError("installation timed out")],
            [installed, SimpleNamespace(return_code=1, stdout="", stderr="Python import failed")],
        ]
        for results in failures:
            with self.subTest(results=results), tempfile.TemporaryDirectory() as directory:
                agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
                environment = SimpleNamespace(type=lambda: "docker", exec=AsyncMock(side_effect=[
                    SimpleNamespace(return_code=0, stdout="/app", stderr=None), missing, *results]))
                with patch("script.harbor.agent.capture_environment", AsyncMock()), \
                        self.assertRaisesRegex(RuntimeError, "Worker Python.*setup.log"):
                    await agent.setup(environment)
                log = (Path(directory) / "setup.log").read_text()
                self.assertIn("python3: command not found", log)
                for result in results:
                    if isinstance(result, Exception):
                        self.assertIn(str(result), log)
                    else:
                        for stream in (result.stdout, result.stderr):
                            if stream:
                                self.assertIn(stream, log)

    async def run_status(self, status, outcome, trajectory=None, export_error=None):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            logs = Path(directory)
            agent = SumikaAgent(logs_dir=logs, model_name="fixture", binary=sys.executable)
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(return_value=status), returncode=status)
            context = AgentContext()
            environment = object()
            if outcome is not None:
                (logs / "result.json").write_text(json.dumps({"outcome": outcome}))
            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec",
                          AsyncMock(return_value=process)), \
                    patch("script.harbor.agent.export_trajectory", return_value=trajectory,
                          side_effect=export_error) as export, \
                    patch("script.harbor.agent.capture_legacy_artifacts", AsyncMock(
                        side_effect=lambda *_args: self.assertEqual(bridge.close.await_count, 1))) as capture, \
                    self.assertLogs(agent.logger, level="ERROR") if export_error else contextlib.nullcontext():
                try:
                    await agent.run("Repair the fixture", environment, context)
                finally:
                    export.assert_called_once_with(logs, "fixture", agent.version())
                    bridge.close.assert_awaited_once()
                    capture.assert_awaited_once_with(environment, logs, agent.logger)
                    if export_error:
                        self.assertEqual(json.loads((logs / "trajectory-error.json").read_text()),
                                         {"error": str(export_error)})
                    if trajectory is not None:
                        metrics = trajectory.final_metrics
                        self.assertEqual((context.n_input_tokens, context.n_cache_tokens, context.n_output_tokens),
                                         (metrics.total_prompt_tokens, metrics.total_cached_tokens,
                                          metrics.total_completion_tokens))
                    else:
                        self.assertIsNone(context.n_input_tokens)
                        self.assertIsNone(context.n_cache_tokens)
                        self.assertIsNone(context.n_output_tokens)
            return context.metadata

    async def test_needs_user_preserves_metadata_and_allows_verification(self):
        self.assertEqual(await self.run_status(2, "needs_user"),
                         {"sumika": {"outcome": "needs_user"}})

    async def test_runner_failures_and_mismatched_exit_two_remain_errors(self):
        trajectory = SimpleNamespace(final_metrics=SimpleNamespace(
            total_prompt_tokens=25, total_cached_tokens=10, total_completion_tokens=7))
        for status, outcome in ((1, "failed"), (124, "timed_out"),
                                (2, "completed"), (2, None)):
            with self.subTest(status=status, outcome=outcome), self.assertRaises(RuntimeError):
                await self.run_status(status, outcome, trajectory=trajectory)

    async def test_trajectory_metrics_populate_context_with_native_metadata(self):
        for cached in (10, None):
            with self.subTest(cached=cached):
                trajectory = SimpleNamespace(final_metrics=SimpleNamespace(
                    total_prompt_tokens=25, total_cached_tokens=cached, total_completion_tokens=7))
                self.assertEqual(await self.run_status(0, "completed", trajectory=trajectory),
                                 {"sumika": {"outcome": "completed"}})

    async def test_export_error_preserves_native_outcome_and_cleanup(self):
        error = ValueError("invalid session")
        self.assertEqual(await self.run_status(0, "completed", export_error=error),
                         {"sumika": {"outcome": "completed"}})
        with self.assertRaisesRegex(RuntimeError, "SumikaEval exited with status 1"):
            await self.run_status(1, "failed", export_error=error)

    async def test_capture_failure_preserves_completed_native_result(self):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            logs = Path(directory)
            (logs / "task").mkdir()
            (logs / "task/task.toml").write_text("")
            (logs / "result.json").write_text(json.dumps({"outcome": "completed"}))
            agent = SumikaAgent(logs_dir=logs, model_name="fixture", binary=sys.executable)
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(return_value=0), returncode=0)
            context = SimpleNamespace(metadata=None)
            environment = SimpleNamespace(exec=AsyncMock(side_effect=PermissionError("probe denied")))
            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                    self.assertLogs(agent.logger, level="ERROR"):
                await agent.run("Repair", environment, context)
            self.assertEqual(context.metadata, {"sumika": {"outcome": "completed"}})
            self.assertEqual(json.loads((logs / "artifact-error.json").read_text())["error"], "probe denied")

    async def test_cancelled_runner_drains_before_export_and_artifact_capture(self):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(side_effect=[asyncio.CancelledError, 0]),
                                      returncode=None, pid=123)
            context = AgentContext()

            def export_after_drain(*_args):
                self.assertEqual(process.wait.await_count, 2)
                return SimpleNamespace(final_metrics=SimpleNamespace(
                    total_prompt_tokens=25, total_cached_tokens=None, total_completion_tokens=7))

            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                    patch("script.harbor.agent.os.killpg") as terminate, \
                    patch("script.harbor.agent.export_trajectory", side_effect=export_after_drain) as export, \
                    patch("script.harbor.agent.capture_legacy_artifacts", AsyncMock(
                        side_effect=lambda *_args: self.assertEqual(bridge.close.await_count, 1))) as capture:
                with self.assertRaises(asyncio.CancelledError):
                    await agent.run("Repair", object(), context)
            terminate.assert_called_once_with(123, signal.SIGTERM)
            export.assert_called_once()
            capture.assert_awaited_once()
            self.assertEqual(context.n_input_tokens, 25)
            self.assertIsNone(context.n_cache_tokens)
            self.assertEqual(context.n_output_tokens, 7)


if __name__ == "__main__":
    unittest.main()
