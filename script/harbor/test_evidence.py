"""Evidence integrity checks use fixtures, without Docker or an MLX model."""

import contextlib
import io
import json
from importlib.util import find_spec
import logging
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from script.harbor.evidence import (
    EvidencePlugin, assess_trial, capture_environment, capture_legacy_artifacts, check_evidence, inventory,
    prepare_trial, save_assessment, write_json,
)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sumika-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.trial = (Path(self.temporary.name) / "trial").resolve()
        self.trial.mkdir()
        write_json(self.trial.parent / "result.json", {"finished_at": "now", "n_total_trials": 1})
        write_json(self.trial.parent / "config.json", {"agents": [{"model_name": "model"}]})
        write_json(self.trial.parent / "lock.json", {"trials": []})
        self.write("agent/task/instruction.md", "Repair")
        self.write("agent/task/task.toml", "")
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
            "buildConfiguration": "debug", "workspaceRoot": "/app"})
        self.json("agent/environment.json", {"images": [{"Id": "image"}]})
        self.json("agent/result.json", {"modelID": "model", "turnID": "turn", "outcome": "completed"})
        self.json("agent/session.json", {"selectedModelID": "model", "turns": [{"id": "turn"}]})
        self.json("artifacts/manifest.json", [{"source": "/app", "destination": "artifacts/app",
                                               "type": "directory", "status": "ok", "exclude": []}])
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

    def task_config(self, contents):
        self.write("agent/task/task.toml", contents)
        reproduction = json.loads((self.trial / "agent/reproduction.json").read_text())
        reproduction["task_files"] = inventory(self.trial / "agent/task")
        self.json("agent/reproduction.json", reproduction)

    def test_legacy_capture_must_match_the_runtime_workspace(self):
        runtime = json.loads((self.trial / "agent/runtime.json").read_text())
        runtime["workspaceRoot"] = "/work dir"
        self.json("agent/runtime.json", runtime)
        self.assertIn("Missing artifact capture: /work dir (main).", assess_trial(self.trial)["issues"])
        (self.trial / "artifacts/app").rename(self.trial / "artifacts/work dir")
        self.json("artifacts/manifest.json", [{"source": "/work dir", "destination": "artifacts/work dir",
            "type": "directory", "status": "ok", "exclude": []}])
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_legacy_capture_requires_a_valid_nonroot_runtime_workspace(self):
        runtime = json.loads((self.trial / "agent/runtime.json").read_text())
        for root in (None, "", "relative", "/app/../workdir", "/"):
            with self.subTest(root=root):
                runtime["workspaceRoot"] = root
                self.json("agent/runtime.json", runtime)
                self.assertTrue(any("workspaceRoot" in issue for issue in assess_trial(self.trial)["issues"]))

    def test_root_workspace_uses_declared_artifacts(self):
        runtime = json.loads((self.trial / "agent/runtime.json").read_text())
        runtime["workspaceRoot"] = "/"
        self.json("agent/runtime.json", runtime)
        self.task_config('artifacts = ["/app"]\n')
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_declared_file_replaces_workspace_requirement_and_is_checksummed(self):
        self.task_config('artifacts = ["/output/report.json"]\n')
        self.json("artifacts/output/report.json", {"answer": 1})
        self.json("artifacts/manifest.json", [{"source": "/output/report.json",
            "destination": "artifacts/output/report.json", "type": "file", "status": "ok"}])
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        self.json("artifacts/output/report.json", {"answer": 2})
        with self.assertRaisesRegex(ValueError, "changed evidence"):
            check_evidence(self.trial)

    def test_declared_sidecar_directory_honors_destination_and_exclusions(self):
        self.task_config('artifacts = [{source = "/results", destination = "reports", '
                         'service = "loadgen", exclude = ["*.tmp"]}]\n')
        self.write("artifacts/reports/result.csv", "answer")
        entry = {"source": "/results", "destination": "artifacts/reports",
                 "service": "loadgen", "exclude": ["*.tmp"], "type": "directory", "status": "ok"}
        self.json("artifacts/manifest.json", [entry])
        self.assertTrue(assess_trial(self.trial)["complete"])
        for change in ({"service": "main"}, {"destination": "artifacts/elsewhere"},
                       {"exclude": []}, {"exclude": ["*.tmp", "result.csv"]},
                       {"status": "failed"}, {"status": "skipped"}, {"type": "file"}):
            with self.subTest(change=change):
                self.json("artifacts/manifest.json", [{**entry, **change}])
                self.assertFalse(assess_trial(self.trial)["complete"])

    def test_declared_artifacts_cannot_be_replaced_by_unrelated_captures(self):
        self.task_config('artifacts = ["/required/result.csv"]\n')
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_run_level_artifacts_are_also_required(self):
        self.task_config('artifacts = ["/app/result.py"]\n')
        config = json.loads((self.trial / "config.json").read_text())
        config["artifacts"] = ["/output/extra.txt"]
        self.json("config.json", config)
        self.json("artifacts/manifest.json", [{"source": "/app/result.py",
            "destination": "artifacts/app/result.py", "type": "file", "status": "ok"}])
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.write("artifacts/output/extra.txt", "answer")
        manifest = json.loads((self.trial / "artifacts/manifest.json").read_text())
        manifest.append({"source": "/output/extra.txt", "destination": "artifacts/output/extra.txt",
                         "type": "file", "status": "ok"})
        self.json("artifacts/manifest.json", manifest)
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_collection_error_remains_incomplete_after_harbor_collects_logs(self):
        self.json("agent/artifact-error.json", {"error": "Cannot inspect legacy /output path"})
        report = assess_trial(self.trial)
        self.assertFalse(report["complete"])
        self.assertIn("Cannot inspect legacy /output path", " ".join(report["issues"]))

    def test_trajectory_error_is_incomplete_without_requiring_export_for_old_trials(self):
        self.assertFalse((self.trial / "agent/trajectory.json").exists())
        self.assertTrue(assess_trial(self.trial)["complete"])
        self.json("agent/trajectory-error.json", {"error": "Cannot correlate native tool results"})
        report = assess_trial(self.trial)
        self.assertFalse(report["complete"])
        self.assertIn("Trajectory export error: Cannot correlate native tool results", report["issues"])

    def test_declared_empty_directory_is_complete(self):
        self.task_config('artifacts = ["/results"]\n')
        (self.trial / "artifacts/results").mkdir()
        self.json("artifacts/manifest.json", [{"source": "/results", "destination": "artifacts/results",
                                               "type": "directory", "status": "empty", "exclude": []}])
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_declared_outputs_override_rate_limit_legacy_requirements(self):
        result = json.loads((self.trial / "result.json").read_text())
        result["task_name"] = "openthoughts/python-api-rate-limit"
        self.json("result.json", result)
        self.task_config('artifacts = ["/app/result.py"]\n')
        self.json("artifacts/manifest.json", [{"source": "/app/result.py",
            "destination": "artifacts/app/result.py", "type": "file", "status": "ok"}])
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_all_artifact_destinations_and_roots_are_checked(self):
        self.task_config('artifacts = ["/app/result.py"]\n')
        entry = {"source": "/app/result.py", "destination": "artifacts/app/result.py",
                 "type": "file", "status": "ok"}
        for destination in ("../outside", "/tmp/outside", "artifacts/link/result.py"):
            with self.subTest(destination=destination):
                (self.trial / "artifacts/link").symlink_to("app", target_is_directory=True)
                self.json("artifacts/manifest.json", [entry, {"source": "/other",
                    "destination": destination, "type": "file", "status": "ok"}])
                self.assertFalse(assess_trial(self.trial)["complete"])
                (self.trial / "artifacts/link").unlink()
        path = self.trial / "artifacts/app/result.py"
        path.unlink()
        path.symlink_to("missing")
        self.json("artifacts/manifest.json", [entry])
        self.assertFalse(assess_trial(self.trial)["complete"])

    def rate_limit_outputs(self):
        result = json.loads((self.trial / "result.json").read_text())
        result["task_name"] = "openthoughts/python-api-rate-limit"
        self.json("result.json", result)
        manifest = json.loads((self.trial / "artifacts/manifest.json").read_text())
        manifest.append({"source": "/output", "destination": "artifacts/reports",
                         "type": "directory", "status": "ok", "exclude": []})
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

    def test_job_reports_every_failure_and_checks_later_trials_without_mutating_evidence(self):
        save_assessment(self.trial)
        root = self.trial.parent
        for name in ("a-malformed", "b-missing-agent", "c-changed", "d-incomplete", "e-invalid-data"):
            shutil.copytree(self.trial, root / name)
        (root / "a-malformed/agent/completeness.json").write_text("{broken")
        shutil.rmtree(root / "b-missing-agent/agent")
        (root / "c-changed/artifacts/app/result.py").write_text("changed solution")
        (root / "d-incomplete/agent/runner.log").unlink()
        save_assessment(root / "d-incomplete")
        (root / "e-invalid-data/agent/session.json").write_text("[]")
        write_json(root / "result.json", {"finished_at": "now", "n_total_trials": 6})
        before = inventory(root)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(ValueError) as caught:
            check_evidence(root)
        detail = str(caught.exception)
        for name in ("a-malformed", "b-missing-agent", "c-changed", "d-incomplete", "e-invalid-data"):
            self.assertIn(f"Incomplete or changed evidence in {root / name}:", detail)
        self.assertIn("Evidence files changed since saved assessment: artifacts/app/result.py", detail)
        incomplete = detail.split(f"{root / 'd-incomplete'}:\n", 1)[1].split("Incomplete or changed evidence", 1)[0]
        self.assertEqual(incomplete.count("Missing regular file: agent/runner.log"), 1)
        self.assertIn(f"Complete evidence: {self.trial}", output.getvalue())
        self.assertIn("6 trials checked, 1 complete, 5 incomplete", output.getvalue())
        self.assertEqual(inventory(root), before)

    def test_job_metadata_errors_do_not_skip_available_trials(self):
        save_assessment(self.trial)
        for value in ("{broken", "[]", '{"n_total_trials": 2}'):
            with self.subTest(value=value):
                (self.trial.parent / "result.json").write_text(value)
                output = io.StringIO()
                with contextlib.redirect_stdout(output), self.assertRaises(ValueError):
                    check_evidence(self.trial.parent)
                self.assertIn(f"Complete evidence: {self.trial}", output.getvalue())
                self.assertIn("1 trials checked, 1 complete, 0 incomplete", output.getvalue())

    def test_missing_or_malformed_report_does_not_skip_current_assessment(self):
        self.write("agent/runtime.json", "{}")
        for value in (None, "[]", '{"complete": true, "files": {}, "issues": [null]}'):
            with self.subTest(value=value):
                path = self.trial / "agent/completeness.json"
                if value is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(value)
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError) as caught:
                    check_evidence(self.trial)
                self.assertIn("agent/completeness.json", str(caught.exception))
                self.assertIn("Runtime settings or build configuration are missing", str(caught.exception))

    def test_missing_agent_directory_is_reported_for_a_single_trial(self):
        shutil.rmtree(self.trial / "agent")
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError) as caught:
            check_evidence(self.trial)
        self.assertIn(f"Incomplete or changed evidence in {self.trial}", str(caught.exception))
        self.assertIn("agent/completeness.json", str(caught.exception))

    def test_missing_artifact_keys_are_reported_without_aborting_other_trials(self):
        save_assessment(self.trial)
        broken = self.trial.parent / "a-broken"
        shutil.copytree(self.trial, broken)
        write_json(broken / "config.json", {"agent": {"model_name": "model"}, "artifacts": [{}]})
        self.assertFalse(save_assessment(broken)["complete"])
        write_json(self.trial.parent / "result.json", {"finished_at": "now", "n_total_trials": 2})
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(ValueError) as caught:
            check_evidence(self.trial.parent)
        self.assertIn(f"Incomplete or changed evidence in {broken}", str(caught.exception))
        self.assertIn(f"Complete evidence: {self.trial}", output.getvalue())

    def test_cli_exits_after_reporting_all_failures(self):
        self.write("agent/runtime.json", "{}")
        (self.trial / "agent/mlx-trace.jsonl").unlink()
        save_assessment(self.trial)
        shutil.copytree(self.trial, self.trial.parent / "second")
        save_assessment(self.trial.parent / "second")
        write_json(self.trial.parent / "result.json", {"finished_at": "now", "n_total_trials": 2})
        result = subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("evidence.py").resolve()),
                                 self.trial.parent.name], cwd=self.trial.parent.parent,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("2 trials checked, 0 complete, 2 incomplete", result.stdout)
        self.assertIn(f"Incomplete or changed evidence in {self.trial}:", result.stderr)
        self.assertIn(f"Incomplete or changed evidence in {self.trial.parent / 'second'}:", result.stderr)
        self.assertEqual(result.stderr.count("agent/mlx-trace.jsonl:"), 2)
        self.assertNotIn("Traceback", result.stderr)


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

    async def test_capture_needs_no_recipe_paths_and_hooks_run_after_trial_and_job(self):
        with patch("script.harbor.evidence.version", return_value="0.24.0"):
            plugin = EvidencePlugin()
            job = SimpleNamespace(config=SimpleNamespace(artifacts=[]), job_dir=Path("job"),
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


@unittest.skipIf(find_spec("harbor") is None, "Requires the pinned Harbor environment")
class LegacyCaptureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sumika-artifacts-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.logs = self.root / "trial/agent"
        (self.logs / "task").mkdir(parents=True)
        (self.logs / "task/task.toml").write_text("")
        self.remote = self.root / "remote"
        (self.remote / "app").mkdir(parents=True)
        (self.remote / "app/result.csv").write_text("answer")
        (self.remote / "logs/artifacts").mkdir(parents=True)
        self.logger = logging.getLogger("sumika-artifacts-test")

        async def download_directory(source_dir, target_dir, **_kwargs):
            shutil.copytree(self.remote / source_dir.lstrip("/"), target_dir,
                            dirs_exist_ok=True, symlinks=True)

        self.environment = SimpleNamespace(
            capabilities=SimpleNamespace(mounted=False),
            exec=AsyncMock(side_effect=lambda *_args, **_kwargs: SimpleNamespace(return_code=(
                4 if (self.remote / "output").is_symlink()
                else 0 if (self.remote / "output").exists() else 3))),
            service_is_dir=AsyncMock(side_effect=lambda path, **_kwargs:
                                    (self.remote / path.lstrip("/")).is_dir()),
            service_download_dir=AsyncMock(side_effect=download_directory))

    async def test_legacy_capture_preserves_existing_output_and_omits_absent_output(self):
        from harbor.models.trial.paths import EnvironmentPaths
        from harbor.trial.artifact_handler import ArtifactHandler

        for present in (False, True):
            with self.subTest(output_present=present):
                if present:
                    (self.remote / "output").mkdir()
                    for name in ("report.json", "a.json", "b.json"):
                        (self.remote / "output" / name).write_text("{}")
                artifacts = self.logs.parent / "artifacts"
                if artifacts.exists():
                    shutil.rmtree(artifacts)
                await capture_legacy_artifacts(self.environment, self.logs, self.logger, "/app")
                # Harbor's later collection must retain the legacy manifest entries.
                await ArtifactHandler(artifacts=[], logger=self.logger).download_artifacts(
                    self.environment, artifacts, source_artifacts_dir=EnvironmentPaths.artifacts_dir)
                manifest = json.loads((artifacts / "manifest.json").read_text())
                sources = {entry["source"] for entry in manifest}
                self.assertIn("/app", sources)
                self.assertEqual("/output" in sources, present)
                self.assertTrue(all(entry["status"] in ("ok", "empty") for entry in manifest))
                self.assertEqual((artifacts / "app/result.csv").read_text(), "answer")
                if present:
                    for name in ("report.json", "a.json", "b.json"):
                        self.assertEqual((artifacts / "output" / name).read_text(), "{}")

    async def test_declared_artifacts_leave_collection_to_harbor(self):
        (self.logs / "task/task.toml").write_text('artifacts = ["/app/result.csv"]\n')
        await capture_legacy_artifacts(self.environment, self.logs, self.logger, "/")
        self.environment.exec.assert_not_awaited()
        self.environment.service_download_dir.assert_not_awaited()
        self.assertFalse((self.logs.parent / "artifacts").exists())

    async def test_legacy_capture_uses_resolved_root_and_deduplicates_output(self):
        for root in ("/work dir", "/output"):
            with self.subTest(root=root):
                remote = self.remote / root.lstrip("/")
                remote.mkdir()
                (remote / "result.csv").write_text("answer")
                await capture_legacy_artifacts(self.environment, self.logs, self.logger, root)
                artifacts = self.logs.parent / "artifacts"
                manifest = json.loads((artifacts / "manifest.json").read_text())
                self.assertEqual([entry["source"] for entry in manifest], ["/logs/artifacts", root])
                self.assertEqual((artifacts / root.lstrip("/") / "result.csv").read_text(), "answer")
                shutil.rmtree(artifacts)

    async def test_legacy_capture_never_downloads_container_root(self):
        with self.assertLogs(self.logger, level="ERROR"):
            await capture_legacy_artifacts(self.environment, self.logs, self.logger, "/")
        self.environment.exec.assert_not_awaited()
        self.environment.service_download_dir.assert_not_awaited()
        error = json.loads((self.logs / "artifact-error.json").read_text())
        self.assertIn("must declare artifacts", error["error"])

    async def test_probe_errors_and_output_symlinks_are_reported(self):
        for kind in ("transport", "symlink"):
            with self.subTest(kind=kind):
                if kind == "transport":
                    self.environment.exec.side_effect = PermissionError("probe denied")
                else:
                    self.environment.exec.side_effect = None
                    self.environment.exec.return_value = SimpleNamespace(return_code=4)
                    (self.remote / "output").symlink_to(self.remote / "app", target_is_directory=True)
                with self.assertLogs(self.logger, level="ERROR"):
                    await capture_legacy_artifacts(self.environment, self.logs, self.logger, "/app")
                error = json.loads((self.logs / "artifact-error.json").read_text())
                self.assertTrue(error["error"])
                self.environment.service_download_dir.assert_not_awaited()

    async def test_transfer_failure_is_preserved_in_the_manifest(self):
        download = self.environment.service_download_dir.side_effect
        (self.remote / "output").mkdir()

        async def fail_output(source_dir, target_dir, **kwargs):
            if source_dir == "/output":
                raise PermissionError("copy denied")
            await download(source_dir, target_dir, **kwargs)

        self.environment.service_download_dir.side_effect = fail_output
        await capture_legacy_artifacts(self.environment, self.logs, self.logger, "/app")
        manifest = json.loads((self.logs.parent / "artifacts/manifest.json").read_text())
        self.assertEqual(next(entry["status"] for entry in manifest if entry["source"] == "/output"), "failed")


if __name__ == "__main__":
    unittest.main()
