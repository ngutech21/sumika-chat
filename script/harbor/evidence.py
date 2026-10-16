"""Per-trial reproduction evidence and a read-only integrity check for Harbor 0.24.0."""

import asyncio
import hashlib
import json
import os
import platform
import posixpath
import shutil
import stat
import subprocess
import sys
from importlib.metadata import distributions, version
from pathlib import Path

from harbor.models.task.artifacts import effective_artifact_service, normalize_artifact_entries
from harbor.models.task.config import ArtifactConfig, TaskConfig
from harbor.models.trial.artifact_manifest import ArtifactManifest
from harbor.trial.artifact_handler import artifact_host_path
from pydantic import TypeAdapter
from script.harbor.models import CompletenessReport


def validate_workspace_root(path):
    if (
        not isinstance(path, str)
        or not path.startswith("/")
        or path.startswith("//")
        or any(character in path for character in "\0\r\n")
        or posixpath.normpath(path) != path
    ):
        raise ValueError("Expected a normalized absolute container workspace path.")
    return path


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
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
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
    return subprocess.run(arguments, cwd=cwd, check=True, capture_output=True, timeout=30).stdout


def prepare_trial(event, repository):
    from dirhash import dirhash

    trial = event.config.trials_dir / event.trial_name
    agent = trial / "agent"
    agent.mkdir(parents=True, exist_ok=True)
    write_json(
        agent / "completeness.json", {"schema_version": 1, "complete": False, "issues": ["Trial has not finished."]}
    )
    provenance = trial / "provenance"
    provenance.mkdir()
    task = provenance / "task"
    task_id = event.result.task_id
    if event.lock.task.type == "package":
        # The result retains the requested ref; the lock records the downloaded version.
        digest = event.lock.task.digest
        source = task_id.model_copy(update={"ref": digest}).get_local_path()
        if event.config.task.download_dir is not None:
            source = event.config.task.download_dir / task_id.org / task_id.name / digest.removeprefix("sha256:")
    else:
        source = task_id.get_local_path()
    shutil.copytree(source, task, symlinks=True)
    if dirhash(task, "sha256") != event.result.task_checksum:
        raise ValueError("Task changed after Harbor planned the trial.")
    steps = TaskConfig.model_validate_toml((task / "task.toml").read_text(encoding="utf-8")).steps or []
    retained_agent = Path("steps") / steps[0].name / "agent" if steps else Path("agent")
    git = ["git", "--no-optional-locks", "-C", str(repository)]
    commit = command([*git, "rev-parse", "HEAD"]).decode().strip()
    (provenance / "source.patch").write_bytes(command([*git, "diff", "--binary", "HEAD"]))
    untracked = command([*git, "ls-files", "--others", "--exclude-standard", "-z"])
    (provenance / "source-untracked").mkdir()
    for raw in untracked.split(b"\0"):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        target = provenance / "source-untracked" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repository / relative, target, follow_symlinks=False)
    shutil.copy2(repository / "Package.resolved", provenance / "Package.resolved")
    binary = Path(event.config.agent.kwargs["binary"]).expanduser().resolve(strict=True)
    write_json(
        provenance / "reproduction.json",
        {
            "schema_version": 1,
            "trial_id": str(event.trial_id),
            "task_checksum": event.result.task_checksum,
            "task_files": inventory(task),
            "harbor_version": version("harbor"),
            "binary": {"path": str(binary), **file_record(binary)},
            "source_at_run": {
                "commit": commit,
                "patch": "provenance/source.patch",
                "untracked": "provenance/source-untracked",
            },
            "swift_version": command(["xcrun", "swift", "--version"]).decode().strip(),
            "python": {
                "version": sys.version,
                "executable": sys.executable,
                "packages": {package.metadata["Name"]: package.version for package in distributions()},
                "uv_lock": file_record(repository / "script/harbor/uv.lock"),
            },
            "host": {"os": platform.platform(), "architecture": platform.machine()},
            "generation_activity": os.environ.get("SUMIKA_GENERATION_ACTIVITY", "default"),
            "runtime_metadata": (retained_agent / "runtime.json").as_posix(),
        },
    )


