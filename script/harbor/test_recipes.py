"""Harbor recipe checks use fake launchers without building or running a model."""

import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from harbor.cli.main import app
from harbor.models.job.config import JobConfig
from typer.testing import CliRunner

ROOT = Path(__file__).resolve().parents[2]
JUST = shutil.which("just")
AUTH_TOKEN = (
    "openthoughts/auth_token_race_condition@sha256:3f944adfbb5ef321ba179db84f82ee9500262971de02eea66d8ebd09b74b7984"
)
FILE_BACKUP = "gabeorlanski/file_backup@sha256:fd2acb76c0afcfc1b9bba10a8500e5ef3f51a8178373dcaa6da808011c6b499c"
RESUME_RECIPE = "run-harbor-file-backup-resume"
EXISTING_RECIPES = (
    "run-harbor-smoke-test",
    "run-harbor",
    "run-harbor-file-backup",
    "run-harbor-suite",
)


@unittest.skipUnless(JUST, "just is required for recipe checks")
class HarborRecipeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name).resolve()
        (self.directory / "script").symlink_to(ROOT / "script", target_is_directory=True)
        self.log = self.directory / "calls.jsonl"
        launchers = self.directory / "bin"
        launchers.mkdir()
        script = (
            f"#!{sys.executable}\n"
            + """
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
with Path(os.environ["HARBOR_RECIPE_LOG"]).open("a") as log:
    log.write(json.dumps({"command": command, "args": sys.argv[1:],
                          "telemetry": os.environ.get("HARBOR_TELEMETRY")}) + "\\n")
if command == "uuidgen":
    print("recipe-test-job")
elif command == "swift":
    sys.exit(int(os.environ.get("HARBOR_RECIPE_BUILD_STATUS", "0")))
elif command == "uv":
    status = "HARBOR_RECIPE_RUN_STATUS" if "harbor" in sys.argv else "HARBOR_RECIPE_CHECK_STATUS"
    sys.exit(int(os.environ.get(status, "0")))
"""
        )
        for name in ("swift", "uv", "uuidgen"):
            path = launchers / name
            path.write_text(script)
            path.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{launchers}{os.pathsep}{os.environ.get('PATH', '')}",
            "HARBOR_RECIPE_LOG": str(self.log),
        }
        self.just = [JUST, "--justfile", str(ROOT / "Justfile"), "--working-directory", str(self.directory)]

    def run_recipe(self, recipe, *, run_status=0, check_status=0, build_status=0):
        self.log.unlink(missing_ok=True)
        environment = {
            **self.environment,
            "HARBOR_RECIPE_RUN_STATUS": str(run_status),
            "HARBOR_RECIPE_CHECK_STATUS": str(check_status),
            "HARBOR_RECIPE_BUILD_STATUS": str(build_status),
        }
        result = subprocess.run(self.just + [recipe], env=environment, text=True, capture_output=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls

    def assert_run(self, calls):
        self.assertEqual(calls[0]["command"], "swift")
        self.assertEqual(calls[0]["args"], ["build", "--configuration", "release", "--product", "SumikaEval"])
        self.assertEqual([call["command"] for call in calls], ["swift", "uuidgen", "uv", "uv"])
        run, check = calls[2:]
        args = run["args"]
        self.assertEqual(args[:6], ["run", "--project", "script/harbor", "--locked", "harbor", "run"])
        self.assertEqual(args.count("--config"), 1)
        self.assertEqual(args[args.index("--config") + 1], "script/harbor/sumika.yaml")
        self.assertEqual(args[args.index("--plugin") + 1], "script.harbor.evidence:EvidencePlugin")
        with contextlib.chdir(self.directory):
            resolved = CliRunner().invoke(app, ["run", *args[6:], "--print-config"], env={"HARBOR_TELEMETRY": "0"})
        self.assertEqual(resolved.exit_code, 0, resolved.output)
        config = JobConfig.model_validate_json(resolved.stdout)
        self.assertEqual(config.n_concurrent_trials, 1)
        self.assertEqual(config.n_attempts, 1)
        self.assertEqual(config.environment.type, "docker")
        self.assertTrue(config.environment.delete)
        self.assertEqual(len(config.agents), 1)
        agent = config.agents[0]
        self.assertEqual(agent.import_path, "script.harbor.agent:SumikaAgent")
        self.assertEqual(agent.model_name, "Swift-1.5-4bit-MLX")
        self.assertEqual(agent.kwargs, {"binary": ".build/release/SumikaEval", "reasoning_effort": "low"})
        self.assertEqual(run["telemetry"], "0")
        self.assertEqual(config.jobs_dir, Path(".harbor"))
        self.assertEqual(config.job_name, "recipe-test-job")
        job = str(self.directory / config.jobs_dir / config.job_name)
        self.assertEqual(
            check["args"],
            ["run", "--project", "script/harbor", "--locked", "python", "-B", "-m", "script.harbor.evidence", job],
        )
        return config

    def test_shared_config_preserves_each_recipe_selection_timeout_and_resume(self):
        dataset = subprocess.check_output(self.just + ["--evaluate", "harbor_suite_dataset"], text=True).strip()
        task_names = subprocess.check_output(self.just + ["--evaluate", "harbor_suite_tasks"], text=True).split()
        for recipe in (*EXISTING_RECIPES, RESUME_RECIPE):
            with self.subTest(recipe=recipe):
                result, calls = self.run_recipe(recipe)
                self.assertEqual(result.returncode, 0, result.stderr)
                config = self.assert_run(calls)
                self.assertEqual(config.timeout_multiplier, 1)
                self.assertIsNone(config.verifier_timeout_multiplier)
                self.assertEqual(config.agents[0].resume_trajectory, recipe == RESUME_RECIPE)
                if recipe == "run-harbor-suite":
                    self.assertEqual(config.tasks, [])
                    self.assertEqual(len(config.datasets), 1)
                    self.assertEqual(f"{config.datasets[0].name}@{config.datasets[0].ref}", dataset)
                    self.assertEqual(config.datasets[0].task_names, task_names)
                    self.assertEqual(config.agent_timeout_multiplier, 6)
                else:
                    self.assertEqual(config.datasets, [])
                    self.assertEqual(len(config.tasks), 1)
                    if recipe == "run-harbor-smoke-test":
                        self.assertEqual(config.tasks[0].path, Path("script/harbor/tasks/merge-ranges"))
                        self.assertIsNone(config.agent_timeout_multiplier)
                    else:
                        expected = AUTH_TOKEN if recipe == "run-harbor" else FILE_BACKUP
                        self.assertEqual(f"{config.tasks[0].name}@{config.tasks[0].ref}", expected)
                        self.assertEqual(config.agent_timeout_multiplier, 6 if recipe == "run-harbor" else 1)

    def test_show_and_dry_run_only_resume_recipe_adds_resume(self):
        for recipe in (*EXISTING_RECIPES, RESUME_RECIPE):
            for mode in ("--show", "--dry-run"):
                with self.subTest(recipe=recipe, mode=mode):
                    result = subprocess.run(
                        self.just + [mode, recipe], env=self.environment, text=True, capture_output=True
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual("--resume-trajectory" in result.stdout + result.stderr, recipe == RESUME_RECIPE)
                    self.assertFalse(self.log.exists())

    def test_resume_keeps_default_recipe_arguments(self):
        invocations = []
        for recipe in ("run-harbor-file-backup", RESUME_RECIPE):
            result, calls = self.run_recipe(recipe)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_run(calls)
            invocations.append(calls[2]["args"])
        self.assertNotIn("--resume-trajectory", invocations[0])
        self.assertEqual(invocations[1].count("--resume-trajectory"), 1)
        self.assertEqual([arg for arg in invocations[1] if arg != "--resume-trajectory"], invocations[0])

    def test_evidence_runs_after_harbor_failure_and_exit_status_is_preserved(self):
        for recipe in (*EXISTING_RECIPES, RESUME_RECIPE):
            for run_status, check_status, expected in ((17, 0, 17), (0, 23, 1), (17, 23, 1)):
                with self.subTest(recipe=recipe, run_status=run_status, check_status=check_status):
                    result, calls = self.run_recipe(recipe, run_status=run_status, check_status=check_status)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assert_run(calls)

    def test_build_failure_stops_before_harbor(self):
        for recipe in (*EXISTING_RECIPES, RESUME_RECIPE):
            with self.subTest(recipe=recipe):
                result, calls = self.run_recipe(recipe, build_status=19)
                self.assertEqual(result.returncode, 19, result.stderr)
                self.assertEqual([call["command"] for call in calls], ["swift"])

    def test_python_gate_is_locked_and_propagates_failures(self):
        for status in (0, 23):
            with self.subTest(status=status):
                result, calls = self.run_recipe("test-harbor-python", check_status=status)
                self.assertEqual(result.returncode == 0, status == 0, result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertEqual(
                    calls[0]["args"],
                    [
                        "run",
                        "--project",
                        "script/harbor",
                        "--locked",
                        "python",
                        "-B",
                        "-m",
                        "unittest",
                        "discover",
                        "-s",
                        "script/harbor",
                        "-v",
                    ],
                )
                self.assertEqual(calls[0]["telemetry"], "0")

    def test_check_gate_runs_lint_build_and_both_test_suites(self):
        self.just += ["--set", "swift", "swift"]
        result, calls = self.run_recipe("check-harbor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["command"] for call in calls], ["uv", "uv", "uv", "swift", "uv", "swift"])
        self.assertEqual(
            calls[0]["args"], ["run", "--project", "script/harbor", "--locked", "ruff", "check", "script/harbor"]
        )
        self.assertEqual(
            calls[1]["args"],
            ["run", "--project", "script/harbor", "--locked", "ruff", "format", "--check", "script/harbor"],
        )
        self.assertEqual(
            calls[2]["args"],
            ["run", "--project", "script/harbor", "--locked", "mypy", "--config-file", "script/harbor/pyproject.toml"],
        )
        self.assertEqual(calls[3]["args"], ["build", "--configuration", "release", "--product", "SumikaEval"])
        self.assertEqual(calls[-1]["args"], ["test", "--filter", "SumikaEvalTests"])


if __name__ == "__main__":
    unittest.main()
