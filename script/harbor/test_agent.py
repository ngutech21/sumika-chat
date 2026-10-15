"""Adapter lifecycle tests; run with the pinned Harbor Python environment."""

import asyncio
import contextlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

try:
    from harbor.models.agent.context import AgentContext
    from harbor.models.task.config import NetworkPolicy, TaskConfig
    from harbor.models.trial.config import TrialConfig
    from harbor.viewer.trial_utils import reasoning_effort_from_config
    from script.harbor.agent import SumikaAgent
except ModuleNotFoundError as error:
    if not error.name.startswith("harbor"):
        raise
    SumikaAgent = None


@unittest.skipIf(SumikaAgent is None, "Harbor is not installed in this Python interpreter")
class AgentLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_setup_resolves_container_working_directory_without_overriding_it(self):
        for root in ("/app", "/workdir", "/workspace/project", "/work dir "):
            with self.subTest(root=root), tempfile.TemporaryDirectory() as directory:
                agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
                environment = SimpleNamespace(type=lambda: "docker", exec=AsyncMock(return_value=
                    SimpleNamespace(return_code=0, stdout=root + "\n", stderr=None)))
                with patch("script.harbor.agent.capture_environment", AsyncMock()), \
                        patch.object(agent, "_ensure_worker_python", AsyncMock()):
                    await agent.setup(environment)
                environment.exec.assert_awaited_once_with("pwd -P", timeout_sec=10)
                self.assertEqual(agent.workspace_root, root)

    async def test_invalid_working_directory_prevents_setup(self):
        for root in ("", "relative", "/app/../etc", "/app\n/other", "/app\x00", "//app", "/app/"):
            with self.subTest(root=root), tempfile.TemporaryDirectory() as directory:
                agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
                environment = SimpleNamespace(type=lambda: "docker", exec=AsyncMock(return_value=
                    SimpleNamespace(return_code=0, stdout=root + "\n", stderr=None)))
                with patch("script.harbor.agent.capture_environment", AsyncMock()) as capture, \
                        self.assertRaisesRegex(ValueError, "absolute container workspace"):
                    await agent.setup(environment)
                capture.assert_not_awaited()

    async def test_root_working_directory_requires_declared_artifacts(self):
        for declared in (False, True):
            with self.subTest(declared=declared), tempfile.TemporaryDirectory() as directory:
                logs = Path(directory)
                (logs / "task").mkdir()
                (logs / "task/task.toml").write_text('artifacts = ["/output/report.json"]' if declared else "")
                agent = SumikaAgent(logs_dir=logs, model_name="fixture", binary=sys.executable)
                environment = SimpleNamespace(type=lambda: "docker", exec=AsyncMock(return_value=
                    SimpleNamespace(return_code=0, stdout="/\n", stderr=None)))
                with patch("script.harbor.agent.capture_environment", AsyncMock()), \
                        patch.object(agent, "_ensure_worker_python", AsyncMock()) as prepare:
                    if declared:
                        await agent.setup(environment)
                        self.assertEqual(agent.workspace_root, "/")
                        prepare.assert_awaited_once()
                    else:
                        with self.assertRaisesRegex(ValueError, "must declare artifacts"):
                            await agent.setup(environment)
                        prepare.assert_not_awaited()
                        self.assertIsNone(agent.workspace_root)

    async def test_failed_directory_probe_keeps_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            environment = SimpleNamespace(type=lambda: "docker", exec=AsyncMock(return_value=
                SimpleNamespace(return_code=1, stdout="pwd: permission denied", stderr=None)))
            with self.assertRaisesRegex(ValueError, "pwd: permission denied"):
                await agent.setup(environment)

    async def test_run_requires_successful_directory_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            with self.assertRaisesRegex(ValueError, "not been resolved"):
                await agent.run("Repair", SimpleNamespace(), AgentContext())

    async def test_resolved_root_reaches_bridge_native_runner_and_capture(self):
        for root in ("/workdir", "/work dir "):
            with self.subTest(root=root):
                await self.run_status(0, "completed", workspace_root=root)

    async def test_web_prerequisite_accepts_directory_only_trust_store(self):
        certificates = ssl.create_default_context().get_ca_certs(binary_form=True)
        if not certificates or not shutil.which("openssl"):
            self.skipTest("Requires an existing trust root and OpenSSL")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            certificate = root / "root.pem"
            certificate.write_text(ssl.DER_cert_to_PEM_cert(certificates[0]))
            hashed = subprocess.check_output(
                ["openssl", "x509", "-in", str(certificate), "-subject_hash", "-noout"], text=True).strip()
            trust = root / "trust"
            trust.mkdir()
            (trust / (hashed + ".0")).symlink_to(certificate)
            empty = root / "empty"
            empty.mkdir()
            environment_variables = {**os.environ, "SSL_CERT_FILE": str(root / "missing.pem")}

            async def execute(command, **_options):
                self.assertNotIn("apt-get", command)
                process = await asyncio.create_subprocess_exec(
                    *shlex.split(command), env=environment_variables,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                stdout, stderr = await process.communicate()
                return SimpleNamespace(return_code=process.returncode, stdout=stdout.decode(), stderr=stderr.decode())

            for directories in (str(trust), os.pathsep.join((str(empty), str(trust))),
                                os.pathsep.join((str(trust), str(empty)))):
                with self.subTest(directories=directories):
                    environment_variables["SSL_CERT_DIR"] = directories
                    agent = SumikaAgent(logs_dir=root, model_name="fixture", binary=sys.executable)
                    environment = SimpleNamespace(exec=AsyncMock(side_effect=execute))
                    await agent._ensure_worker_python(environment, require_web_certificates=True)
                    self.assertEqual(environment.exec.await_count, 1)

    async def test_offline_interpreter_does_not_require_trust_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            environment = SimpleNamespace(exec=AsyncMock(return_value=SimpleNamespace(
                return_code=0, stdout="ready", stderr=None)))
            await agent._ensure_worker_python(environment)
            self.assertNotIn("cert_store_stats", environment.exec.call_args.args[0])
            self.assertEqual(environment.exec.await_count, 1)

    async def test_web_prerequisite_checks_trust_roots_and_provisions_certificates(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            ready = SimpleNamespace(return_code=0, stdout="ready", stderr=None)
            missing = SimpleNamespace(return_code=1, stdout="", stderr="Web tools require trusted CA certificates")
            environment = SimpleNamespace(exec=AsyncMock(side_effect=[missing, ready, ready]))
            await agent._ensure_worker_python(environment, require_web_certificates=True)
            calls = environment.exec.await_args_list
            self.assertIn("cert_store_stats", calls[0].args[0])
            self.assertIn("python3 ca-certificates", calls[1].args[0])
            self.assertEqual(calls[0].args, calls[2].args)
            self.assertIn("trusted CA certificates", (Path(directory) / "setup.log").read_text())

    async def test_missing_trust_roots_prevents_native_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            agent.workspace_root = "/app"
            environment = SimpleNamespace(network_policy=NetworkPolicy())
            with patch.object(agent, "_ensure_worker_python", AsyncMock(
                    side_effect=RuntimeError("Web tools require trusted CA certificates"))), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec", AsyncMock()) as launch:
                with self.assertRaisesRegex(RuntimeError, "trusted CA certificates"):
                    await agent.run("Repair", environment, AgentContext())
                launch.assert_not_called()
                self.assertEqual((Path(directory) / "instruction.md").read_text(), "Repair")

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

    async def run_status(self, status, outcome, trajectory=None, export_error=None, policy=None,
                         reasoning_effort=None, workspace_root="/app"):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            logs = Path(directory)
            agent = SumikaAgent(logs_dir=logs, model_name="fixture", binary=sys.executable,
                                **({"reasoning_effort": reasoning_effort} if reasoning_effort is not None else {}))
            agent.workspace_root = workspace_root
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(return_value=status), returncode=status)
            context = AgentContext()
            environment = SimpleNamespace(network_policy=policy or NetworkPolicy())
            if outcome is not None:
                (logs / "result.json").write_text(json.dumps({"outcome": outcome}))
            with patch.object(agent, "_ensure_worker_python", AsyncMock()) as prepare, \
                    patch("script.harbor.agent.SandboxBridge", return_value=bridge) as make_bridge, \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec",
                          AsyncMock(return_value=process)) as launch, \
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
                    capture.assert_awaited_once_with(environment, logs, agent.logger, workspace_root)
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
                    make_bridge.assert_called_once_with(environment, workspace_root)
                    launch_arguments = launch.call_args.args
                    self.assertEqual(launch_arguments[launch_arguments.index("--workspace-root") + 1],
                                     workspace_root)
                    if reasoning_effort is None:
                        self.assertNotIn("--reasoning-level", launch_arguments)
                    else:
                        self.assertEqual(launch_arguments.count("--reasoning-level"), 1)
                        self.assertEqual(launch_arguments[launch_arguments.index("--reasoning-level") + 1],
                                         reasoning_effort)
                    network_index = launch_arguments.index("--network-policy") + 1
                    self.assertEqual(json.loads(launch_arguments[network_index]),
                                     environment.network_policy.model_dump(mode="json"))
                    enabled = environment.network_policy.network_mode == "public" or (
                        environment.network_policy.network_mode == "allowlist"
                        and bool(environment.network_policy.allowed_hosts))
                    if enabled:
                        prepare.assert_awaited_once_with(environment, require_web_certificates=True)
                    else:
                        prepare.assert_not_called()
            return context.metadata

    async def test_runner_receives_reasoning_effort_only_when_requested(self):
        for effort in (None, "low", "medium", "xhigh"):
            with self.subTest(effort=effort):
                kwargs = {"reasoning_effort": effort} if effort is not None else {}
                config = TrialConfig.model_validate({
                    "task": {"path": "script/harbor/tasks/merge-ranges"}, "agent": {"kwargs": kwargs}})
                self.assertEqual(reasoning_effort_from_config(config), effort)
                await self.run_status(0, "completed", **config.agent.kwargs)

    def test_old_reasoning_option_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for kwargs in ({"reasoning_level": "low"}, {"reasoning_level": "low", "reasoning_effort": "medium"}):
                with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, "Use reasoning_effort"):
                    SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable, **kwargs)

    def test_invalid_reasoning_efforts_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for level in ("", "high", "off", 1, True, ["low"]):
                with self.subTest(level=level), self.assertRaisesRegex(ValueError, "reasoning_effort"):
                    SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable,
                                reasoning_effort=level)

    async def test_runner_receives_resolved_agent_phase_policy(self):
        for definition in ('[environment]\nallow_internet = false',
                           '[environment]\nallow_internet = true',
                           '[agent]\nnetwork_mode = "allowlist"\nallowed_hosts = ["example.com"]'):
            with self.subTest(definition=definition):
                task = TaskConfig.model_validate_toml(definition)
                policy = task.agent.explicit_phase_policy() or task.environment.resolve_baseline()
                await self.run_status(0, "completed", policy=policy)

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
            agent.workspace_root = "/app"
            bridge = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                     token="test-token", url="http://127.0.0.1:1")
            process = SimpleNamespace(wait=AsyncMock(return_value=0), returncode=0)
            context = SimpleNamespace(metadata=None)
            environment = SimpleNamespace(network_policy=NetworkPolicy(network_mode="no-network"),
                                          exec=AsyncMock(side_effect=PermissionError("probe denied")))
            with patch("script.harbor.agent.SandboxBridge", return_value=bridge), \
                    patch("script.harbor.agent.asyncio.create_subprocess_exec", AsyncMock(return_value=process)), \
                    self.assertLogs(agent.logger, level="ERROR"):
                await agent.run("Repair", environment, context)
            self.assertEqual(context.metadata, {"sumika": {"outcome": "completed"}})
            self.assertEqual(json.loads((logs / "artifact-error.json").read_text())["error"], "probe denied")

    async def test_cancelled_runner_drains_before_export_and_artifact_capture(self):
        with tempfile.TemporaryDirectory(prefix="sumika-agent-test-") as directory:
            agent = SumikaAgent(logs_dir=Path(directory), model_name="fixture", binary=sys.executable)
            agent.workspace_root = "/app"
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
                    await agent.run("Repair", SimpleNamespace(network_policy=NetworkPolicy(network_mode="no-network")),
                                    context)
            terminate.assert_called_once_with(123, signal.SIGTERM)
            export.assert_called_once()
            capture.assert_awaited_once()
            self.assertEqual(context.n_input_tokens, 25)
            self.assertIsNone(context.n_cache_tokens)
            self.assertEqual(context.n_output_tokens, 7)


if __name__ == "__main__":
    unittest.main()