async def capture_environment(environment, logs_dir):
    # This Compose lookup is tied to the adapter's exact Harbor version pin.
    images = await environment._run_docker_compose_command(["images", "-q"], timeout_sec=30)
    identifiers = sorted(set(images.stdout.split()))
    if not identifiers:
        raise ValueError("Cannot identify the running task image.")
    runtime = environment.runtime()
    data = json.loads(await asyncio.to_thread(command, runtime.engine_cmd("image", "inspect", *identifiers)))
    fields = ("Id", "RepoDigests", "Architecture", "Os")
    config = environment.task_env_config
    write_json(
        logs_dir / "environment.json",
        {
            "schema_version": 1,
            "engine": list(runtime.engine),
            "images": [{key: image.get(key) for key in fields} for image in data],
            "workdir": config.workdir,
            "cpus": config.cpus,
            "memory_mb": config.memory_mb,
            "storage_mb": config.storage_mb,
            "network_mode": config.network_mode,
        },
    )


async def capture_legacy_artifacts(environment, logs_dir, logger, workspace_root, *, task_config=None, step_name=None):
    from harbor.models.trial.paths import EnvironmentPaths
    from harbor.trial.artifact_handler import ArtifactHandler

    try:
        task = task_config or TaskConfig.model_validate_toml(
            (logs_dir.parent / "provenance/task/task.toml").read_text(encoding="utf-8")
        )
        step = next((step for step in task.steps or [] if step.name == step_name), None)
        if step_name is not None and step is None:
            raise ValueError(f"Unknown checkpoint: {step_name}")
        if task.artifacts or (step is not None and step.artifacts):
            return
        workspace_root = validate_workspace_root(workspace_root)
        if workspace_root == "/":
            raise ValueError("Tasks working in / must declare artifacts; capturing the container root is unsupported.")
        # shortcut: legacy capture covers the workspace and /output; declare other paths in the task.
        artifacts = [workspace_root]
        output = await environment.exec(
            "if [ -L /output ]; then exit 4; elif [ -e /output ]; then exit 0; else exit 3; fi",
            timeout_sec=10,
            user="root",
        )
        if output.return_code == 0:
            if workspace_root != "/output":
                artifacts.append("/output")
        elif output.return_code != 3:
            raise RuntimeError(f"Cannot inspect legacy /output path (exit {output.return_code}).")
        collector = ArtifactHandler(artifacts=artifacts, logger=logger)
        await collector.download_artifacts(
            environment, logs_dir.parent / "artifacts", source_artifacts_dir=EnvironmentPaths.artifacts_dir
        )
    except Exception as error:
        logger.exception("Could not collect legacy artifacts")
        write_json(logs_dir / "artifact-error.json", {"error": str(error)})


def _read_json(root, name, issues):
    path = root / name
    try:
        if not _regular_file(path, root):
            raise ValueError("Missing regular file or symlink ancestor")
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        issues.append(f"{name}: {error}")
        return {}


def _regular_file(path, root):
    return path.is_file() and not any(
        parent.is_symlink() for parent in [path, *path.parents] if parent == root or root in parent.parents
    )


def _step_stop_reason(step, result, config):
    if result.get("exception_info") is not None and result.get("verifier_result") is None:
        return "Checkpoint exception"
    threshold = step.min_reward
    if threshold is None or config.get("verifier", {}).get("disable", False):
        return None
    thresholds = {"reward": threshold} if isinstance(threshold, (int, float)) else threshold
    rewards = (result.get("verifier_result") or {}).get("rewards") or {}
    if any(rewards.get(key, float("-inf")) < value for key, value in thresholds.items()):
        return "Checkpoint reward below min_reward"
    return None


