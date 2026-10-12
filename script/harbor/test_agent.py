"""Adapter lifecycle tests; run with the pinned Harbor Python environment."""

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
            if outcome is not None:
                (logs / "result.json").write_text(json.dumps({"outcome": outcome}))
            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec",
                          AsyncMock(return_value=process)):
                try:
                    await agent.run("Repair the fixture", object(), context)
                finally:
                    bridge.close.assert_awaited_once()
            return context.metadata

    async def test_needs_user_preserves_metadata_and_allows_verification(self):
        self.assertEqual(await self.run_status(2, "needs_user"),
                         {"sumika": {"outcome": "needs_user"}})

    async def test_runner_failures_and_mismatched_exit_two_remain_errors(self):
        for status, outcome in ((1, "failed"), (124, "timed_out"),
                                (2, "completed"), (2, None)):
            with self.subTest(status=status, outcome=outcome), self.assertRaises(RuntimeError):
                await self.run_status(status, outcome)


if __name__ == "__main__":
    unittest.main()
