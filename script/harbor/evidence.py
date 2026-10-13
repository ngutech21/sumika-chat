"""Per-trial reproduction evidence and a read-only integrity check for Harbor 0.24.0."""

import asyncio
from importlib.metadata import version
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def file_record(path):
    before = path.lstat()
    record = {"mode": stat.S_IMODE(before.st_mode)}
    if stat.S_ISLNK(before.st_mode):
        return {**record, "symlink": os.readlink(path)}
    if stat.S_ISDIR(before.st_mode):
        return {**record, "directory": True}
    if not stat.S_ISREG(before.st_mode):
        raise ValueError(f"Unsupported evidence file: {path}")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    after = path.lstat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError(f"Evidence changed while hashing: {path}")
    return {**record, "bytes": after.st_size, "sha256": digest}


def inventory(root):
    # Never follow workspace symlinks into host files or other task directories.
    result = {}
    errors = []
    for directory, directories, files in os.walk(root, followlinks=False, onerror=errors.append):
        for name in sorted(directories + files):
            path = Path(directory) / name
            result[path.relative_to(root).as_posix()] = file_record(path)
    if errors:
        raise errors[0]
    return result


def command(arguments, cwd=None):
    return subprocess.run(arguments, cwd=cwd, check=True, capture_output=True,
                          timeout=30).stdout


def prepare_trial(event, repository):
    from dirhash import dirhash

    trial = event.config.trials_dir / event.trial_name
    agent = trial / "agent"
    agent.mkdir(parents=True, exist_ok=True)
    write_json(agent / "completeness.json", {
        "schema_version": 1, "complete": False, "issues": ["Trial has not finished."]})
    task = agent / "task"
    task_id = event.result.task_id
    if event.lock.task.type == "package":
        # The result retains the requested ref; the lock records the downloaded version.
        digest = event.lock.task.digest
        source = task_id.model_copy(update={"ref": digest}).get_local_path()
        if event.config.task.download_dir is not None:
            source = (event.config.task.download_dir / task_id.org / task_id.name
                      / digest.removeprefix("sha256:"))
    else:
        source = task_id.get_local_path()
    shutil.copytree(source, task, symlinks=True)
    if dirhash(task, "sha256") != event.result.task_checksum:
        raise ValueError("Task changed after Harbor planned the trial.")
    git = ["git", "--no-optional-locks", "-C", str(repository)]
    commit = command([*git, "rev-parse", "HEAD"]).decode().strip()
    (agent / "source.patch").write_bytes(command([*git, "diff", "--binary", "HEAD"]))
    untracked = command([*git, "ls-files", "--others", "--exclude-standard", "-z"])
    (agent / "source-untracked").mkdir()
    for raw in untracked.split(b"\0"):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        target = agent / "source-untracked" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repository / relative, target, follow_symlinks=False)
    shutil.copy2(repository / "Package.resolved", agent / "Package.resolved")
    binary = Path(event.config.agent.kwargs["binary"]).expanduser().resolve(strict=True)
    write_json(agent / "reproduction.json", {
        "schema_version": 1, "trial_id": str(event.trial_id),
        "task_checksum": event.result.task_checksum,
        "task_files": inventory(task), "harbor_version": version("harbor"),
        "binary": {"path": str(binary), **file_record(binary)},
        "source_at_run": {"commit": commit, "patch": "agent/source.patch",
                          "untracked": "agent/source-untracked"},
        "swift_version": command(["xcrun", "swift", "--version"]).decode().strip(),
        "host": {"os": platform.platform(), "architecture": platform.machine()},
        "generation_activity": os.environ.get("SUMIKA_GENERATION_ACTIVITY", "default"),
        "runtime_metadata": "agent/runtime.json",
    })


async def capture_environment(environment, logs_dir):
    # This Compose lookup is tied to the adapter's exact Harbor version pin.
    images = await environment._run_docker_compose_command(
        ["images", "-q"], timeout_sec=30)
    identifiers = sorted(set(images.stdout.split()))
    if not identifiers:
        raise ValueError("Cannot identify the running task image.")
    runtime = environment.runtime()
    data = json.loads(await asyncio.to_thread(
        command, runtime.engine_cmd("image", "inspect", *identifiers)))
    fields = ("Id", "RepoDigests", "Architecture", "Os")
    config = environment.task_env_config
    write_json(logs_dir / "environment.json", {
        "schema_version": 1,
        "engine": list(runtime.engine),
        "images": [{key: image.get(key) for key in fields} for image in data],
        "workdir": config.workdir, "cpus": config.cpus, "memory_mb": config.memory_mb,
        "storage_mb": config.storage_mb, "network_mode": config.network_mode,
    })