def _assess_resumed_session(run, previous, issues):
    session = _read_json(run, "agent/session.json", issues)
    native = _read_json(run, "agent/result.json", issues)
    runtime = _read_json(run, "agent/runtime.json", issues)
    turns = session.get("turns", [])
    turn_ids = [turn.get("id") for turn in turns]
    if (
        not isinstance(session.get("id"), str)
        or not session["id"]
        or not turn_ids
        or any(not isinstance(identifier, str) or not identifier for identifier in turn_ids)
        or len(set(turn_ids)) != len(turn_ids)
        or turn_ids[-1] != native.get("turnID")
    ):
        issues.append("Resumed session identity or current turn ordering is invalid.")
    if previous is None:
        if len(turns) != 1:
            issues.append("The first resumed checkpoint must start with one user turn.")
    else:
        prior_session, prior_runtime = previous
        if session.get("id") != prior_session.get("id") or turns[:-1] != prior_session.get("turns"):
            issues.append("Resumed checkpoints must retain the same session and unchanged prior turns.")
        if any(runtime.get(key) != prior_runtime.get(key) for key in ("settings", "modelFiles")):
            issues.append("Resumed checkpoint model fingerprints or settings changed.")
    return session, runtime


def assess_trial(trial):
    issues = []
    harbor = _read_json(trial, "result.json", issues)
    config = _read_json(trial, "config.json", issues)
    lock = _read_json(trial, "lock.json", issues)
    if not harbor.get("finished_at"):
        issues.append("Harbor trial has not finished.")
    steps_dir = trial / "steps"
    if trial.is_symlink() or steps_dir.is_symlink():
        raise ValueError("Cannot assess a symlinked evidence directory")
    archives = sorted(steps_dir.iterdir()) if steps_dir.is_dir() else []
    # Read-only compatibility for existing .harbor runs captured in agent logs.
    locations = [trial / "provenance", trial / "agent", *(step / "agent" for step in archives)]
    candidates = [
        path for path in locations if (path / "reproduction.json").exists() or (path / "reproduction.json").is_symlink()
    ]
    if len(candidates) != 1:
        issues.append("Expected one canonical reproduction snapshot.")
    provenance = candidates[0] if candidates else trial / "provenance"
    if provenance == trial / "provenance":
        for logs in locations[1:]:
            if any(
                (logs / name).exists() or (logs / name).is_symlink()
                for name in ("task", "source.patch", "source-untracked", "Package.resolved", "reproduction.json")
            ):
                issues.append(f"Provenance snapshot is exposed in agent logs: {logs.relative_to(trial)}.")
    reproduction = _read_json(trial, str((provenance / "reproduction.json").relative_to(trial)), issues)
    if reproduction.get("trial_id") != harbor.get("id"):
        issues.append("Reproduction metadata belongs to another trial.")
    if not reproduction.get("binary", {}).get("sha256") or not reproduction.get("source_at_run", {}).get("commit"):
        issues.append("Binary fingerprint or source commit is missing.")
    if reproduction.get("task_checksum") != harbor.get("task_checksum") or not lock.get("task"):
        issues.append("Task identity is missing or inconsistent.")
    task = provenance / "task"
    files = inventory(trial)
    task_prefix = task.relative_to(trial).as_posix() + "/"
    task_files = {
        name.removeprefix(task_prefix): record for name, record in files.items() if name.startswith(task_prefix)
    }
    if (
        task.is_symlink()
        or not task.is_dir()
        or not _regular_file(task / "task.toml", trial)
        or task_files != reproduction.get("task_files")
    ):
        issues.append("Retained task files are missing or changed.")
    try:
        definition = task / "task.toml"
        if not _regular_file(definition, trial):
            raise ValueError("Missing regular task.toml")
        task_config = TaskConfig.model_validate_toml(definition.read_text(encoding="utf-8"))
        declared = task_config.artifacts
        steps = task_config.steps or []
        names = [step.name for step in steps]
    except (OSError, ValueError, TypeError, KeyError) as error:
        issues.append(f"{definition.relative_to(trial)}: {error}")
        declared, steps, names = [], [], []
    runtime_agent = trial / "steps" / names[0] / "agent" if steps else trial / "agent"
    pointers = (
        (reproduction.get("source_at_run", {}).get("patch"), provenance / "source.patch"),
        (reproduction.get("source_at_run", {}).get("untracked"), provenance / "source-untracked"),
        (reproduction.get("runtime_metadata"), runtime_agent / "runtime.json"),
    )
    for pointer, target in pointers:
        retained = (
            target.is_dir() and not target.is_symlink()
            if target.name == "source-untracked"
            else _regular_file(target, trial)
        )
        if pointer != target.relative_to(trial).as_posix() or not retained:
            issues.append(f"Reproduction pointer is missing, invalid, or dangling: {target.name}.")
    for name in ("source.patch", "Package.resolved"):
        if not _regular_file(provenance / name, trial):
            issues.append(f"Missing regular file: {(provenance / name).relative_to(trial)}")
    reports = []
    if steps:
        if provenance not in (trial / "provenance", trial / "steps" / names[0] / "agent"):
            issues.append("Legacy checkpoint provenance is not in the first checkpoint archive.")
        results = harbor.get("step_results") or []
        if not isinstance(results, list):
            raise ValueError("Harbor checkpoint results must be a list")
        attempted = [result.get("step_name") for result in results]
        if not results or attempted != names[: len(results)]:
            issues.append("Harbor checkpoint results are missing, duplicated, or out of task order.")
        if any(archive.name not in attempted for archive in archives):
            issues.append("Checkpoint archive has no corresponding Harbor result.")
        stop = None
        previous_session = None
        resume = config.get("agent", {}).get("resume_trajectory", False)
        for index, (step, result) in enumerate(zip(steps, results)):
            name = names[index]
            if result.get("step_name") != name:
                continue
            run = trial / "steps" / name
            try:
                report = _assess_run(run, result, config, [*declared, *step.artifacts], checkpoint=True)
                if resume:
                    previous_session = _assess_resumed_session(run, previous_session, report["issues"])
                    report["complete"] = not report["issues"]
            except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
                report = {"complete": False, "issues": [str(error)], "trace_requests": 0, "trace_clipped_rows": 0}
            issues.extend(f"steps/{name}: {issue}" for issue in report["issues"])
            reports.append({"name": name, "attempted": True, **report})
            stop = _step_stop_reason(step, result, config)
            if stop and index + 1 < len(results):
                issues.append(f"Checkpoint results continue after a stop condition: {name}.")
        if len(results) < len(steps):
            if not stop:
                issues.append("Unattempted checkpoints have no preceding stop condition.")
            reports.extend(
                {"name": name, "attempted": False, "reason": stop or "Missing checkpoint result"}
                for name in names[len(results) :]
            )
    else:
        if harbor.get("step_results") is not None or archives:
            issues.append("Checkpoint outputs exist without task checkpoint declarations.")
        report = _assess_run(trial, harbor, config, declared)
        issues.extend(report["issues"])
        reports.append(report)
    files.pop("agent/completeness.json", None)
    report = {
        "schema_version": 1,
        "complete": not issues,
        "issues": issues,
        "trace_requests": sum(report["trace_requests"] for report in reports if report.get("attempted", True)),
        "trace_clipped_rows": sum(report["trace_clipped_rows"] for report in reports if report.get("attempted", True)),
        "files": files,
    }
    if steps:
        report["steps"] = reports
    return report


