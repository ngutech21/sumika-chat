"""Evidence integrity checks use fixtures, without Docker or an MLX model."""

import contextlib
import copy
import hashlib
import io
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from importlib.util import find_spec
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from script.harbor.evidence import (
    EvidencePlugin,
    assess_trial,
    capture_environment,
    capture_legacy_artifacts,
    check_evidence,
    inventory,
    prepare_trial,
    save_assessment,
    write_json,
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
        self.write("provenance/task/instruction.md", "Repair")
        self.write("provenance/task/task.toml", "")
        self.write("artifacts/app/result.py", "solution")
        self.write("agent/instruction.md", "Repair")
        self.write("agent/runner.log", "")
        self.write("provenance/source.patch", "")
        self.write("provenance/Package.resolved", "{}")
        (self.trial / "provenance/source-untracked").mkdir()
        self.json(
            "result.json",
            {
                "id": "trial-1",
                "finished_at": "now",
                "task_checksum": "digest",
                "verifier_result": {"rewards": {"reward": 0}},
            },
        )
        self.json("config.json", {"agent": {"model_name": "model"}})
        self.json("lock.json", {"task": {"digest": "digest"}})
        self.json(
            "provenance/reproduction.json",
            {
                "trial_id": "trial-1",
                "task_checksum": "digest",
                "binary": {"sha256": "binary"},
                "source_at_run": {
                    "commit": "commit",
                    "patch": "provenance/source.patch",
                    "untracked": "provenance/source-untracked",
                },
                "runtime_metadata": "agent/runtime.json",
                "task_files": inventory(self.trial / "provenance/task"),
            },
        )
        self.json(
            "agent/runtime.json",
            {
                "schemaVersion": 1,
                "modelID": "model",
                "modelFiles": [{"sha256": "weight"}],
                "settings": {"contextTokenLimit": 16384},
                "buildConfiguration": "debug",
                "workspaceRoot": "/app",
            },
        )
        self.json("agent/environment.json", {"images": [{"Id": "image"}]})
        self.json("agent/result.json", {"modelID": "model", "turnID": "turn", "outcome": "completed"})
        self.json("agent/session.json", {"selectedModelID": "model", "turns": [{"id": "turn"}]})
        self.json(
            "artifacts/manifest.json",
            [{"source": "/app", "destination": "artifacts/app", "type": "directory", "status": "ok", "exclude": []}],
        )
        self.write("verifier/reward.txt", "0")
        self.write("verifier/test-stdout.txt", "failed test")
        self.rows = [
            {"kind": "mlx_request", "id": "generation"},
            {"kind": "mlx_response", "id": "generation"},
            {"kind": "turn_trace", "phase": "runtime_stream_start", "generationID": "generation", "turnID": "turn"},
            {"kind": "turn_trace", "phase": "runtime_stream_end", "generationID": "generation", "turnID": "turn"},
        ]
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
        self.write("provenance/task/task.toml", contents)
        reproduction = json.loads((self.trial / "provenance/reproduction.json").read_text())
        reproduction["task_files"] = inventory(self.trial / "provenance/task")
        self.json("provenance/reproduction.json", reproduction)

    def legacy_provenance(self, relative):
        target = self.trial / relative
        target.mkdir(parents=True, exist_ok=True)
        provenance = self.trial / "provenance"
        for path in provenance.iterdir():
            path.rename(target / path.name)
        provenance.rmdir()
        reproduction = json.loads((target / "reproduction.json").read_text())
        reproduction["source_at_run"].update(patch=f"{relative}/source.patch", untracked=f"{relative}/source-untracked")
        write_json(target / "reproduction.json", reproduction)

    def test_absent_empty_publish_directory_is_not_accepted_for_single_step_trials(self):
        manifest = json.loads((self.trial / "artifacts/manifest.json").read_text())
        manifest.append(
            {
                "source": "/logs/artifacts",
                "destination": "artifacts/logs/artifacts",
                "type": "directory",
                "status": "empty",
                "service": None,
                "exclude": [],
            }
        )
        self.json("artifacts/manifest.json", manifest)
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_legacy_saved_single_step_evidence_remains_readable_without_migration(self):
        self.legacy_provenance("agent")
        self.assertTrue(save_assessment(self.trial)["complete"])
        before = inventory(self.trial)
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        self.assertEqual(inventory(self.trial), before)
        self.assertFalse((self.trial / "provenance").exists())

    def test_assessment_hashes_each_file_once_in_current_and_legacy_layouts(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                if legacy:
                    self.legacy_provenance("agent")
                with patch("script.harbor.evidence.hashlib.file_digest", wraps=hashlib.file_digest) as digest:
                    report = assess_trial(self.trial)
                self.assertTrue(report["complete"], report["issues"])
                self.assertCountEqual(
                    [Path(call.args[0].name) for call in digest.call_args_list],
                    [self.trial / name for name, record in report["files"].items() if "sha256" in record],
                )

    def test_new_provenance_rejects_duplicates_and_snapshots_exposed_in_agent_logs(self):
        shutil.copytree(self.trial / "provenance/task", self.trial / "agent/task")
        self.assertIn("exposed in agent logs", " ".join(assess_trial(self.trial)["issues"]))
        shutil.rmtree(self.trial / "agent/task")
        source = self.trial / "provenance/reproduction.json"
        duplicate = self.trial / "agent/reproduction.json"
        for symlink in (False, True):
            if symlink:
                duplicate.symlink_to(source)
            else:
                shutil.copy2(source, duplicate)
            with self.subTest(symlink=symlink):
                self.assertIn(
                    "Expected one canonical reproduction snapshot", " ".join(assess_trial(self.trial)["issues"])
                )
            duplicate.unlink()

    def test_legacy_capture_must_match_the_runtime_workspace(self):
        runtime = json.loads((self.trial / "agent/runtime.json").read_text())
        runtime["workspaceRoot"] = "/work dir"
        self.json("agent/runtime.json", runtime)
        self.assertIn("Missing artifact capture: /work dir (main).", assess_trial(self.trial)["issues"])
        (self.trial / "artifacts/app").rename(self.trial / "artifacts/work dir")
        self.json(
            "artifacts/manifest.json",
            [
                {
                    "source": "/work dir",
                    "destination": "artifacts/work dir",
                    "type": "directory",
                    "status": "ok",
                    "exclude": [],
                }
            ],
        )
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
        self.json(
            "artifacts/manifest.json",
            [
                {
                    "source": "/output/report.json",
                    "destination": "artifacts/output/report.json",
                    "type": "file",
                    "status": "ok",
                }
            ],
        )
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        self.json("artifacts/output/report.json", {"answer": 2})
        with self.assertRaisesRegex(ValueError, "changed evidence"):
            check_evidence(self.trial)

    def test_declared_sidecar_directory_honors_destination_and_exclusions(self):
        self.task_config(
            'artifacts = [{source = "/results", destination = "reports", service = "loadgen", exclude = ["*.tmp"]}]\n'
        )
        self.write("artifacts/reports/result.csv", "answer")
        entry = {
            "source": "/results",
            "destination": "artifacts/reports",
            "service": "loadgen",
            "exclude": ["*.tmp"],
            "type": "directory",
            "status": "ok",
        }
        self.json("artifacts/manifest.json", [entry])
        self.assertTrue(assess_trial(self.trial)["complete"])
        for change in (
            {"service": "main"},
            {"destination": "artifacts/elsewhere"},
            {"exclude": []},
            {"exclude": ["*.tmp", "result.csv"]},
            {"status": "failed"},
            {"status": "skipped"},
            {"type": "file"},
        ):
            with self.subTest(change=change):
                self.json("artifacts/manifest.json", [{**entry, **change}])
                self.assertFalse(assess_trial(self.trial)["complete"])

    def test_declared_artifacts_cannot_be_replaced_by_unrelated_captures(self):
        self.task_config('artifacts = ["/required/result.csv"]\n')
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_malformed_task_artifact_declarations_are_incomplete(self):
        for declaration in ('"/app"', "[1]", '[{source = "/app", destination = "../escape"}]'):
            with self.subTest(declaration=declaration):
                self.task_config(f"artifacts = {declaration}\n")
                report = assess_trial(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn("provenance/task/task.toml:", " ".join(report["issues"]))

    def test_malformed_run_artifact_declarations_are_incomplete(self):
        config = json.loads((self.trial / "config.json").read_text())
        for declaration in ("/app", [1], [{"source": "/app", "destination": "../escape"}]):
            with self.subTest(declaration=declaration):
                self.json("config.json", {**config, "artifacts": declaration})
                report = assess_trial(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn("Artifact declarations:", " ".join(report["issues"]))

    def test_malformed_artifact_manifests_are_incomplete(self):
        entry = json.loads((self.trial / "artifacts/manifest.json").read_text())[0]
        for manifest in ({}, [{}], [{**entry, "type": "symlink"}], [{**entry, "exclude": "*.tmp"}]):
            with self.subTest(manifest=manifest):
                self.json("artifacts/manifest.json", manifest)
                report = assess_trial(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn("artifacts/manifest.json:", " ".join(report["issues"]))

    def test_run_level_artifacts_are_also_required(self):
        self.task_config('artifacts = ["/app/result.py"]\n')
        config = json.loads((self.trial / "config.json").read_text())
        config["artifacts"] = ["/output/extra.txt"]
        self.json("config.json", config)
        self.json(
            "artifacts/manifest.json",
            [{"source": "/app/result.py", "destination": "artifacts/app/result.py", "type": "file", "status": "ok"}],
        )
        self.assertFalse(assess_trial(self.trial)["complete"])
        self.write("artifacts/output/extra.txt", "answer")
        manifest = json.loads((self.trial / "artifacts/manifest.json").read_text())
        manifest.append(
            {"source": "/output/extra.txt", "destination": "artifacts/output/extra.txt", "type": "file", "status": "ok"}
        )
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
        self.json(
            "artifacts/manifest.json",
            [
                {
                    "source": "/results",
                    "destination": "artifacts/results",
                    "type": "directory",
                    "status": "empty",
                    "exclude": [],
                }
            ],
        )
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_declared_outputs_override_rate_limit_legacy_requirements(self):
        result = json.loads((self.trial / "result.json").read_text())
        result["task_name"] = "openthoughts/python-api-rate-limit"
        self.json("result.json", result)
        self.task_config('artifacts = ["/app/result.py"]\n')
        self.json(
            "artifacts/manifest.json",
            [{"source": "/app/result.py", "destination": "artifacts/app/result.py", "type": "file", "status": "ok"}],
        )
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_all_artifact_destinations_and_roots_are_checked(self):
        self.task_config('artifacts = ["/app/result.py"]\n')
        entry = {"source": "/app/result.py", "destination": "artifacts/app/result.py", "type": "file", "status": "ok"}
        for destination in ("../outside", "/tmp/outside", "artifacts/link/result.py"):
            with self.subTest(destination=destination):
                (self.trial / "artifacts/link").symlink_to("app", target_is_directory=True)
                self.json(
                    "artifacts/manifest.json",
                    [entry, {"source": "/other", "destination": destination, "type": "file", "status": "ok"}],
                )
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
        manifest.append(
            {
                "source": "/output",
                "destination": "artifacts/reports",
                "type": "directory",
                "status": "ok",
                "exclude": [],
            }
        )
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
        for change in (
            {"status": "failed"},
            {"status": "skipped"},
            {"exclude": ["report.json"]},
            {"destination": "../escape"},
            {"destination": "/tmp/reports"},
            {"service": "sidecar"},
        ):
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
        for name in (
            "agent/runtime.json",
            "agent/session.json",
            "agent/runner.log",
            "verifier/reward.txt",
            "verifier/test-stdout.txt",
        ):
            path = self.trial / name
            contents = path.read_bytes()
            path.unlink()
            with self.subTest(name=name):
                self.assertFalse(assess_trial(self.trial)["complete"])
            path.write_bytes(contents)
        self.json("artifacts/manifest.json", [{"source": "/app", "status": "failed", "destination": "artifacts/app"}])
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
        self.write("provenance/task/instruction.md", "Changed")
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
        for job, message in (
            ({}, "not finished"),
            ({"finished_at": "now", "n_total_trials": 2}, "planned count"),
            ({"finished_at": "now"}, "planned count"),
        ):
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
        result = subprocess.run(
            [sys.executable, "-B", "-m", "script.harbor.evidence", self.trial.parent.name],
            cwd=self.trial.parent.parent,
            env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[2])},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("2 trials checked, 0 complete, 2 incomplete", result.stdout)
        self.assertIn(f"Incomplete or changed evidence in {self.trial}:", result.stderr)
        self.assertIn(f"Incomplete or changed evidence in {self.trial.parent / 'second'}:", result.stderr)
        self.assertEqual(result.stderr.count("agent/mlx-trace.jsonl:"), 2)
        self.assertNotIn("Traceback", result.stderr)


class CheckpointEvidenceTests(unittest.TestCase):
    setUp = EvidenceTests.setUp
    write = EvidenceTests.write
    json = EvidenceTests.json
    trace = EvidenceTests.trace
    task_config = EvidenceTests.task_config

    def checkpoints(self, task_artifacts='artifacts = ["/app"]', step_options=""):
        names = [f"checkpoint_{index}" for index in range(1, 5)]
        for name in names:
            self.write(f"provenance/task/steps/{name}/instruction.md", name)
        self.task_config(
            task_artifacts + "\n" + "\n".join(f'[[steps]]\nname = "{name}"\n{step_options}' for name in names)
        )
        first = self.trial / "steps" / names[0]
        first.mkdir(parents=True)
        for directory in ("agent", "artifacts", "verifier"):
            (self.trial / directory).rename(first / directory)
        reproduction_path = self.trial / "provenance/reproduction.json"
        reproduction = json.loads(reproduction_path.read_text())
        reproduction["runtime_metadata"] = f"steps/{names[0]}/agent/runtime.json"
        write_json(reproduction_path, reproduction)
        results = []
        for index, name in enumerate(names):
            run = self.trial / "steps" / name
            if index:
                shutil.copytree(first, run)
            native = {"modelID": "model", "turnID": name, "outcome": "completed"}
            self.json(f"steps/{name}/agent/result.json", native)
            self.json(f"steps/{name}/agent/session.json", {"selectedModelID": "model", "turns": [{"id": name}]})
            self.write(f"steps/{name}/agent/instruction.md", name)
            rows = [{**row, "turnID": name} if "turnID" in row else row for row in self.rows]
            self.write(f"steps/{name}/agent/mlx-trace.jsonl", "".join(json.dumps(row) + "\n" for row in rows))
            results.append(
                {
                    "step_name": name,
                    "agent_result": {"metadata": {"sumika": native}},
                    "verifier_result": {"rewards": {"reward": 0}},
                }
            )
        harbor = json.loads((self.trial / "result.json").read_text())
        harbor["step_results"] = results
        self.json("result.json", harbor)
        return names, harbor

    def resumed_checkpoints(self):
        names, harbor = self.checkpoints()
        self.json("config.json", {"agent": {"model_name": "model", "resume_trajectory": True}})
        turns = []
        for name in names:
            turns.append(
                {"id": name, "status": "completed", "items": [{"kind": "userMessage", "payload": {"content": name}}]}
            )
            self.json(
                f"steps/{name}/agent/session.json",
                {"id": "resumed-session", "selectedModelID": "model", "turns": turns},
            )
        return names, harbor

    def test_resumed_checkpoints_preserve_canonical_history_and_count_only_current_traces(self):
        names, _ = self.resumed_checkpoints()
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        self.assertEqual(report["trace_requests"], len(names))
        for index, name in enumerate(names):
            session = json.loads((self.trial / f"steps/{name}/agent/session.json").read_text())
            self.assertEqual([turn["id"] for turn in session["turns"]], names[: index + 1])
        before = inventory(self.trial)
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        self.assertEqual(inventory(self.trial), before)

    def test_resumed_session_identity_order_and_unchanged_history_are_required(self):
        names, _ = self.resumed_checkpoints()
        path = self.trial / f"steps/{names[1]}/agent/session.json"
        original = json.loads(path.read_text())
        variants = [
            {**original, "id": "foreign-session"},
            {**original, "turns": original["turns"][1:]},
            {**original, "turns": original["turns"][:1]},
            {**original, "turns": list(reversed(original["turns"]))},
            {**original, "turns": [*original["turns"], original["turns"][-1]]},
        ]
        changed = copy.deepcopy(original)
        changed["turns"][0]["items"][0]["payload"]["content"] = "rewritten prior checkpoint"
        variants.append(changed)
        for session in variants:
            with self.subTest(session=session):
                write_json(path, session)
                self.assertFalse(assess_trial(self.trial)["complete"])
        write_json(path, original)
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_resumed_checkpoint_runtime_identity_is_stable(self):
        names, _ = self.resumed_checkpoints()
        path = self.trial / f"steps/{names[1]}/agent/runtime.json"
        original = json.loads(path.read_text())
        for change in ({"settings": {"contextTokenLimit": 32768}}, {"modelFiles": [{"sha256": "other-model-weights"}]}):
            with self.subTest(change=change):
                write_json(path, {**original, **change})
                self.assertIn("fingerprints or settings changed", " ".join(assess_trial(self.trial)["issues"]))
        write_json(path, original)
        self.assertTrue(assess_trial(self.trial)["complete"])

    def test_resumed_traces_reject_foreign_turns_and_orphaned_or_duplicate_prefills(self):
        names, _ = self.resumed_checkpoints()
        path = self.trial / f"steps/{names[1]}/agent/mlx-trace.jsonl"
        original = [json.loads(line) for line in path.read_text().splitlines()]
        prefill = {"kind": "turn_trace", "phase": "runtime_prefill", "generationID": "generation", "turnID": names[1]}
        for rows in (
            original + [{"kind": "turn_trace", "phase": "runtime_memory", "turnID": names[0]}],
            original + [{**prefill, "generationID": "orphan"}],
            original + [prefill, prefill],
            original[:-1],
        ):
            with self.subTest(rows=rows):
                path.write_text("".join(json.dumps(row) + "\n" for row in rows))
                self.assertFalse(assess_trial(self.trial)["complete"])

    def test_archived_checkpoints_share_provenance_and_each_remain_checksummed(self):
        names, _ = self.checkpoints()
        self.assertFalse((self.trial / "agent").exists())
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        self.assertEqual(report["trace_requests"], 4)
        self.assertEqual([step["name"] for step in report["steps"]], names)
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial.parent)
        self.write(f"steps/{names[-1]}/artifacts/app/result.py", "modified checkpoint")
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "changed evidence"):
            check_evidence(self.trial)

    def test_assessment_hashes_each_checkpoint_file_once_in_current_and_legacy_layouts(self):
        names, _ = self.checkpoints()
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                if legacy:
                    EvidenceTests.legacy_provenance(self, f"steps/{names[0]}/agent")
                with patch("script.harbor.evidence.hashlib.file_digest", wraps=hashlib.file_digest) as digest:
                    report = assess_trial(self.trial)
                self.assertTrue(report["complete"], report["issues"])
                self.assertCountEqual(
                    [Path(call.args[0].name) for call in digest.call_args_list],
                    [self.trial / name for name, record in report["files"].items() if "sha256" in record],
                )

    @unittest.skipIf(find_spec("harbor") is None, "Requires the pinned Harbor archive implementation")
    def test_harbor_archive_omits_empty_publish_mount_but_preserves_declared_empty_directory(self):
        from harbor.trial.artifact_handler import ArtifactHandler

        names, _ = self.checkpoints('artifacts = ["/app", "/empty"]')
        for name in names:
            archived = self.trial / "steps" / name / "artifacts"
            live = self.trial / "artifacts"
            archived.rename(live)
            publish = live / "logs/artifacts"
            publish.mkdir(parents=True)
            (live / "empty").mkdir()
            manifest = json.loads((live / "manifest.json").read_text())
            manifest.extend(
                [
                    {
                        "source": "/logs/artifacts",
                        "destination": "artifacts/logs/artifacts",
                        "type": "directory",
                        "status": "empty",
                        "service": None,
                        "exclude": [],
                    },
                    {"source": "/empty", "destination": "artifacts/empty", "type": "directory", "status": "ok"},
                ]
            )
            write_json(live / "manifest.json", manifest)
            ArtifactHandler.move_dir_contents_preserving(live, archived, preserve_dirs=[publish])
            self.assertTrue(publish.is_dir())
            self.assertFalse((archived / "logs/artifacts").exists())
            self.assertTrue((archived / "empty").is_dir())
            shutil.rmtree(live)
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        self.assertIn("sha256", report["files"][f"steps/{names[0]}/artifacts/manifest.json"])
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        shutil.rmtree(self.trial / "steps" / names[0] / "artifacts/empty")
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_absent_empty_publish_capture_exception_is_narrow_and_keeps_path_safety(self):
        names, _ = self.checkpoints()
        run = self.trial / "steps" / names[0]
        path = run / "artifacts/manifest.json"
        manifest = json.loads(path.read_text())
        entry = {
            "source": "/logs/artifacts",
            "destination": "artifacts/logs/artifacts",
            "type": "directory",
            "status": "empty",
            "service": None,
            "exclude": [],
        }
        for service in (None, "main"):
            write_json(path, [*manifest, {**entry, "service": service}])
            self.assertTrue(assess_trial(self.trial)["complete"])
        for change in (
            {"source": "/elsewhere"},
            {"type": "file"},
            {"status": "ok"},
            {"status": "failed"},
            {"service": "sidecar"},
            {"exclude": ["*.tmp"]},
            {"exclude": None},
            {"destination": "artifacts/custom"},
            {"destination": "artifacts/logs/./artifacts"},
            {"destination": "../escape"},
            {"destination": "/tmp/outside"},
        ):
            with self.subTest(change=change):
                write_json(path, [*manifest, {**entry, **change}])
                self.assertFalse(assess_trial(self.trial)["complete"])
        write_json(path, [*manifest, entry])
        for relative in ("logs", "logs/artifacts"):
            capture = run / "artifacts" / relative
            capture.parent.mkdir(parents=True, exist_ok=True)
            capture.symlink_to(self.trial.parent / "missing", target_is_directory=True)
            with self.subTest(symlink=relative):
                self.assertFalse(assess_trial(self.trial)["complete"])
            capture.unlink()
        capture.write_text("not a directory")
        self.assertFalse(assess_trial(self.trial)["complete"])
        capture.unlink()
        capture.parent.rmdir()
        capture.parent.write_text("not a directory")
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_legacy_checkpoint_archives_remain_readable_without_migration(self):
        names, _ = self.checkpoints()
        EvidenceTests.legacy_provenance(self, f"steps/{names[0]}/agent")
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        before = inventory(self.trial)
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        self.assertEqual(inventory(self.trial), before)
        self.assertFalse((self.trial / "provenance").exists())

    def test_reproduction_pointers_must_resolve_to_the_canonical_archive(self):
        names, _ = self.checkpoints()
        reproduction_path = self.trial / "provenance/reproduction.json"
        reproduction = json.loads(reproduction_path.read_text())
        for owner, key, stale in (
            (reproduction["source_at_run"], "patch", "agent/source.patch"),
            (reproduction["source_at_run"], "untracked", "agent/source-untracked"),
            (reproduction, "runtime_metadata", f"steps/{names[1]}/agent/runtime.json"),
        ):
            original = owner[key]
            for pointer in (None, stale, "../outside"):
                owner[key] = pointer
                write_json(reproduction_path, reproduction)
                with self.subTest(key=key, pointer=pointer):
                    self.assertIn("Reproduction pointer", " ".join(assess_trial(self.trial)["issues"]))
            owner[key] = original
        write_json(reproduction_path, reproduction)
        self.assertTrue(assess_trial(self.trial)["complete"])
        (self.trial / reproduction["source_at_run"]["untracked"]).rmdir()
        self.assertIn("source-untracked", " ".join(assess_trial(self.trial)["issues"]))

    def test_every_attempted_checkpoint_requires_its_own_evidence(self):
        names, harbor = self.checkpoints()
        for name in (
            "agent/runtime.json",
            "agent/environment.json",
            "agent/session.json",
            "agent/runner.log",
            "agent/mlx-trace.jsonl",
            "verifier/reward.txt",
            "verifier/test-stdout.txt",
            "artifacts/manifest.json",
        ):
            path = self.trial / "steps" / names[1] / name
            contents = path.read_bytes()
            path.unlink()
            with self.subTest(name=name):
                report = assess_trial(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn(names[1], " ".join(report["issues"]))
            path.write_bytes(contents)
        harbor["step_results"][1]["agent_result"] = harbor["step_results"][0]["agent_result"]
        self.json("result.json", harbor)
        self.assertIn(
            "Native result does not match Harbor checkpoint metadata", " ".join(assess_trial(self.trial)["issues"])
        )

    def test_task_step_and_run_artifacts_are_combined_per_checkpoint(self):
        names, _ = self.checkpoints(
            'artifacts = ["/app/result.py"]',
            'artifacts = [{source = "/reports", destination = "reports", service = "sidecar", exclude = ["*.tmp"]}]',
        )
        self.json("config.json", {"agent": {"model_name": "model"}, "artifacts": ["/extra.txt"]})
        entry = {
            "source": "/reports",
            "destination": "artifacts/reports",
            "service": "sidecar",
            "exclude": ["*.tmp"],
            "type": "directory",
            "status": "ok",
        }
        for name in names:
            self.write(f"steps/{name}/artifacts/reports/result.txt", "report")
            self.write(f"steps/{name}/artifacts/extra.txt", "extra")
            self.json(
                f"steps/{name}/artifacts/manifest.json",
                [
                    entry,
                    {
                        "source": "/app/result.py",
                        "destination": "artifacts/app/result.py",
                        "type": "file",
                        "status": "ok",
                    },
                    {"source": "/extra.txt", "destination": "artifacts/extra.txt", "type": "file", "status": "ok"},
                ],
            )
        self.assertTrue(assess_trial(self.trial)["complete"])
        manifest_path = f"steps/{names[2]}/artifacts/manifest.json"
        manifest = json.loads((self.trial / manifest_path).read_text())
        for change in (
            {"service": "main"},
            {"destination": "artifacts/elsewhere"},
            {"exclude": []},
            {"type": "file"},
            {"status": "failed"},
            {"destination": "../escape"},
        ):
            with self.subTest(change=change):
                self.json(manifest_path, [{**entry, **change}, *manifest[1:]])
                self.assertFalse(assess_trial(self.trial)["complete"])
        self.json(manifest_path, manifest[:-1])
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_missing_reordered_duplicate_and_unexpected_results_are_incomplete(self):
        names, harbor = self.checkpoints()
        results = harbor["step_results"]
        for changed in (
            [],
            results[:-1],
            [results[1], results[0], *results[2:]],
            [results[0], results[0], *results[2:]],
            [*results, results[-1]],
        ):
            with self.subTest(results=[result["step_name"] for result in changed]):
                self.json("result.json", {**harbor, "step_results": changed})
                self.assertFalse(assess_trial(self.trial)["complete"])
        self.json("result.json", harbor)
        shutil.rmtree(self.trial / "steps" / names[-1])
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_reward_gated_stop_is_explicit_and_does_not_require_unattempted_archives(self):
        names, harbor = self.checkpoints(step_options="min_reward = 1")
        for name in names[1:]:
            shutil.rmtree(self.trial / "steps" / name)
        harbor["step_results"] = harbor["step_results"][:1]
        self.json("result.json", harbor)
        report = save_assessment(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        self.assertTrue(report["steps"][0]["attempted"])
        self.assertEqual([step["attempted"] for step in report["steps"]], [True, False, False, False])
        self.assertEqual(report["steps"][1]["reason"], "Checkpoint reward below min_reward")
        with contextlib.redirect_stdout(io.StringIO()):
            check_evidence(self.trial)
        harbor["step_results"][0]["verifier_result"] = {"rewards": {"reward": 1}}
        self.json("result.json", harbor)
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_checkpoint_exception_cannot_hide_missing_attempted_evidence(self):
        names, harbor = self.checkpoints()
        for name in names[1:]:
            shutil.rmtree(self.trial / "steps" / name)
        failed = harbor["step_results"][0]
        failed["exception_info"] = {"exception_type": "TimeoutError", "exception_message": "deadline"}
        failed["verifier_result"] = None
        harbor["step_results"] = [failed]
        self.json("result.json", harbor)
        report = assess_trial(self.trial)
        self.assertTrue(report["complete"], report["issues"])
        self.assertEqual(report["steps"][1]["reason"], "Checkpoint exception")
        (self.trial / f"steps/{names[0]}/agent/runtime.json").unlink()
        self.assertFalse(assess_trial(self.trial)["complete"])

    def test_provenance_tampering_and_checkpoint_symlinks_are_incomplete(self):
        names, _ = self.checkpoints()
        self.write(f"provenance/task/steps/{names[1]}/instruction.md", "tampered")
        self.assertIn("Retained task files are missing or changed", " ".join(assess_trial(self.trial)["issues"]))
        for relative in (
            f"steps/{names[1]}",
            f"steps/{names[2]}/agent",
            f"steps/{names[2]}/artifacts",
            f"steps/{names[2]}/verifier",
        ):
            path = self.trial / relative
            moved = self.trial.parent / "outside"
            path.rename(moved)
            path.symlink_to(moved, target_is_directory=True)
            with self.subTest(path=relative):
                self.assertIn("symlink", " ".join(assess_trial(self.trial)["issues"]))
            path.unlink()
            moved.rename(path)

    def test_unsafe_and_colliding_checkpoint_names_never_select_other_directories(self):
        names, _ = self.checkpoints()
        task = self.trial / "provenance/task"
        for name in ("../escape", "/tmp/outside", "..", "checkpoint_1", "CHECKPOINT_1", "bad\\name", "CON", "bad:name"):
            (task / "task.toml").write_text('[[steps]]\nname = "checkpoint_1"\n[[steps]]\nname = ' + json.dumps(name))
            reproduction_path = self.trial / "provenance/reproduction.json"
            reproduction = json.loads(reproduction_path.read_text())
            reproduction["task_files"] = inventory(task)
            write_json(reproduction_path, reproduction)
            with self.subTest(name=name):
                report = assess_trial(self.trial)
                self.assertFalse(report["complete"])
                self.assertIn("provenance/task/task.toml:", " ".join(report["issues"]))


class PluginTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipIf(
        find_spec("harbor") is None or find_spec("dirhash") is None, "Requires Harbor and its task checksum dependency"
    )
    async def test_task_and_source_snapshot_retain_changes_without_mutating_inputs(self):
        from dirhash import dirhash
        from harbor.models.task.config import TaskOS
        from harbor.models.trial.paths import EnvironmentPaths, TrialPaths
        from harbor.trial.trial import Trial

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            task = root / "task"
            repository.mkdir()
            task.mkdir()
            (task / "instruction.md").write_text("instruction")
            (task / "task.toml").write_text("")
            (task / "solution").mkdir()
            (task / "solution/solve.sh").write_text("reference")
            (task / "tests").mkdir()
            (task / "tests/test.sh").write_text("private verifier")
            (task / "steps/checkpoint_2").mkdir(parents=True)
            (task / "steps/checkpoint_2/instruction.md").write_text("future requirements")
            (repository / "Package.resolved").write_text("{}")
            (repository / "script/harbor").mkdir(parents=True)
            (repository / "script/harbor/uv.lock").write_text("locked dependencies")
            (repository / "new.py").write_text("untracked source")
            binary = repository / "runner"
            binary.write_text("binary")
            for name, definition in (("single", ""), ("multi", '[[steps]]\nname = "checkpoint_1"\n')):
                with self.subTest(name=name):
                    (task / "task.toml").write_text(definition)
                    checksum = dirhash(task, "sha256")
                    event = SimpleNamespace(
                        trial_name=name,
                        trial_id="id",
                        config=SimpleNamespace(
                            trials_dir=root / "job", agent=SimpleNamespace(kwargs={"binary": str(binary)})
                        ),
                        lock=SimpleNamespace(task=SimpleNamespace(type="local")),
                        result=SimpleNamespace(
                            task_id=SimpleNamespace(get_local_path=lambda: task), task_checksum=checksum
                        ),
                    )
                    with (
                        patch(
                            "script.harbor.evidence.command",
                            side_effect=[b"commit\n", b"working patch", b"new.py\0", b"Swift version"],
                        ),
                        patch("script.harbor.evidence.version", return_value="0.24.0"),
                    ):
                        prepare_trial(event, repository)
                    trial = root / "job" / name
                    agent = trial / "agent"
                    write_json(agent / "runtime.json", {"schemaVersion": 1})
                    provenance = trial / "provenance"
                    reproduction = json.loads((provenance / "reproduction.json").read_text())
                    python = reproduction["python"]
                    self.assertEqual(python["version"], sys.version)
                    self.assertEqual(python["executable"], sys.executable)
                    self.assertIn("pydantic", python["packages"])
                    self.assertEqual(python["uv_lock"]["sha256"], hashlib.sha256(b"locked dependencies").hexdigest())
                    mounts = Trial._agent_env_mounts.fget(
                        SimpleNamespace(
                            task=SimpleNamespace(config=SimpleNamespace(environment=SimpleNamespace(os=TaskOS.LINUX))),
                            paths=TrialPaths(trial_dir=trial),
                            agent_env_paths=EnvironmentPaths(),
                            user_agent=None,
                            _main_artifacts_mount_dir=trial / "artifacts/logs/artifacts",
                            config=SimpleNamespace(environment=SimpleNamespace(mounts=[])),
                        )
                    )
                    for mount in mounts:
                        source = Path(mount["source"])
                        self.assertFalse(source == provenance or source in provenance.parents)
                        source.mkdir(parents=True, exist_ok=True)
                        contents = inventory(source)
                        self.assertFalse(
                            any(
                                name in contents
                                for name in (
                                    "task",
                                    "task/tests/test.sh",
                                    "task/solution/solve.sh",
                                    "task/steps/checkpoint_2/instruction.md",
                                    "reproduction.json",
                                    "source.patch",
                                )
                            )
                        )
                    if name == "multi":
                        archived = trial / "steps/checkpoint_1/agent"
                        archived.parent.mkdir(parents=True)
                        agent.rename(archived)
                        agent = archived
                    provenance = trial / "provenance"
                    self.assertEqual((provenance / "task/solution/solve.sh").read_text(), "reference")
                    self.assertEqual((provenance / "source-untracked/new.py").read_text(), "untracked source")
                    self.assertEqual((provenance / "source.patch").read_text(), "working patch")
                    self.assertEqual(dirhash(task, "sha256"), checksum)
                    self.assertFalse(json.loads((agent / "completeness.json").read_text())["complete"])
                    reproduction = json.loads((provenance / "reproduction.json").read_text())
                    for pointer, target in (
                        (reproduction["source_at_run"]["patch"], provenance / "source.patch"),
                        (reproduction["source_at_run"]["untracked"], provenance / "source-untracked"),
                        (reproduction["runtime_metadata"], agent / "runtime.json"),
                    ):
                        self.assertEqual(trial / pointer, target)
                        self.assertTrue((trial / pointer).exists())

    @unittest.skipIf(
        find_spec("harbor") is None or find_spec("dirhash") is None, "Requires Harbor and its task checksum dependency"
    )
    async def test_hub_snapshot_uses_locked_digest_and_checks_contents(self):
        from dirhash import dirhash
        from harbor.models.job.lock import TaskLock
        from harbor.models.trial.config import TaskConfig

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()
            (repository / "Package.resolved").write_text("{}")
            (repository / "script/harbor").mkdir(parents=True)
            (repository / "script/harbor/uv.lock").write_text("locked dependencies")
            binary = repository / "runner"
            binary.write_text("binary")
            digest = "sha256:" + "a" * 64
            lock = TaskLock(name="terminal-bench/regex-chess", type="package", digest=digest)
            for download_dir in (None, root / "downloads"):
                cache = download_dir or root / "cache"
                task = cache / "terminal-bench/regex-chess" / digest.removeprefix("sha256:")
                task.mkdir(parents=True)
                (task / "instruction.md").write_text("instruction")
                (task / "task.toml").write_text("")
                checksum = dirhash(task, "sha256")
                config = TaskConfig(name=lock.name, ref="latest", download_dir=download_dir)
                for changed in (False, True):
                    with self.subTest(download_dir=download_dir, changed=changed):
                        trial_name = f"{cache.name}-{changed}"
                        task_id = config.get_task_id()
                        event = SimpleNamespace(
                            trial_name=trial_name,
                            trial_id="id",
                            config=SimpleNamespace(
                                trials_dir=root / "job",
                                task=config,
                                agent=SimpleNamespace(kwargs={"binary": str(binary)}),
                            ),
                            lock=SimpleNamespace(task=lock),
                            result=SimpleNamespace(task_id=task_id, task_checksum="changed" if changed else checksum),
                        )
                        with (
                            patch("harbor.models.task.id.PACKAGE_CACHE_DIR", root / "cache"),
                            patch(
                                "script.harbor.evidence.command",
                                side_effect=[b"commit\n", b"working patch", b"", b"Swift version"],
                            ) as command,
                            patch("script.harbor.evidence.version", return_value="0.24.0"),
                        ):
                            if changed:
                                with self.assertRaisesRegex(ValueError, "Task changed after Harbor planned"):
                                    prepare_trial(event, repository)
                                command.assert_not_called()
                            else:
                                prepare_trial(event, repository)
                                provenance = root / "job" / trial_name / "provenance"
                                self.assertEqual(inventory(provenance / "task"), inventory(task))
                                reproduction = json.loads((provenance / "reproduction.json").read_text())
                                self.assertEqual(reproduction["task_checksum"], checksum)
                        self.assertEqual(task_id.ref, "latest")

    async def test_capture_needs_no_recipe_paths_and_hooks_run_after_trial_and_job(self):
        with patch("script.harbor.evidence.version", side_effect=AssertionError("Unexpected package version check")):
            plugin = EvidencePlugin()
            job = SimpleNamespace(
                config=SimpleNamespace(artifacts=[]),
                job_dir=Path("job"),
                on_trial_started=lambda hook: None,
                on_trial_ended=lambda hook: None,
            )
            await plugin.on_job_start(job)
            with (
                patch("script.harbor.evidence.save_assessment", return_value={"complete": False}),
                patch("script.harbor.agent.SumikaAgent.close_trial_worker", AsyncMock(), create=True),
            ):
                await plugin.ended(SimpleNamespace(config=SimpleNamespace(trials_dir=Path("job")), trial_name="trial"))

    async def test_job_end_finds_checkpoints_after_root_agent_directory_is_archived(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "trial/steps/checkpoint_1/agent").mkdir(parents=True)
            plugin = EvidencePlugin()
            plugin.job_dir = root
            with (
                patch("script.harbor.evidence.save_assessment", return_value={"complete": True}) as save,
                patch("script.harbor.agent.SumikaAgent.close_trial_worker", AsyncMock(), create=True) as close,
            ):
                await plugin.on_job_end(None)
            close.assert_awaited_once_with(root / "trial")
            save.assert_called_once_with(root / "trial")

    async def test_trial_end_closes_early_stopped_worker_without_assessing_evidence(self):
        plugin = EvidencePlugin()
        event = SimpleNamespace(
            config=SimpleNamespace(trials_dir=Path("job")),
            trial_name="trial",
            result=SimpleNamespace(step_results=[{"step_name": "checkpoint_1"}]),
        )
        with (
            patch("script.harbor.agent.SumikaAgent.close_trial_worker", AsyncMock(), create=True) as close,
            patch("script.harbor.evidence.save_assessment") as assess,
        ):
            await plugin.ended(event)
        close.assert_awaited_once_with(Path("job/trial"))
        assess.assert_not_called()

    async def test_job_end_hashes_final_checkpoint_logs_and_cli_independently_rechecks_content(self):
        fixture = CheckpointEvidenceTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        marker = {"schema_version": 1, "complete": False, "issues": ["Trial has not finished."]}
        fixture.json("agent/completeness.json", marker)
        names, _ = fixture.checkpoints()
        marker_path = fixture.trial / "steps" / names[0] / "agent/completeness.json"
        marker_contents = marker_path.read_bytes()
        plugin = EvidencePlugin()
        plugin.job_dir = fixture.trial.parent
        event = SimpleNamespace(config=SimpleNamespace(trials_dir=plugin.job_dir), trial_name=fixture.trial.name)
        targets = [fixture.trial / f"steps/{name}/artifacts/app/result.py" for name in names]
        targets.append(fixture.trial / "provenance/task/task.toml")
        with (
            patch("script.harbor.agent.SumikaAgent.close_trial_worker", AsyncMock(), create=True),
            patch("script.harbor.evidence.hashlib.file_digest", wraps=hashlib.file_digest) as digest,
        ):
            await plugin.ended(event)
            digest.assert_not_called()
            self.assertEqual(marker_path.read_bytes(), marker_contents)
            self.assertFalse((fixture.trial / "agent").exists())
            final_log = f"steps/{names[-1]}/agent/runner.log"
            fixture.write(final_log, "final scrubbed logs\n")
            await plugin.on_job_end(None)
            report = json.loads((fixture.trial / "agent/completeness.json").read_text())
            self.assertTrue(report["complete"], report["issues"])
            self.assertEqual(report["files"][final_log]["sha256"], hashlib.sha256(b"final scrubbed logs\n").hexdigest())
            hashed = [Path(call.args[0].name) for call in digest.call_args_list]
            self.assertEqual([hashed.count(path) for path in targets], [1] * len(targets))
            with contextlib.redirect_stdout(io.StringIO()):
                check_evidence(fixture.trial.parent)
            hashed = [Path(call.args[0].name) for call in digest.call_args_list]
            self.assertEqual([hashed.count(path) for path in targets], [2] * len(targets))
        artifact = fixture.trial / f"steps/{names[-1]}/artifacts/app/result.py"
        before = artifact.stat()
        artifact.write_bytes(b"changed!")
        os.utime(artifact, ns=(before.st_atime_ns, before.st_mtime_ns))
        after = artifact.stat()
        self.assertEqual(
            (before.st_ino, before.st_size, before.st_mtime_ns), (after.st_ino, after.st_size, after.st_mtime_ns)
        )
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "changed evidence"):
            check_evidence(fixture.trial)

    async def test_environment_records_image_ids_without_environment_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            config = SimpleNamespace(workdir="/app", cpus=1, memory_mb=512, storage_mb=1024, network_mode="no-network")
            environment = SimpleNamespace(
                task_env_config=config,
                runtime=lambda: SimpleNamespace(engine=("docker",), engine_cmd=lambda *args: ["docker", *args]),
                _run_docker_compose_command=AsyncMock(return_value=SimpleNamespace(stdout="image-id\n")),
            )
            image = {
                "Id": "sha256:actual",
                "RepoDigests": ["image@sha256:digest"],
                "Config": {"Env": ["TOKEN=private"]},
            }
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
        self.task = self.logs.parent / "provenance/task"
        self.task.mkdir(parents=True)
        (self.task / "task.toml").write_text("")
        self.remote = self.root / "remote"
        (self.remote / "app").mkdir(parents=True)
        (self.remote / "app/result.csv").write_text("answer")
        (self.remote / "logs/artifacts").mkdir(parents=True)
        self.logger = logging.getLogger("sumika-artifacts-test")

        async def download_directory(source_dir, target_dir, **_kwargs):
            shutil.copytree(self.remote / source_dir.lstrip("/"), target_dir, dirs_exist_ok=True, symlinks=True)

        self.environment = SimpleNamespace(
            is_path_mounted=lambda *_args: False,
            exec=AsyncMock(
                side_effect=lambda *_args, **_kwargs: SimpleNamespace(
                    return_code=(
                        4 if (self.remote / "output").is_symlink() else 0 if (self.remote / "output").exists() else 3
                    )
                )
            ),
            service_is_dir=AsyncMock(side_effect=lambda path, **_kwargs: (self.remote / path.lstrip("/")).is_dir()),
            service_download_dir=AsyncMock(side_effect=download_directory),
        )

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
                    self.environment, artifacts, source_artifacts_dir=EnvironmentPaths.artifacts_dir
                )
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
        (self.task / "task.toml").write_text('artifacts = ["/app/result.csv"]\n')
        await capture_legacy_artifacts(self.environment, self.logs, self.logger, "/")
        self.environment.exec.assert_not_awaited()
        self.environment.service_download_dir.assert_not_awaited()
        self.assertFalse((self.logs.parent / "artifacts").exists())

    async def test_cached_checkpoint_declarations_survive_archived_task_files(self):
        from harbor.models.task.config import TaskConfig

        task = TaskConfig.model_validate_toml(
            '[[steps]]\nname = "declared"\nartifacts = ["/app/result.csv"]\n[[steps]]\nname = "legacy"\n'
        )
        shutil.rmtree(self.task)
        await capture_legacy_artifacts(
            self.environment, self.logs, self.logger, "/", task_config=task, step_name="declared"
        )
        self.environment.exec.assert_not_awaited()
        self.environment.service_download_dir.assert_not_awaited()
        await capture_legacy_artifacts(
            self.environment, self.logs, self.logger, "/app", task_config=task, step_name="legacy"
        )
        manifest = json.loads((self.logs.parent / "artifacts/manifest.json").read_text())
        self.assertIn("/app", {entry["source"] for entry in manifest})
        with self.assertLogs(self.logger, level="ERROR"):
            await capture_legacy_artifacts(
                self.environment, self.logs, self.logger, "/app", task_config=task, step_name="unknown"
            )
        self.assertIn("Unknown checkpoint", (self.logs / "artifact-error.json").read_text())

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
