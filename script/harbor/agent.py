"""Harbor 0.24.0 adapter for the native SumikaEval executable."""

import asyncio
import contextlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import signal

from harbor.agents.base import BaseAgent
from harbor.agents.capabilities import AgentCapabilities

from script.harbor.bridge import SandboxBridge
from script.harbor.evidence import capture_environment, capture_legacy_artifacts, write_json
from script.harbor.trajectory import export_trajectory


class SumikaAgent(BaseAgent):
    capabilities = AgentCapabilities(atif=True)

    def __init__(self, *args, binary, timeout_seconds=600, **kwargs):
        super().__init__(*args, **kwargs)
        if version("harbor") != "0.24.0":
            raise ValueError("This adapter requires harbor==0.24.0.")
        self.binary = Path(binary).expanduser().resolve(strict=True)
        self.timeout = int(timeout_seconds)
        if not 1 <= self.timeout <= 3600:
            raise ValueError("timeout_seconds must be between 1 and 3600.")
        if not self.model_name:
            raise ValueError("Pass an already-installed Sumika model ID with --model.")
        self.bridge = None

    @staticmethod
    def name():
        return "sumika"

    def version(self):
        return "eval-1"

    async def setup(self, environment):
        if environment.type() != "docker":
            raise ValueError("The initial Sumika evaluation supports Docker tasks only.")
        if self.mcp_servers or self.skills_dir:
            raise ValueError("The initial Sumika evaluation does not inject MCP servers or skills.")
        location = await environment.exec("pwd", timeout_sec=10)
        if location.return_code or (location.stdout or "").strip() != "/app":
            raise ValueError("The initial Sumika evaluation requires the task working directory /app.")
        await capture_environment(environment, self.logs_dir)

    async def run(self, instruction, environment, context):
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        prompt = self.logs_dir / "instruction.md"
        prompt.write_text(instruction, encoding="utf-8")
        self.bridge = SandboxBridge(environment)
        process = None
        try:
            await self.bridge.start()
            host_environment = os.environ.copy()
            host_environment["SUMIKA_HARBOR_TOKEN"] = self.bridge.token
            with (self.logs_dir / "runner.log").open("wb") as output:
                process = await asyncio.create_subprocess_exec(
                    str(self.binary), "--model-id", self.model_name,
                    "--workspace-root", "/app", "--bridge-url", self.bridge.url,
                    "--prompt-file", str(prompt.resolve()),
                    "--output-dir", str(self.logs_dir.resolve()),
                    "--timeout-seconds", str(self.timeout),
                    env=host_environment, stdout=output, stderr=asyncio.subprocess.STDOUT,
                    start_new_session=True)
                async with asyncio.timeout(self.timeout + 15):
                    status = await process.wait()
            result_path = self.logs_dir / "result.json"
            result = None
            if result_path.exists():
                result = json.loads(result_path.read_text())
                context.metadata = {"sumika": result}
            needs_user = status == 2 and isinstance(result, dict) and result.get("outcome") == "needs_user"
            if status and not needs_user:
                raise RuntimeError(f"SumikaEval exited with status {status}; inspect runner.log/result.json.")
        finally:
            if process is not None and process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(process.wait(), timeout=5)
                except TimeoutError:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    await process.wait()
            try:
                trajectory = await asyncio.to_thread(
                    export_trajectory, self.logs_dir, self.model_name, self.version())
                if trajectory is not None and trajectory.final_metrics is not None:
                    metrics = trajectory.final_metrics
                    context.n_input_tokens = metrics.total_prompt_tokens
                    context.n_cache_tokens = metrics.total_cached_tokens
                    context.n_output_tokens = metrics.total_completion_tokens
            except Exception as error:
                self.logger.exception("Could not export Harbor trajectory")
                with contextlib.suppress(OSError):
                    await asyncio.to_thread(
                        write_json, self.logs_dir / "trajectory-error.json", {"error": str(error)})
            await self.bridge.close()
            await capture_legacy_artifacts(environment, self.logs_dir, self.logger)
