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
import weakref

from harbor.agents.base import BaseAgent
from harbor.agents.capabilities import AgentCapabilities
from harbor.models.task.config import TaskConfig
from harbor.models.trial.config import TrialConfig

from script.harbor.bridge import SandboxBridge, exec_diagnostics, web_access_enabled
from script.harbor.evidence import capture_environment, capture_legacy_artifacts, validate_workspace_root, write_json
from script.harbor.trajectory import export_trajectory


class SumikaAgent(BaseAgent):
    capabilities = AgentCapabilities(atif=True, resume=True)
    # Harbor's END hook closes workers even when reward gating skips the next resume.
    _live_workers = weakref.WeakValueDictionary()

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
        self._task_config = None
        self._trial_config = None
        self._step_index = 0
        self._worker = None
        self._worker_policy = None
        self._worker_turn_id = None

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
            task = TaskConfig.model_validate_toml((self.logs_dir.parent / "provenance/task/task.toml").read_text())
            if not task.artifacts and not (task.steps and all(step.artifacts for step in task.steps)):
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
        await self._run_checkpoint(instruction, environment, context, resume=False)

    async def resume(self, instruction, environment, context):
        await self._run_checkpoint(instruction, environment, context, resume=True)

    async def _run_checkpoint(self, instruction, environment, context, *, resume):
        if self.workspace_root is None:
            raise ValueError("Task working directory has not been resolved by setup.")
        if self._task_config is None:
            self._task_config = TaskConfig.model_validate_toml(
                (self.logs_dir.parent / "provenance/task/task.toml").read_text())
            self._trial_config = TrialConfig.model_validate_json((self.logs_dir.parent / "config.json").read_text())
        task = self._task_config
        config = self._trial_config
        steps = task.steps or []
        persistent = config.agent.resume_trajectory and len(steps) > 1
        if resume and (not persistent or self._worker is None):
            raise ValueError("Resume requires an active multi-checkpoint worker and --resume-trajectory.")
        if persistent and bool(self._step_index) != resume:
            raise ValueError("Use resume() to continue the active checkpoint worker.")
        step = steps[self._step_index] if self._step_index < len(steps) else None
        if task.steps and step is None:
            raise ValueError("No remaining Harbor checkpoint.")
        default_timeout = step.agent.timeout_sec if step and step.agent.timeout_sec is not None else task.agent.timeout_sec
        timeout = config.agent.override_timeout_sec or default_timeout
        multiplier = config.agent_timeout_multiplier
        if multiplier is None:
            multiplier = config.timeout_multiplier
        # Validate Harbor 0.24.0's budget without starting a competing timer.
        if timeout is not None:
            timeout = min(timeout, config.agent.max_timeout_sec or math.inf) * multiplier
        if timeout is None or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("Sumika requires a finite positive Harbor agent timeout.")
        policy = environment.network_policy.model_dump(mode="json")
        if persistent and self._worker_policy is not None and policy != self._worker_policy:
            await self._stop_worker()
            raise ValueError("Resumed checkpoints must keep the same network policy.")
        if resume:
            for name in ("trajectory.json", "trajectory-error.json", "artifact-error.json"):
                (self.logs_dir / name).unlink(missing_ok=True)
        self._step_index += 1
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        if step is not None:
            await capture_environment(environment, self.logs_dir)
        prompt = self.logs_dir / "instruction.md"
        prompt.write_text(instruction, encoding="utf-8")
        if web_access_enabled(environment.network_policy):
            await self._ensure_worker_python(environment, require_web_certificates=True)
        if not persistent or self.bridge is None:
            self.bridge = SandboxBridge(environment, self.workspace_root)
        process = None
        completed = False
        acknowledged = False
        try:
            if not persistent or self._worker is None:
                await self.bridge.start()
            arguments = [
                str(self.binary), "--model-id", self.model_name,
                "--workspace-root", self.workspace_root, "--bridge-url", self.bridge.url,
                "--prompt-file", str(prompt.resolve()),
                "--output-dir", str(self.logs_dir.resolve()),
                "--timeout-seconds", "harbor",
                "--network-policy", environment.network_policy.model_dump_json(),
                *(["--reasoning-level", self.reasoning_effort] if self.reasoning_effort is not None else []),
            ]
            host_environment = os.environ.copy()
            host_environment["SUMIKA_HARBOR_TOKEN"] = self.bridge.token
            if persistent:
                if self._worker is None:
                    self._worker = await asyncio.create_subprocess_exec(
                        *arguments, "--worker", env=host_environment,
                        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.STDOUT, start_new_session=True, limit=4 * 1024 * 1024)
                    self._worker_policy = policy
                    self._live_workers[self.logs_dir.parent.resolve()] = self
                result = await self._worker_checkpoint(step.name, policy)
                acknowledged = True
                status = {"completed": 0, "needs_user": 2, "failed": 1,
                          "cancelled": 130, "timed_out": 124}.get(result.get("outcome"))
                if status is None:
                    raise RuntimeError("SumikaEval worker returned an unknown outcome.")
            else:
                with (self.logs_dir / "runner.log").open("wb") as output:
                    process = await asyncio.create_subprocess_exec(
                        *arguments, env=host_environment, stdout=output, stderr=asyncio.subprocess.STDOUT,
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
            completed = status == 0 and result is not None and result.get("finishTaskStatus") in (None, "done")
        finally:
            if persistent:
                if not completed or self._step_index == len(steps):
                    await self._stop_worker()
                else:
                    try:
                        await self.bridge.suspend()
                    except BaseException:
                        await self._stop_worker()
                        raise
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
                if persistent and not acknowledged:
                    raise ValueError("No current checkpoint acknowledgement; prior usage cannot be exported.")
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
            if not persistent:
                await self.bridge.close()
            if step is None:
                await capture_legacy_artifacts(environment, self.logs_dir, self.logger, self.workspace_root)
            else:
                await capture_legacy_artifacts(environment, self.logs_dir, self.logger, self.workspace_root,
                                               task_config=task, step_name=step.name)

    async def _worker_checkpoint(self, checkpoint_id, policy):
        process = self._worker
        if process.returncode is not None:
            raise RuntimeError("SumikaEval worker exited before the next checkpoint.")
        self.bridge.resume()
        request = {"checkpointID": checkpoint_id, "networkPolicy": policy}
        process.stdin.write((json.dumps(request) + "\n").encode())
        await process.stdin.drain()
        with (self.logs_dir / "runner.log").open("wb") as output:
            while line := await process.stdout.readline():
                output.write(line)
                output.flush()
                if not line.startswith(b"SUMIKA_EVAL_WORKER "):
                    continue
                response = json.loads(line.removeprefix(b"SUMIKA_EVAL_WORKER "))
                if not isinstance(response, dict) or response.get("checkpointID") != checkpoint_id:
                    raise RuntimeError("SumikaEval worker checkpoint response ID mismatch.")
                result = response.get("result")
                if (not isinstance(result, dict) or not isinstance(result.get("turnID"), str)
                        or not result["turnID"] or result["turnID"] == self._worker_turn_id):
                    raise RuntimeError("SumikaEval worker response has no current turn result.")
                retained = json.loads((self.logs_dir / "result.json").read_text())
                if result != retained:
                    raise RuntimeError("SumikaEval worker response differs from its retained result.")
                self._worker_turn_id = result["turnID"]
                return result
        raise RuntimeError("SumikaEval worker closed its output before checkpoint completion.")

    @classmethod
    async def close_trial_worker(cls, trial):
        agent = cls._live_workers.get(Path(trial).resolve())
        if agent is not None:
            await agent._stop_worker(cleanup_environment=False)

    async def _stop_worker(self, *, cleanup_environment=True):
        process, self._worker = self._worker, None
        self._live_workers.pop(self.logs_dir.parent.resolve(), None)
        try:
            if process is not None:
                if process.stdin is not None:
                    process.stdin.close()
                try:
                    await asyncio.wait_for(process.communicate(), timeout=5)
                except TimeoutError:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGTERM)
                    try:
                        await asyncio.wait_for(process.wait(), timeout=5)
                    except TimeoutError:
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        await process.wait()
        finally:
            if self.bridge is not None:
                bridge, self.bridge = self.bridge, None
                await bridge.close(cleanup_environment=cleanup_environment)