def _assess_run(trial, harbor, config, declared, checkpoint=False):
    issues = []
    if trial.is_symlink() or any((trial / name).is_symlink() for name in ("agent", "verifier", "artifacts")):
        return {
            "complete": False,
            "issues": ["Output directory is a symlink."],
            "trace_requests": 0,
            "trace_clipped_rows": 0,
        }

    def read(name):
        return _read_json(trial, name, issues)

    runtime = read("agent/runtime.json")
    environment = read("agent/environment.json")
    native = read("agent/result.json")
    session = read("agent/session.json")
    manifest = read("artifacts/manifest.json")
    model_id = config.get("agent", {}).get("model_name")
    if not model_id or any(value.get("modelID") != model_id for value in (runtime, native)):
        issues.append("Model identity is missing or inconsistent.")
    if session.get("selectedModelID") != model_id or not runtime.get("modelFiles"):
        issues.append("Session model or model file fingerprints are missing.")
    if runtime.get("schemaVersion") != 1 or not runtime.get("settings") or not runtime.get("buildConfiguration"):
        issues.append("Runtime settings or build configuration are missing.")
    if not environment.get("images") or any(not image.get("Id") for image in environment["images"]):
        issues.append("Resolved task images are missing.")
    if checkpoint and ((harbor.get("agent_result") or {}).get("metadata") or {}).get("sumika") != native:
        issues.append("Native result does not match Harbor checkpoint metadata.")
    turn_id = native.get("turnID")
    if not turn_id or not any(turn.get("id") == turn_id for turn in session.get("turns", [])):
        issues.append("The native result's turn is missing from the session.")
    try:
        run_artifacts = TypeAdapter(list[str | ArtifactConfig]).validate_python(config.get("artifacts", []))
        requirements = normalize_artifact_entries([*declared, *run_artifacts])
    except ValueError as error:
        issues.append(f"Artifact declarations: {error}")
        requirements = []
    legacy_files = {}
    if not declared:
        try:
            workspace_root = validate_workspace_root(runtime.get("workspaceRoot"))
            if workspace_root == "/":
                raise ValueError("Tasks working in / must declare artifacts.")
            legacy_files[workspace_root] = ()
        except ValueError as error:
            issues.append(f"agent/runtime.json workspaceRoot: {error}")
        # Legacy rate-limit tasks omit declarations; retain this until they declare their outputs.
        if harbor.get("task_name") == "openthoughts/python-api-rate-limit":
            legacy_files["/output"] = ("report.json", "a.json", "b.json")
        for source in legacy_files:
            if not any(
                entry.source == source and effective_artifact_service(entry) == "main" for entry in requirements
            ):
                requirements.append(ArtifactConfig(source=source))
    for name, label in (("artifact-error.json", "Artifact collection"), ("trajectory-error.json", "Trajectory export")):
        error_path = trial / "agent" / name
        if error_path.exists() or error_path.is_symlink():
            error = read(f"agent/{name}")
            issues.append(f"{label} error: {error.get('error', 'Unknown failure')}")
    captures = {}
    try:
        entries = ArtifactManifest(entries=manifest).entries
    except ValueError as error:
        issues.append(f"artifacts/manifest.json: {error}")
        entries = []
    for entry in entries:
        if entry.status not in ("ok", "empty"):
            issues.append(f"Artifact collection {entry.status}: {entry.source}")
        source = entry.source
        destination = Path(entry.destination)
        if destination.is_absolute() or ".." in destination.parts or destination.parts[:1] != ("artifacts",):
            issues.append(f"Invalid artifact destination for {source}.")
            continue
        capture = trial / destination
        if any(
            parent.is_symlink() for parent in [capture, *capture.parents] if parent != trial and trial in parent.parents
        ):
            issues.append(f"Artifact capture has a symlink ancestor: {source}.")
            continue
        kind = entry.type
        # Harbor preserves the live publish mount and moves only its contents into checkpoint archives.
        empty_publish_mount = (
            checkpoint
            and source == "/logs/artifacts"
            and kind == "directory"
            and entry.status == "empty"
            and entry.service in (None, "main")
            and entry.destination == "artifacts/logs/artifacts"
            and (entry.exclude == [] or "exclude" not in entry.model_fields_set)
            and not capture.exists()
            and (not capture.parent.exists() or capture.parent.is_dir())
        )
        if not (
            empty_publish_mount or (kind == "directory" and capture.is_dir()) or (kind == "file" and capture.is_file())
        ):
            issues.append(f"Missing or invalid artifact capture: {source}.")
            continue
        captures.setdefault((source, entry.service or "main"), []).append((entry, capture))
    for requirement in requirements:
        source = requirement.source
        service = effective_artifact_service(requirement)
        names = legacy_files.get(source) if service == "main" else None
        destination = (
            artifact_host_path(trial / "artifacts", requirement)
            if requirement.destination is not None or names is None
            else None
        )
        candidates = [
            (entry, path)
            for entry, path in captures.get((source, service), [])
            if destination is None or path == destination
        ]
        if not candidates:
            issues.append(f"Missing artifact capture: {source} ({service}).")
            continue
        entry, capture = candidates[0]
        exclusions = requirement.exclude if entry.type == "directory" else []
        if names is not None:
            exclusions = []
            if not capture.is_dir():
                issues.append(f"The final {source} directory was not captured.")
                continue
        if (entry.exclude or []) != exclusions:
            issues.append(f"Artifact exclusions differ from the declaration: {source}.")
        for name in names or ():
            path = capture / name
            if path.is_symlink() or not path.is_file():
                issues.append(f"Missing regular output file: {source}/{name}")
    for name in ("agent/instruction.md", "agent/runner.log"):
        if not (trial / name).is_file() or (trial / name).is_symlink():
            issues.append(f"Missing regular file: {name}")
    if harbor.get("verifier_result") is not None:
        if not any(
            (trial / "verifier" / name).is_file() and not (trial / "verifier" / name).is_symlink()
            for name in ("reward.txt", "reward.json")
        ):
            issues.append("Verifier reward artifact is missing.")
        if not (trial / "verifier/test-stdout.txt").is_file() or (trial / "verifier/test-stdout.txt").is_symlink():
            issues.append("Verifier stdout is missing.")
    elif harbor.get("exception_info") is None:
        issues.append("Trial has neither verifier result nor exception evidence.")
    requests, responses, starts, ends = set(), set(), set(), set()
    generation_ids, prefills = set(), set()
    clipped = 0
    try:
        path = trial / "agent/mlx-trace.jsonl"
        if path.is_symlink():
            raise ValueError("Trace is a symlink")
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                row = json.loads(line)
                kind = row.get("kind")
                if row.get("turnID") not in (None, turn_id):
                    issues.append("Trace contains a foreign turn.")
                if kind == "turn_trace" and row.get("generationID"):
                    generation_ids.add(row["generationID"])
                if row.get("phase") == "runtime_prefill":
                    identifier = row.get("generationID")
                    if not identifier or identifier in prefills:
                        issues.append("Missing or duplicate model prefill trace ID.")
                    prefills.add(identifier)
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
                clipped += bool(
                    row.get("promptTruncated")
                    or row.get("outputTruncated")
                    or any(message.get("truncated") for message in row.get("history", []))
                )
        if not generation_ids.issubset(requests):
            issues.append("Trace contains an unmatched model generation.")
        if not requests or requests != responses or requests != starts or requests != ends:
            issues.append("Model requests, responses, and stream boundaries are incomplete.")
        if clipped:
            issues.append(f"Trace contains {clipped} rows with clipped model content.")
    except (OSError, ValueError, TypeError, AttributeError) as error:
        issues.append(f"agent/mlx-trace.jsonl: {error}")
    return {"complete": not issues, "issues": issues, "trace_requests": len(requests), "trace_clipped_rows": clipped}


