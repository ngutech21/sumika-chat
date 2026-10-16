"""Baseline reward checks do not require Harbor, Docker, or a model."""

import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from script.harbor.check_baselines import check_baselines


class BaselineCheckTests(unittest.TestCase):
    suite_tasks = ["openthoughts/log-summary", "openthoughts/pandas-etl"]

    def run_check(
        self,
        agent_to_change=None,
        changes=None,
        returned_tasks=None,
        command_failure=False,
        suite=False,
        malformed=False,
    ):
        calls = []
        task_names = self.suite_tasks if suite else ["merge-ranges"]
        argv = (
            ["--dataset", "openthoughts/openthoughts-tblite", *task_names]
            if suite
            else ["script/harbor/tasks/merge-ranges"]
        )

        def run(command, *, check):
            self.assertTrue(check)
            agent = command[command.index("-a") + 1]
            calls.append(agent)
            self.assertEqual(command[command.index("-n") + 1], "1")
            self.assertEqual(command[command.index("-k") + 1], "1")
            if suite:
                self.assertEqual(command[command.index("-d") + 1], "openthoughts/openthoughts-tblite")
                self.assertEqual([command[i + 1] for i, arg in enumerate(command) if arg == "-i"], task_names)
                self.assertEqual(command[command.index("-e") + 1], "docker")
                self.assertEqual(command[command.index("--agent-timeout-multiplier") + 1], "6")
            else:
                self.assertEqual(command[command.index("-p") + 1], "script/harbor/tasks/merge-ranges")
            if agent == agent_to_change and command_failure:
                raise subprocess.CalledProcessError(1, command)
            jobs_dir = Path(command[command.index("--jobs-dir") + 1])
            job_name = command[command.index("--job-name") + 1]
            names = returned_tasks if agent == agent_to_change and returned_tasks is not None else task_names
            for trial, name in enumerate(names):
                result = {
                    "task_name": name,
                    "finished_at": "2026-10-13T00:00:00Z",
                    "exception_info": None,
                    "verifier_result": {"rewards": {"reward": 0 if agent == "nop" else 1}},
                }
                if agent == agent_to_change and trial == len(names) - 1:
                    result.update(changes or {})
                path = jobs_dir / job_name / f"trial-{trial}" / "result.json"
                path.parent.mkdir(parents=True)
                path.write_text("{" if agent == agent_to_change and malformed else json.dumps(result))
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            stale = Path("tmp/harbor/baseline/old-job/trial/result.json")
            stale.parent.mkdir(parents=True)
            stale.write_text(json.dumps({"verifier_result": {"rewards": {"reward": 0}}}))
            with patch("script.harbor.check_baselines.subprocess.run", side_effect=run):
                with contextlib.redirect_stdout(io.StringIO()):
                    check_baselines(argv)
        return calls

    def test_matching_rewards_pass_in_order(self):
        self.assertEqual(self.run_check(), ["nop", "oracle"])

    def test_suite_runs_both_agents_with_the_same_tasks(self):
        self.assertEqual(self.run_check(suite=True), ["nop", "oracle"])

    def test_wrong_missing_and_boolean_rewards_fail_for_each_agent(self):
        for agent in ("nop", "oracle"):
            for reward in (1 if agent == "nop" else 0, None, False, True, "0", "1"):
                with self.subTest(agent=agent, reward=reward):
                    with self.assertRaisesRegex(RuntimeError, "expected reward"):
                        self.run_check(agent, {"verifier_result": {"rewards": {"reward": reward}}}, suite=True)

    def test_failed_incomplete_and_unverified_trials_fail(self):
        for agent in ("nop", "oracle"):
            for changes in (
                {"finished_at": None},
                {"exception_info": {"exception_type": "Failure"}},
                {"verifier_result": None},
                {"verifier_result": {"rewards": None}},
            ):
                with self.subTest(agent=agent, changes=changes), self.assertRaises(RuntimeError):
                    self.run_check(agent, changes, suite=True)

    def test_missing_or_multiple_fresh_results_fail_despite_stale_success(self):
        for agent in ("nop", "oracle"):
            for names in ([], self.suite_tasks[:1], [*self.suite_tasks, "extra"]):
                with self.subTest(agent=agent, names=names), self.assertRaisesRegex(RuntimeError, "trial results"):
                    self.run_check(agent, returned_tasks=names, suite=True)

    def test_duplicate_unexpected_and_missing_task_names_fail(self):
        for agent in ("nop", "oracle"):
            for name in (self.suite_tasks[0], "other/task", None):
                with self.subTest(agent=agent, name=name), self.assertRaisesRegex(RuntimeError, "task"):
                    self.run_check(agent, {"task_name": name}, suite=True)

    def test_malformed_result_fails(self):
        for agent in ("nop", "oracle"):
            with self.subTest(agent=agent), self.assertRaises(json.JSONDecodeError):
                self.run_check(agent, suite=True, malformed=True)

    def test_empty_or_duplicate_selection_fails_before_running_harbor(self):
        for argv in (
            ["--dataset", "example/suite"],
            ["--dataset", "example/suite", "example/task", "example/task"],
            ["first/path", "second/path"],
        ):
            with self.subTest(argv=argv), patch("script.harbor.check_baselines.subprocess.run") as run:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    check_baselines(argv)
                run.assert_not_called()

    def test_harbor_command_failure_is_propagated(self):
        for agent in ("nop", "oracle"):
            with self.subTest(agent=agent), self.assertRaises(subprocess.CalledProcessError):
                self.run_check(agent, command_failure=True, suite=True)


if __name__ == "__main__":
    unittest.main()
