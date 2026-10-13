"""Run the Harbor fixture baselines and require their expected verifier rewards."""

import json
from pathlib import Path
import subprocess
import uuid


def check_fixture():
    job_name = "fixture-" + uuid.uuid4().hex
    for agent, expected, folder in (("nop", 0, "baseline"), ("oracle", 1, "oracle")):
        jobs_dir = Path("tmp/harbor") / folder
        subprocess.run([
            "harbor", "run", "-p", "script/harbor/tasks/merge-ranges",
            "-a", agent, "-n", "1", "-k", "1", "--job-name", job_name,
            "--jobs-dir", str(jobs_dir),
        ], check=True)
        results = list((jobs_dir / job_name).glob("*/result.json"))
        if len(results) != 1:
            raise RuntimeError(f"{agent}: expected one trial result in {jobs_dir / job_name}.")
        result_path = results[0]
        result = json.loads(result_path.read_text())
        if not result.get("finished_at") or result.get("exception_info") is not None:
            raise RuntimeError(f"{agent}: trial failed or did not finish; inspect {result_path}.")
        rewards = (result.get("verifier_result") or {}).get("rewards") or {}
        reward = rewards.get("reward")
        if type(reward) not in (int, float) or reward != expected:
            raise RuntimeError(
                f"{agent}: expected reward {expected}, got {reward!r}; inspect {result_path}.")
        print(f"{agent}: reward {reward} matches expected {expected}.")


if __name__ == "__main__":
    check_fixture()