def assess_trial(trial):
    issues = []

    def read(name):
        path = trial / name
        try:
            if path.is_symlink() or not path.is_file():
                raise ValueError("Missing regular file")
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            issues.append(f"{name}: {error}")
            return {}

    harbor = read("result.json")
    config = read("config.json")
    lock = read("lock.json")
    reproduction = read("agent/reproduction.json")
    runtime = read("agent/runtime.json")
    environment = read("agent/environment.json")
    native = read("agent/result.json")
    session = read("agent/session.json")
    manifest = read("artifacts/manifest.json")
    if not harbor.get("finished_at"):
        issues.append("Harbor trial has not finished.")
    if reproduction.get("trial_id") != harbor.get("id"):
        issues.append("Reproduction metadata belongs to another trial.")
    model_id = config.get("agent", {}).get("model_name")
    if not model_id or any(value.get("modelID") != model_id for value in (runtime, native)):
        issues.append("Model identity is missing or inconsistent.")
    if session.get("selectedModelID") != model_id or not runtime.get("modelFiles"):
        issues.append("Session model or model file fingerprints are missing.")
    if runtime.get("schemaVersion") != 1 or not runtime.get("settings") or not runtime.get("buildConfiguration"):
        issues.append("Runtime settings or build configuration are missing.")
    if not reproduction.get("binary", {}).get("sha256") or not reproduction.get("source_at_run", {}).get("commit"):
        issues.append("Binary fingerprint or source commit is missing.")
    if not environment.get("images") or any(not image.get("Id") for image in environment["images"]):
        issues.append("Resolved task images are missing.")
    turn_id = native.get("turnID")
    if not turn_id or not any(turn.get("id") == turn_id for turn in session.get("turns", [])):
        issues.append("The native result's turn is missing from the session.")
    if reproduction.get("task_checksum") != harbor.get("task_checksum") or not lock.get("task"):
        issues.append("Task identity is missing or inconsistent.")
    task = trial / "agent/task"
    if not task.is_dir() or task.is_symlink() or inventory(task) != reproduction.get("task_files"):
        issues.append("Retained task files are missing or changed.")
    required_captures = {"/app": ()}
    if harbor.get("task_name") == "openthoughts/python-api-rate-limit":
        required_captures["/output"] = ("report.json", "a.json", "b.json")
    captures = {}
    for entry in manifest if isinstance(manifest, list) else []:
        if entry.get("status") in ("failed", "skipped"):
            issues.append(f"Artifact collection {entry.get('status')}: {entry.get('source')}")
        source = entry.get("source")
        if source in required_captures and entry.get("service") in (None, "main"):
            destination = Path(entry.get("destination", ""))
            if destination.is_absolute() or ".." in destination.parts or destination.parts[:1] != ("artifacts",):
                issues.append(f"Invalid artifact destination for {source}.")
                continue
            capture = trial / destination
            if any(parent.is_symlink() for parent in [capture, *capture.parents] if parent != trial and trial in parent.parents):
                issues.append(f"Artifact capture has a symlink ancestor: {source}.")
                continue
            if entry.get("status") not in ("ok", "empty") or entry.get("exclude"):
                issues.append(f"Artifact capture failed or excluded files: {source}.")
            captures[source] = capture
    for source, names in required_captures.items():
        capture = captures.get(source)
        if capture is None or capture.is_symlink() or not capture.is_dir():
            issues.append(f"The final {source} directory was not captured.")
            continue
        for name in names:
            path = capture / name
            if path.is_symlink() or not path.is_file():
                issues.append(f"Missing regular output file: {source}/{name}")
    for name in ("agent/instruction.md", "agent/runner.log", "agent/source.patch", "agent/Package.resolved"):
        if not (trial / name).is_file() or (trial / name).is_symlink():
            issues.append(f"Missing regular file: {name}")
    if harbor.get("verifier_result") is not None:
        if not any((trial / "verifier" / name).is_file() and not (trial / "verifier" / name).is_symlink()
                   for name in ("reward.txt", "reward.json")):
            issues.append("Verifier reward artifact is missing.")
        if not (trial / "verifier/test-stdout.txt").is_file() or (trial / "verifier/test-stdout.txt").is_symlink():
            issues.append("Verifier stdout is missing.")
    elif harbor.get("exception_info") is None:
        issues.append("Trial has neither verifier result nor exception evidence.")
    requests, responses, starts, ends = set(), set(), set(), set()
    clipped = 0
    try:
        path = trial / "agent/mlx-trace.jsonl"
        if path.is_symlink():
            raise ValueError("Trace is a symlink")
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                row = json.loads(line)
                kind = row.get("kind")
                if kind in ("mlx_request", "mlx_response"):
                    identifiers = requests if kind == "mlx_request" else responses
                    identifier = row.get("id")
                    if not identifier or identifier in identifiers:
                        issues.append("Missing or duplicate model trace ID.")
                    identifiers.add(identifier)
                if row.get("phase") in ("runtime_stream_start", "runtime_stream_end"):
                    identifiers = starts if row["phase"] == "runtime_stream_start" else ends
                    identifier = row.get("generationID")
                    if not identifier or identifier in identifiers or row.get("turnID") != turn_id:
                        issues.append("Missing, duplicate, or foreign model stream boundary.")
                    identifiers.add(identifier)
                clipped += bool(row.get("promptTruncated") or row.get("outputTruncated")
                                or any(message.get("truncated") for message in row.get("history", [])))
        if not requests or requests != responses or requests != starts or requests != ends:
            issues.append("Model requests, responses, and stream boundaries are incomplete.")
        if clipped:
            issues.append(f"Trace contains {clipped} rows with clipped model content.")
    except (OSError, ValueError, TypeError, AttributeError) as error:
        issues.append(f"agent/mlx-trace.jsonl: {error}")
    files = inventory(trial)
    files.pop("agent/completeness.json", None)
    return {"schema_version": 1, "complete": not issues, "issues": issues,
            "trace_requests": len(requests), "trace_clipped_rows": clipped, "files": files}


