"""Harbor 0.24.0 adapter for the native SumikaEval executable."""

import asyncio
import contextlib
from importlib.metadata import version
import json
import math
import os
from pathlib import Path
import shlex
import signal
import tomllib

from harbor.agents.base import BaseAgent
from harbor.agents.capabilities import AgentCapabilities
from harbor.models.task.config import TaskConfig
from harbor.models.trial.config import TrialConfig

from script.harbor.bridge import SandboxBridge, exec_diagnostics, web_access_enabled
from script.harbor.evidence import capture_environment, capture_legacy_artifacts, validate_workspace_root, write_json
from script.harbor.trajectory import export_trajectory


class SumikaAgent(BaseAgent):
    capabilities = AgentCapabilities(atif=True)

    def __init__(self, *args, binary, reasoning_effort=None, **kwargs):
        if "reasoning_level" in kwargs:
            raise ValueError("Use reasoning_effort instead of reasoning_level.")
        if "timeout_seconds" in kwargs:
            raise ValueError("Use Harbor's agent timeout settings instead of timeout_seconds.")
        super().__init__(*args, **kwargs)
        if version("harbor") != "0.24.0":
            raise ValueError("This adapter requires harbor==0.24.0.")
        self.binary = Path(binary).expanduser().resolve(strict=True)
        if reasoning_effort is not None and reasoning_effort not in ("low", "medium", "xhigh"):
            raise ValueError("reasoning_effort must be low, medium, or xhigh.")
        self.reasoning_effort = reasoning_effort
        if not self.model_name:
            raise ValueError("Pass an already-installed Sumika model ID with --model.")
        self.bridge = None
        self.workspace_root = None

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
        location = await environment.exec("pwd -P", timeout_sec=10)
        if location.return_code:
            raise ValueError(f"Cannot resolve the task working directory: {exec_diagnostics(location)}")
        workspace_root = validate_workspace_root((location.stdout or "").removesuffix("\n"))
        if workspace_root == "/":
            task = tomllib.loads((self.logs_dir / "task/task.toml").read_text(encoding="utf-8"))
            if not task.get("artifacts"):
                raise ValueError("Tasks working in / must declare artifacts; capturing the container root is unsupported.")
        await capture_environment(environment, self.logs_dir)
        await self._ensure_worker_python(environment)
        self.workspace_root = workspace_root

    async def _ensure_worker_python(self, environment, require_web_certificates=False):
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        with (self.logs_dir / "setup.log").open("a", encoding="utf-8") as log:
            async def execute(label, command, **options):
                log.write(f"{label}\n$ {command}\n")
                log.flush()
                try:
                    result = await environment.exec(command, **options)
                except Exception as error:
                    log.write(f"{type(error).__name__}: {error}\n")
                    log.flush()
                    raise RuntimeError(f"Worker Python {label} failed: {error}; inspect agent/setup.log.") from error
                log.write(exec_diagnostics(result) + "\n\n")
                log.flush()
                return result

            certificate_check = (
                "\ncontext = ssl.create_default_context()\n"
                "paths = ssl.get_default_verify_paths()\n"
                "directories = (os.environ.get(paths.openssl_capath_env, paths.openssl_capath) or '').split(os.pathsep)\n"
                "if not context.cert_store_stats()['x509']:\n"
                "    for directory in filter(None, directories):\n"
                "        for certificate in Path(directory).glob('[0-9a-f]' * 8 + '.0'):\n"
                "            try:\n"
                "                context.load_verify_locations(cafile=str(certificate))\n"
                "            except (OSError, ssl.SSLError):\n"
                "                continue\n"
                "            if context.cert_store_stats()['x509']:\n"
                "                break\n"
                "        if context.cert_store_stats()['x509']:\n"
                "            break\n"
                "if not context.cert_store_stats()['x509']:\n"
                "    sys.exit('Web tools require trusted CA certificates')\n"
                if require_web_certificates else "")
            probe = shlex.join(["python3", "-c",
                "import ctypes, fcntl, http.client, ipaddress, json, os, selectors, socket, ssl, subprocess, sys\n"
                "from pathlib import Path\n"
                "if sys.version_info < (3, 7):\n"
                "    sys.exit('Worker requires Python 3.7 or newer')\n"
                "print(sys.executable)\nprint(sys.version)" + certificate_check])
            result = await execute("probe", probe, timeout_sec=10)
            if result.return_code == 0:
                return
            # shortcut: provision apt-based images; add another installer when a task needs it.
            install = (
                "if ! command -v apt-get >/dev/null 2>&1; then "
                "echo 'Cannot provision worker Python: apt-get is unavailable' >&2; exit 1; fi; "
                "apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=30 "
                "-o Acquire::https::Timeout=30 update && "
                "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 ca-certificates")
            result = await execute("installation", install, user="root", timeout_sec=180)
            if result.return_code == 0:
                result = await execute("verification", probe, timeout_sec=10)
            if result.return_code:
                raise RuntimeError("Worker Python prerequisite could not be prepared; inspect agent/setup.log.\n"
                                   + exec_diagnostics(result))

    async def run(self, instruction, environment, context):
        if self.workspace_root is None:
            raise ValueError("Task working directory has not been resolved by setup.")
        config = TrialConfig.model_validate_json((self.logs_dir.parent / "config.json").read_text())
        task = TaskConfig.model_validate_toml((self.logs_dir / "task/task.toml").read_text())
        timeout = config.agent.override_timeout_sec or task.agent.timeout_sec
        multiplier = config.agent_timeout_multiplier
        if multiplier is None:
            multiplier = config.timeout_multiplier
        # Validate Harbor 0.24.0's budget without starting a competing timer.
        if timeout is not None:
            timeout = min(timeout, config.agent.max_timeout_sec or math.inf) * multiplier
        if timeout is None or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("Sumika requires a finite positive Harbor agent timeout.")
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        prompt = self.logs_dir / "instruction.md"
        prompt.write_text(instruction, encoding="utf-8")
        if web_access_enabled(environment.network_policy):
            await self._ensure_worker_python(environment, require_web_certificates=True)
        self.bridge = SandboxBridge(environment, self.workspace_root)
        process = None
        try:
            await self.bridge.start()
            host_environment = os.environ.copy()
            host_environment["SUMIKA_HARBOR_TOKEN"] = self.bridge.token
            with (self.logs_dir / "runner.log").open("wb") as output:
                process = await asyncio.create_subprocess_exec(
                    str(self.binary), "--model-id", self.model_name,
                    "--workspace-root", self.workspace_root, "--bridge-url", self.bridge.url,
                    "--prompt-file", str(prompt.resolve()),
                    "--output-dir", str(self.logs_dir.resolve()),
                    "--timeout-seconds", "harbor",
                    "--network-policy", environment.network_policy.model_dump_json(),
                    *(["--reasoning-level", self.reasoning_effort] if self.reasoning_effort is not None else []),
                    env=host_environment, stdout=output, stderr=asyncio.subprocess.STDOUT,
                    start_new_session=True)
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
            await capture_legacy_artifacts(environment, self.logs_dir, self.logger, self.workspace_root)