def save_assessment(trial):
    if trial.is_symlink() or (trial / "agent").is_symlink():
        raise ValueError("Cannot save a report in a symlinked evidence directory")
    (trial / "agent").mkdir(parents=True, exist_ok=True)
    try:
        report = assess_trial(trial)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        report = {"schema_version": 1, "complete": False, "issues": [str(error)], "files": {}}
    write_json(trial / "agent/completeness.json", report)
    return report


class EvidencePlugin:
    async def on_job_start(self, job):
        if version("harbor") != "0.24.0":
            raise ValueError("Evidence collection requires harbor==0.24.0.")
        self.job_dir = job.job_dir
        job.on_trial_started(self.started)
        job.on_trial_ended(self.ended)

    async def started(self, event):
        await asyncio.to_thread(prepare_trial, event, Path(__file__).resolve().parents[2])

    async def _finish_trial(self, trial):
        from script.harbor.agent import SumikaAgent

        await SumikaAgent.close_trial_worker(trial)
        return await asyncio.to_thread(save_assessment, trial)

    async def ended(self, event):
        from script.harbor.agent import SumikaAgent

        await SumikaAgent.close_trial_worker(event.config.trials_dir / event.trial_name)

    async def on_job_end(self, _result):
        # Final logs and Harbor secret scrubbing finish after the trial END hook.
        trials = {
            path.parent
            for name in ("agent", "steps", "config.json", "result.json")
            for path in self.job_dir.glob(f"*/{name}")
        }
        for trial in sorted(trials):
            report = await self._finish_trial(trial)
            if not report["complete"]:
                print(f"Incomplete evidence: {trial}; {report['issues']}", file=sys.stderr)


