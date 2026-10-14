"""Adapter lifecycle tests; run with the pinned Harbor Python environment."""

import asyncio
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

try:
    from script.harbor.agent import SumikaAgent
except ModuleNotFoundError as error:
    if not error.name.startswith("harbor"):
        raise
    SumikaAgent = None


@unittest.skipIf(SumikaAgent is None, "Harbor is not installed in this Python interpreter")
class AgentLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def run_status(self, status, outcome):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            logs = Path(directory)
            agent = SumikaAgent(logs_dir=logs, model_name="fixture", binary=sys.executable)
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(return_value=status), returncode=status)
            context = SimpleNamespace(metadata=None)
            environment = object()
            if outcome is not None:
                (logs / "result.json").write_text(json.dumps({"outcome": outcome}))
            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec",
                          AsyncMock(return_value=process)), \
                    patch("script.harbor.agent.capture_legacy_artifacts", AsyncMock(
                        side_effect=lambda *_args: self.assertEqual(bridge.close.await_count, 1))) as capture:
                try:
                    await agent.run("Repair the fixture", environment, context)
                finally:
                    bridge.close.assert_awaited_once()
                    capture.assert_awaited_once_with(environment, logs, agent.logger)
            return context.metadata

    async def test_needs_user_preserves_metadata_and_allows_verification(self):
        self.assertEqual(await self.run_status(2, "needs_user"),
                         {"sumika": {"outcome": "needs_user"}})

    async def test_runner_failures_and_mismatched_exit_two_remain_errors(self):
        for status, outcome in ((1, "failed"), (124, "timed_out"),
                                (2, "completed"), (2, None)):
            with self.subTest(status=status, outcome=outcome), self.assertRaises(RuntimeError):
                await self.run_status(status, outcome)

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

    async def test_cancelled_runner_drains_before_artifact_capture(self):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(side_effect=asyncio.CancelledError), returncode=0)
            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                    patch("script.harbor.agent.capture_legacy_artifacts", AsyncMock(
                        side_effect=lambda *_args: self.assertEqual(bridge.close.await_count, 1))) as capture:
                with self.assertRaises(asyncio.CancelledError):
                    await agent.run("Repair", object(), SimpleNamespace(metadata=None))
            capture.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
