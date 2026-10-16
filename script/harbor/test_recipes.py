"""Harbor recipe checks use fake launchers without building or running a model."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JUST = shutil.which("just")
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
        self.assertEqual(args[:7], ["run", "--project", "script/harbor", "--locked", "harbor", "run", "-t"])
        self.assertEqual(args[args.index("-t") + 1], FILE_BACKUP)
        for flag, value in (
            ("-a", "script.harbor.agent:SumikaAgent"),
            ("-m", "Swift-1.5-4bit-MLX"),
            ("-e", "docker"),
            ("-n", "1"),
            ("-k", "1"),
            ("--agent-timeout-multiplier", "1"),
            ("--plugin", "script.harbor.evidence:EvidencePlugin"),
        ):
            self.assertEqual(args[args.index(flag) + 1], value)
        agent_options = [args[i + 1] for i, flag in enumerate(args) if flag == "--ak"]
        self.assertEqual(agent_options, [f"binary={self.directory}/.build/release/SumikaEval", "reasoning_effort=low"])
        self.assertEqual(run["telemetry"], "0")
        job = str(self.directory / ".harbor" / "recipe-test-job")
        self.assertEqual(args[args.index("--jobs-dir") + 1], str(self.directory / ".harbor"))
        self.assertEqual(args[args.index("--job-name") + 1], "recipe-test-job")
        self.assertEqual(
            check["args"],
            ["run", "--project", "script/harbor", "--locked", "python", "-B", "-m", "script.harbor.evidence", job],
        )
        return args

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
            invocations.append(self.assert_run(calls))
        self.assertNotIn("--resume-trajectory", invocations[0])
        self.assertEqual(invocations[1].count("--resume-trajectory"), 1)
        self.assertEqual([arg for arg in invocations[1] if arg != "--resume-trajectory"], invocations[0])

    def test_evidence_runs_after_harbor_failure_and_exit_status_is_preserved(self):
        for run_status, check_status, expected in ((17, 0, 17), (0, 23, 1), (17, 23, 1)):
            with self.subTest(run_status=run_status, check_status=check_status):
                result, calls = self.run_recipe(RESUME_RECIPE, run_status=run_status, check_status=check_status)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assert_run(calls)

    def test_build_failure_stops_before_harbor(self):
        result, calls = self.run_recipe(RESUME_RECIPE, build_status=19)
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