def check_evidence(path):
    path = path.absolute()
    try:
        config = json.loads((path / "config.json").read_text(encoding="utf-8"))
    except OSError, ValueError:
        config = {}
    # Jobs also have lock.json; a trial config has one agent, not an agents list.
    is_trial = (
        (path / "agent").exists() or (path / "steps").exists() or (isinstance(config, dict) and "agent" in config)
    )
    trials = (
        [path]
        if is_trial
        else sorted(
            {p.parent for name in ("agent", "steps", "result.json", "config.json") for p in path.glob(f"*/{name}")}
        )
    )
    if not trials:
        raise ValueError(f"No trial evidence in {path}")
    failures = []
    if not is_trial:
        try:
            job = json.loads((path / "result.json").read_text(encoding="utf-8"))
            stats = job.get("stats", {})
            if not job.get("finished_at") or stats.get("n_running_trials", 0) or stats.get("n_pending_trials", 0):
                failures.append(f"Harbor job has not finished: {path}")
            if len(trials) != job.get("n_total_trials"):
                failures.append(f"Trial directories do not match Harbor's planned count in {path}")
        except (OSError, ValueError, TypeError, AttributeError) as error:
            failures.append(f"Cannot read Harbor job result in {path}: {error}")
    complete = 0
    for trial in trials:
        issues = []
        report = None
        try:
            report_path = trial / "agent/completeness.json"
            if trial.is_symlink() or (trial / "agent").is_symlink() or report_path.is_symlink():
                raise ValueError("Evidence directory or completeness report is a symlink")
            report = CompletenessReport.model_validate_json(report_path.read_text(encoding="utf-8")).model_dump(
                exclude_unset=True
            )
            issues.extend(report["issues"])
            if not report["complete"] and not issues:
                issues.append("Saved assessment is incomplete.")
        except (OSError, ValueError, TypeError, AttributeError) as error:
            issues.append(f"agent/completeness.json: {error}")
        try:
            if trial.is_symlink() or (trial / "agent").is_symlink():
                raise ValueError("Cannot assess a symlinked evidence directory")
            current = assess_trial(trial)
            issues.extend(current["issues"])
            if report is not None and report["files"] != current["files"]:
                changed = sorted(
                    name
                    for name in report["files"].keys() | current["files"].keys()
                    if report["files"].get(name) != current["files"].get(name)
                )
                issues.append("Evidence files changed since saved assessment: " + ", ".join(changed))
        except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
            issues.append(f"Cannot assess retained evidence: {error}")
        if issues:
            failures.append(f"Incomplete or changed evidence in {trial}:\n  " + "\n  ".join(dict.fromkeys(issues)))
        else:
            complete += 1
            print(f"Complete evidence: {trial}")
    print(f"Evidence: {len(trials)} trials checked, {complete} complete, {len(trials) - complete} incomplete")
    if failures:
        raise ValueError("\n".join(failures))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: python -m script.harbor.evidence TRIAL_OR_JOB_DIRECTORY")
        check_evidence(Path(sys.argv[1]))
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
