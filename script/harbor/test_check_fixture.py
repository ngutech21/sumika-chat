"""Fixture reward checks do not require Harbor, Docker, or a model."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from script.harbor.check_fixture import check_fixture


class FixtureCheckTests(unittest.TestCase):
    def run_check(self, agent_to_change=None, changes=None, trial_count=1, command_failure=False):
        calls = []

        def run(command, *, check):
            self.assertTrue(check)
            agent = command[command.index("-a") + 1]
            calls.append(agent)
            if agent == agent_to_change and command_failure:
                raise subprocess.CalledProcessError(1, command)
            jobs_dir = Path(command[command.index("--jobs-dir") + 1])
            job_name = command[command.index("--job-name") + 1]
            result = {"finished_at": "2026-10-13T00:00:00Z", "exception_info": None,
                      "verifier_result": {"rewards": {"reward": 0 if agent == "nop" else 1}}}
            if agent == agent_to_change:
                result.update(changes or {})
            for trial in range(trial_count if agent == agent_to_change else 1):
                path = jobs_dir / job_name / f"trial-{trial}" / "result.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(result))
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            stale = Path("tmp/harbor/baseline/old-job/trial/result.json")
            stale.parent.mkdir(parents=True)
            stale.write_text(json.dumps({"verifier_result": {"rewards": {"reward": 0}}}))
            with patch("script.harbor.check_fixture.subprocess.run", side_effect=run):
                with contextlib.redirect_stdout(io.StringIO()):
                    check_fixture()
        return calls

    def test_matching_rewards_pass_in_order(self):
        self.assertEqual(self.run_check(), ["nop", "oracle"])

    def test_wrong_missing_and_boolean_rewards_fail_for_each_agent(self):
        for agent in ("nop", "oracle"):
            for reward in (1 if agent == "nop" else 0, None, False, True, "0", "1"):
                with self.subTest(agent=agent, reward=reward):
                    with self.assertRaisesRegex(RuntimeError, "expected reward"):
                        self.run_check(agent, {"verifier_result": {"rewards": {"reward": reward}}})

    def test_failed_incomplete_and_unverified_trials_fail(self):
        for changes in ({"finished_at": None}, {"exception_info": {"exception_type": "Failure"}},
                        {"verifier_result": None}, {"verifier_result": {"rewards": None}}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.run_check("nop", changes)

    def test_missing_or_multiple_fresh_results_fail_despite_stale_success(self):
        for count in (0, 2):
            with self.subTest(count=count), self.assertRaisesRegex(RuntimeError, "one trial result"):
                self.run_check("nop", trial_count=count)

    def test_harbor_command_failure_is_propagated(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_check("nop", command_failure=True)


if __name__ == "__main__":
    unittest.main()