def save_assessment(trial):
    try:
        report = assess_trial(trial)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        report = {"schema_version": 1, "complete": False, "issues": [str(error)], "files": {}}
    write_json(trial / "agent/completeness.json", report)
    return report


class EvidencePlugin:
    async def on_job_start(self, job):
        if version("harbor") != "0.24.0":
            raise ValueError("Evidence collection requires harbor==0.24.0.")
        if "/app" not in job.config.artifacts:
            raise ValueError("Pass --artifact /app to retain the final workspace.")
        self.job_dir = job.job_dir
        job.on_trial_started(self.started)
        job.on_trial_ended(self.ended)

    async def started(self, event):
        await asyncio.to_thread(prepare_trial, event, Path(__file__).resolve().parents[2])

    async def ended(self, event):
        await asyncio.to_thread(save_assessment, event.config.trials_dir / event.trial_name)

    async def on_job_end(self, _result):
        # Final logs and Harbor secret scrubbing finish after the trial END hook.
        for trial in sorted(self.job_dir.glob("*/agent")):
            report = await asyncio.to_thread(save_assessment, trial.parent)
            if not report["complete"]:
                print(f"Incomplete evidence: {trial.parent}; {report['issues']}", file=sys.stderr)


def check_evidence(path):
    is_trial = (path / "agent").is_dir()
    trials = [path] if is_trial else sorted(p.parent for p in path.glob("*/agent"))
    if not trials:
        raise ValueError(f"No trial evidence in {path}")
    if not is_trial:
        job = json.loads((path / "result.json").read_text(encoding="utf-8"))
        stats = job.get("stats", {})
        if not job.get("finished_at") or stats.get("n_running_trials", 0) or stats.get("n_pending_trials", 0):
            raise ValueError(f"Harbor job has not finished: {path}")
        if len(trials) != job.get("n_total_trials"):
            raise ValueError(f"Trial directories do not match Harbor's planned count in {path}")
    for trial in trials:
        report = json.loads((trial / "agent/completeness.json").read_text(encoding="utf-8"))
        current = assess_trial(trial)
        if not report.get("complete") or not current["complete"] or report.get("files") != current["files"]:
            raise ValueError(f"Incomplete or changed evidence in {trial}: "
                             f"{report.get('issues', []) + current['issues']}")
        print(f"Complete evidence: {trial}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: python3 script/harbor/evidence.py TRIAL_OR_JOB_DIRECTORY")
        check_evidence(Path(sys.argv[1]))
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
