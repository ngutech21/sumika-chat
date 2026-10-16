"""Run Harbor fixture or suite baselines and require their expected verifier rewards."""

import argparse
import json
import subprocess
import uuid
from pathlib import Path


def check_baselines(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset")
    parser.add_argument("tasks", nargs="+")
    args = parser.parse_args(argv)
    if args.dataset:
        task_names = args.tasks
        task_args = ["-d", args.dataset, "-e", "docker", "--agent-timeout-multiplier", "6"]
        for name in task_names:
            task_args.extend(["-i", name])
        prefix = "suite-"
    else:
        if len(args.tasks) != 1:
            parser.error("Without --dataset, provide exactly one local task path.")
        task_names = [Path(args.tasks[0]).name]
        task_args = ["-p", args.tasks[0]]
        prefix = "fixture-"
    if len(set(task_names)) != len(task_names):
        parser.error("Task names must be unique.")

    job_name = prefix + uuid.uuid4().hex
    for agent, expected, folder in (("nop", 0, "baseline"), ("oracle", 1, "oracle")):
        jobs_dir = Path("tmp/harbor") / folder
        subprocess.run(
            [
                "harbor",
                "run",
                *task_args,
                "-a",
                agent,
                "-n",
                "1",
                "-k",
                "1",
                "--job-name",
                job_name,
                "--jobs-dir",
                str(jobs_dir),
            ],
            check=True,
        )
        results = list((jobs_dir / job_name).glob("*/result.json"))
        if len(results) != len(task_names):
            raise RuntimeError(
                f"{agent}: expected {len(task_names)} trial results in {jobs_dir / job_name}, got {len(results)}."
            )
        remaining = set(task_names)
        for result_path in sorted(results):
            result = json.loads(result_path.read_text())
            name = result.get("task_name")
            if name not in remaining:
                raise RuntimeError(f"{agent}: unexpected or duplicate task {name!r}; inspect {result_path}.")
            remaining.remove(name)
            if not result.get("finished_at") or result.get("exception_info") is not None:
                raise RuntimeError(f"{agent}: {name} failed or did not finish; inspect {result_path}.")
            rewards = (result.get("verifier_result") or {}).get("rewards") or {}
            reward = rewards.get("reward")
            if type(reward) not in (int, float) or reward != expected:
                raise RuntimeError(
                    f"{agent}: {name} expected reward {expected}, got {reward!r}; inspect {result_path}."
                )
            print(f"{agent}: {name} reward {reward} matches expected {expected}.")


if __name__ == "__main__":
    check_baselines()
