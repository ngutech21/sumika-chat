"""Evidence integrity checks use fixtures, without Docker or an MLX model."""

import contextlib
import io
import json
from importlib.util import find_spec
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from script.harbor.evidence import (
    EvidencePlugin, assess_trial, capture_environment, check_evidence, inventory,
    prepare_trial, save_assessment, write_json,
)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sumika-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.trial = Path(self.temporary.name) / "trial"
        self.trial.mkdir()
        write_json(self.trial.parent / "result.json", {"finished_at": "now", "n_total_trials": 1})
        self.write("agent/task/instruction.md", "Repair")
        self.write("artifacts/app/result.py", "solution")
        self.write("agent/instruction.md", "Repair")
        self.write("agent/runner.log", "")
        self.write("agent/source.patch", "")
        self.write("agent/Package.resolved", "{}")
        self.json("result.json", {"id": "trial-1", "finished_at": "now", "task_checksum": "digest",
                                  "verifier_result": {"rewards": {"reward": 0}}})
        self.json("config.json", {"agent": {"model_name": "model"}})
        self.json("lock.json", {"task": {"digest": "digest"}})
        self.json("agent/reproduction.json", {
            "trial_id": "trial-1", "task_checksum": "digest",
            "binary": {"sha256": "binary"}, "source_at_run": {"commit": "commit"},
            "task_files": inventory(self.trial / "agent/task")})
        self.json("agent/runtime.json", {"schemaVersion": 1, "modelID": "model",
            "modelFiles": [{"sha256": "weight"}], "settings": {"contextTokenLimit": 16384},
            "buildConfiguration": "debug"})
        self.json("agent/environment.json", {"images": [{"Id": "image"}]})
        self.json("agent/result.json", {"modelID": "model", "turnID": "turn", "outcome": "completed"})
        self.json("agent/session.json", {"selectedModelID": "model", "turns": [{"id": "turn"}]})
        self.json("artifacts/manifest.json", [{"source": "/app", "destination": "artifacts/app",
                                               "status": "ok", "exclude": []}])
        self.write("verifier/reward.txt", "0")
        self.write("verifier/test-stdout.txt", "failed test")
        self.rows = [{"kind": "mlx_request", "id": "generation"},
                     {"kind": "mlx_response", "id": "generation"},
                     {"kind": "turn_trace", "phase": "runtime_stream_start", "generationID": "generation", "turnID": "turn"},
                     {"kind": "turn_trace", "phase": "runtime_stream_end", "generationID": "generation", "turnID": "turn"}]
        self.trace()

    def write(self, name, contents):
        path = self.trial / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def json(self, name, value):
        write_json(self.trial / name, value)

    def trace(self):
        self.write("agent/mlx-trace.jsonl", "".join(json.dumps(row) + "\n" for row in self.rows))

    def rate_limit_outputs(self):
        result = json.loads((self.trial / "result.json").read_text())
        result["task_name"] = "openthoughts/python-api-rate-limit"
        self.json("result.json", result)
        manifest = json.loads((self.trial / "artifacts/manifest.json").read_text())
        manifest.append({"source": "/output", "destination": "artifacts/reports",
                         "status": "ok", "exclude": []})
        self.json("artifacts/manifest.json", manifest)
        for name in ("report.json", "a.json", "b.json"):
            self.json(f"artifacts/reports/{name}", {"total_requests": 1})
        return manifest

    def test_rate_limiter_requires_output_capture_even_if_not_configured(self):
        result = json.loads((self.trial / "result.json").read_text())
        result["task_name"] = "openthoughts/python-api-rate-limit"
        self.json("result.json", result)
        report = save_assessment(self.trial)
        self.assertFalse(report["complete"])
        self.assertIn("/output", " ".join(report["issues"]))
        with self.assertRaisesRegex(ValueError, "/output"):
            check_evidence(self.trial)

    def test_required_outputs_use_manifest_destination_and_are_checksummed(self):
        self.rate_limit_outputs()
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        for name in ("report.json", "a.json", "b.json"):
            self.assertIn("sha256", report["files"][f"artifacts/reports/{name}"])
        self.json("artifacts/reports/a.json", {"total_requests": 2})
        with self.assertRaisesRegex(ValueError, "changed evidence"):
            check_evidence(self.trial)

    def test_each_missing_required_output_fails_completeness(self):
        self.rate_limit_outputs()
        for name in ("report.json", "a.json", "b.json"):
            with self.subTest(name=name):
                path = self.trial / "artifacts/reports" / name
                contents = path.read_bytes()
                path.unlink()
                report = save_assessment(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn(f"/output/{name}", " ".join(report["issues"]))
                with self.assertRaisesRegex(ValueError, f"/output/{name}"):
                    check_evidence(self.trial)
                path.write_bytes(contents)

    def test_failed_excluded_or_unsafe_output_capture_is_incomplete(self):
        manifest = self.rate_limit_outputs()
        for change in ({"status": "failed"}, {"status": "skipped"},
                       {"exclude": ["report.json"]}, {"destination": "../escape"},
                       {"destination": "/tmp/reports"}, {"service": "sidecar"}):
            with self.subTest(change=change):
                self.json("artifacts/manifest.json", [manifest[0], {**manifest[1], **change}])
                report = assess_trial(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn("/output", " ".join(report["issues"]))

    def test_required_outputs_reject_symlinks_and_directories(self):
        self.rate_limit_outputs()
        path = self.trial / "artifacts/reports/report.json"
        path.unlink()
        path.symlink_to("a.json")
        self.assertFalse(assess_trial(self.trial)["complete"])
        path.unlink()
        path.mkdir()
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_output_capture_rejects_symlink_ancestors(self):
        manifest = self.rate_limit_outputs()
        (self.trial / "artifacts/link").symlink_to(".", target_is_directory=True)
        manifest[1]["destination"] = "artifacts/link/reports"
        self.json("artifacts/manifest.json", manifest)
        report = assess_trial(self.trial)
        self.assertFalse(report["complete"])
        self.assertIn("/output", " ".join(report["issues"]))

    def test_reward_zero_is_complete_and_changed_solution_fails_integrity(self):
        self.assertTrue(save_assessment(self.trial)["complete"])
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial.parent)
        self.write("artifacts/app/result.py", "different solution")
        with self.assertRaisesRegex(ValueError, "changed evidence"):
            check_evidence(self.trial)

    def test_missing_workspace_native_artifacts_and_verifier_logs_are_incomplete(self):
        for name in ("agent/runtime.json", "agent/session.json", "agent/runner.log", "verifier/reward.txt", "verifier/test-stdout.txt"):
            path = self.trial / name
            contents = path.read_bytes()
            path.unlink()
            with self.subTest(name=name):
                self.assertFalse(assess_trial(self.trial)["complete"])
            path.write_bytes(contents)
        self.json("artifacts/manifest.json", [{"source": "/app", "status": "failed",
                                               "destination": "artifacts/app"}])
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_clipped_duplicate_unpaired_and_malformed_traces_are_incomplete(self):
        for row in ({"promptTruncated": True}, {"history": [{"truncated": True}]}):
            self.rows[0].update(row)
            self.trace()
            self.assertFalse(assess_trial(self.trial)["complete"])
            self.rows[0] = {"kind": "mlx_request", "id": "generation"}
        self.rows.pop()
        self.trace()
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.rows.append(self.rows[0])
        self.trace()
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.write("agent/mlx-trace.jsonl", "{broken")
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_identity_task_changes_and_path_traversal_are_rejected(self):
        self.json("agent/result.json", {"modelID": "other"})
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.json("agent/result.json", {"modelID": "model", "turnID": "turn"})
        self.write("agent/task/instruction.md", "Changed")
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.json("artifacts/manifest.json", [{"source": "/app", "destination": "../escape", "status": "ok"}])
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_foreign_turn_and_duplicate_stream_boundaries_are_incomplete(self):
        self.rows[-1]["turnID"] = "other-turn"
        self.trace()
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.rows[-1]["turnID"] = "turn"
        self.rows.append(self.rows[-1])
        self.trace()
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_inventory_preserves_symlinks_without_reading_targets(self):
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (outside / "secret").write_text("private")
        workspace = self.trial / "artifacts/app"
        (workspace / "link").symlink_to(outside, target_is_directory=True)
        records = inventory(workspace)
        self.assertEqual(records["link"]["symlink"], str(outside))
        self.assertNotIn("link/secret", records)
        self.assertTrue(save_assessment(self.trial)["complete"])

    def test_empty_and_unfinished_jobs_do_not_pass(self):
        with self.assertRaisesRegex(ValueError, "No trial evidence"):
            check_evidence(self.trial / "agent")
        self.json("result.json", {})
        self.assertFalse(save_assessment(self.trial)["complete"])

    def test_running_jobs_and_missing_trials_do_not_pass(self):
        save_assessment(self.trial)
        for job, message in (({}, "not finished"),
                             ({"finished_at": "now", "n_total_trials": 2}, "planned count"),
                             ({"finished_at": "now"}, "planned count")):
            write_json(self.trial.parent / "result.json", job)
            with self.subTest(job=job), self.assertRaisesRegex(ValueError, message):
                check_evidence(self.trial.parent)


class PluginTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipIf(find_spec("dirhash") is None, "Requires Harbor's task checksum dependency")
    async def test_task_and_source_snapshot_retain_changes_without_mutating_inputs(self):
        from dirhash import dirhash

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            task = root / "task"
            repository.mkdir()
            task.mkdir()
            (task / "instruction.md").write_text("instruction")
            (task / "solution").mkdir()
            (task / "solution/solve.sh").write_text("reference")
            (repository / "Package.resolved").write_text("{}")
            (repository / "new.py").write_text("untracked source")
            binary = repository / "runner"
            binary.write_text("binary")
            checksum = dirhash(task, "sha256")
            event = SimpleNamespace(trial_name="trial", trial_id="id", config=SimpleNamespace(
                trials_dir=root / "job", agent=SimpleNamespace(kwargs={"binary": str(binary)})),
                lock=SimpleNamespace(task=SimpleNamespace(type="local")),
                result=SimpleNamespace(task_id=SimpleNamespace(get_local_path=lambda: task), task_checksum=checksum))
            with patch("script.harbor.evidence.command", side_effect=[
                    b"commit\n", b"working patch", b"new.py\0", b"Swift version"]), \
                    patch("script.harbor.evidence.version", return_value="0.24.0"):
                prepare_trial(event, repository)
            agent = root / "job/trial/agent"
            self.assertEqual((agent / "task/solution/solve.sh").read_text(), "reference")
            self.assertEqual((agent / "source-untracked/new.py").read_text(), "untracked source")
            self.assertEqual((agent / "source.patch").read_text(), "working patch")
            self.assertEqual(dirhash(task, "sha256"), checksum)
            self.assertFalse(json.loads((agent / "completeness.json").read_text())["complete"])

    @unittest.skipIf(find_spec("harbor") is None or find_spec("dirhash") is None,
                     "Requires Harbor and its task checksum dependency")
    async def test_hub_snapshot_uses_locked_digest_and_checks_contents(self):
        from dirhash import dirhash
        from harbor.models.job.lock import TaskLock
        from harbor.models.trial.config import TaskConfig

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()
            (repository / "Package.resolved").write_text("{}")
            binary = repository / "runner"
            binary.write_text("binary")
            digest = "sha256:" + "a" * 64
            lock = TaskLock(name="terminal-bench/regex-chess", type="package", digest=digest)
            for download_dir in (None, root / "downloads"):
                cache = download_dir or root / "cache"
                task = cache / "terminal-bench/regex-chess" / digest.removeprefix("sha256:")
                task.mkdir(parents=True)
                (task / "instruction.md").write_text("instruction")
                checksum = dirhash(task, "sha256")
                config = TaskConfig(name=lock.name, ref="latest", download_dir=download_dir)
                for changed in (False, True):
                    with self.subTest(download_dir=download_dir, changed=changed):
                        trial_name = f"{cache.name}-{changed}"
                        task_id = config.get_task_id()
                        event = SimpleNamespace(trial_name=trial_name, trial_id="id",
                            config=SimpleNamespace(trials_dir=root / "job", task=config,
                                agent=SimpleNamespace(kwargs={"binary": str(binary)})),
                            lock=SimpleNamespace(task=lock),
                            result=SimpleNamespace(task_id=task_id,
                                task_checksum="changed" if changed else checksum))
                        with patch("harbor.models.task.id.PACKAGE_CACHE_DIR", root / "cache"), \
                                patch("script.harbor.evidence.command", side_effect=[
                                    b"commit\n", b"working patch", b"", b"Swift version"]) as command, \
                                patch("script.harbor.evidence.version", return_value="0.24.0"):
                            if changed:
                                with self.assertRaisesRegex(ValueError, "Task changed after Harbor planned"):
                                    prepare_trial(event, repository)
                                command.assert_not_called()
                            else:
                                prepare_trial(event, repository)
                                agent = root / "job" / trial_name / "agent"
                                self.assertEqual(inventory(agent / "task"), inventory(task))
                                reproduction = json.loads((agent / "reproduction.json").read_text())
                                self.assertEqual(reproduction["task_checksum"], checksum)
                        self.assertEqual(task_id.ref, "latest")

    async def test_capture_must_be_enabled_and_hooks_run_after_trial_and_job(self):
        with patch("script.harbor.evidence.version", return_value="0.24.0"):
            plugin = EvidencePlugin()
            with self.assertRaisesRegex(ValueError, "--artifact /app"):
                await plugin.on_job_start(SimpleNamespace(config=SimpleNamespace(artifacts=[])))
            job = SimpleNamespace(config=SimpleNamespace(artifacts=["/app"]), job_dir=Path("job"),
                                  on_trial_started=lambda hook: None, on_trial_ended=lambda hook: None)
            await plugin.on_job_start(job)
            with patch("script.harbor.evidence.save_assessment", return_value={"complete": False}):
                await plugin.ended(SimpleNamespace(config=SimpleNamespace(trials_dir=Path("job")), trial_name="trial"))

    async def test_environment_records_image_ids_without_environment_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            config = SimpleNamespace(workdir="/app", cpus=1, memory_mb=512,
                                     storage_mb=1024, network_mode="no-network")
            environment = SimpleNamespace(task_env_config=config,
                runtime=lambda: SimpleNamespace(engine=("docker",), engine_cmd=lambda *args: ["docker", *args]),
                _run_docker_compose_command=AsyncMock(return_value=SimpleNamespace(stdout="image-id\n")))
            image = {"Id": "sha256:actual", "RepoDigests": ["image@sha256:digest"],
                     "Config": {"Env": ["TOKEN=private"]}}
            with patch("script.harbor.evidence.command", return_value=json.dumps([image]).encode()):
                await capture_environment(environment, Path(directory))
            contents = (Path(directory) / "environment.json").read_text()
            self.assertIn("sha256:actual", contents)
            self.assertNotIn("private", contents)


if __name__ == "__main__":
    unittest.main()
