"""Check the analyzer recipe without compiling or running SwiftLint."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PHASES = ("prepare", "xcode", "clean", "build", "analyze")
MOCK = """
import json
import os
from pathlib import Path
import shutil
import signal
import sys

directory = Path(os.environ["LINT_ANALYZE_TEST_DIR"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
if command == "xcodebuild":
    phase = "xcode"
elif command == "swiftlint":
    phase = "analyze"
elif "--package-path" in args:
    phase = "prepare"
else:
    phase = "clean" if "clean" in args else "build"
with (directory / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps({"phase": phase, "args": args}) + "\\n")
print(phase + " stdout", flush=True)
print(phase + " stderr", file=sys.stderr, flush=True)
if phase == "analyze":
    compiler_log = args[args.index("--compiler-log-path") + 1]
    shutil.copyfile(compiler_log, directory / "compiler-at-analysis.log")
    if os.environ.get("LINT_ANALYZE_TEST_INTERRUPT") == "1":
        os.kill(os.getppid(), signal.SIGTERM)
        sys.exit(143)
sys.exit(17 if phase == os.environ.get("LINT_ANALYZE_TEST_FAIL") else 0)
"""


class LintAnalyzeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sumika lint analyze ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        launchers = self.directory / "bin"
        launchers.mkdir()
        for name in ("swift", "xcodebuild", "swiftlint"):
            command = launchers / name
            command.write_text(f"#!{sys.executable}\n" + MOCK)
            command.chmod(0o755)
        self.environment = dict(
            os.environ,
            PATH=f"{launchers}{os.pathsep}{os.environ['PATH']}",
            LINT_ANALYZE_TEST_DIR=str(self.directory),
            CLONED_SOURCE_PACKAGES_DIR_PATH="cached packages",
            SKIP_PACKAGE_PLUGIN_VALIDATION="1",
        )
        self.logs = self.directory / "build/lint-analyze-logs"

    def run_recipe(self, *, fail="", interrupt=False):
        calls = self.directory / "calls.jsonl"
        calls.unlink(missing_ok=True)
        previous = set(self.logs.glob("run.*"))
        result = subprocess.run(
            [
                shutil.which("just"),
                "--justfile",
                str(ROOT / "Justfile"),
                "--working-directory",
                str(self.directory),
                "--set",
                "swift",
                "swift",
                "--set",
                "swiftlint",
                "bin/swiftlint",
                "lint-analyze",
            ],
            env=dict(self.environment, LINT_ANALYZE_TEST_FAIL=fail, LINT_ANALYZE_TEST_INTERRUPT=str(int(interrupt))),
            text=True,
            capture_output=True,
            timeout=10,
        )
        return (
            result,
            set(self.logs.glob("run.*")) - previous,
            [json.loads(line) for line in calls.read_text().splitlines()],
        )

    def test_success_combines_compiler_logs_and_removes_only_its_logs(self):
        self.logs.mkdir(parents=True)
        older = self.logs / "run.previous-failure"
        older.mkdir()
        result, logs, calls = self.run_recipe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["phase"] for call in calls], list(PHASES))
        self.assertEqual(logs, set())
        self.assertTrue(older.exists())
        self.assertEqual(result.stdout.count(": started"), 4)
        self.assertEqual(result.stdout.count(": finished in"), 4)
        compiler_log = (self.directory / "compiler-at-analysis.log").read_text()
        for phase in ("xcode", "clean", "build"):
            self.assertIn(phase + " stdout", compiler_log)
            self.assertIn(phase + " stderr", compiler_log)
        self.assertIn("--build-tests", calls[3]["args"])
        self.assertIn("cached packages", calls[1]["args"])
        self.assertIn("-skipMacroValidation", calls[1]["args"])
        self.assertNotIn("--quiet", calls[4]["args"])

    def test_each_phase_failure_stops_and_preserves_output_and_timings(self):
        for index, phase in enumerate(PHASES[1:], start=1):
            with self.subTest(phase=phase):
                result, logs, calls = self.run_recipe(fail=phase)
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertEqual([call["phase"] for call in calls], list(PHASES[: index + 1]))
                self.assertEqual(len(logs), 1)
                directory = logs.pop()
                output = directory / ("analyzer.log" if phase == "analyze" else "compiler.log")
                self.assertIn(phase + " stdout", output.read_text())
                self.assertIn(phase + " stderr", output.read_text())
                self.assertIn("(exit 17)", (directory / "timings.log").read_text())
                self.assertIn(str(directory), result.stdout)

    def test_interruption_preserves_partial_logs(self):
        result, logs, _ = self.run_recipe(interrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(logs), 1)
        directory = logs.pop()
        self.assertIn("analyze stdout", (directory / "analyzer.log").read_text())
        self.assertIn("xcode stdout", (directory / "compiler.log").read_text())
        timings = (directory / "timings.log").read_text()
        self.assertIn("SwiftLint analysis: started", timings)
        self.assertNotIn("SwiftLint analysis: finished", timings)


if __name__ == "__main__":
    unittest.main()
