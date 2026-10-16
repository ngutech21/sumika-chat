# Sumika Harbor proof

This adapter runs the real Sumika Work loop and MLX model on the Mac. Its file
operations and commands execute inside a fresh Harbor Docker task. Task files are
never copied to the Mac for execution. Run one local trial at a time, using the
included Python repair fixture, the pinned development suite, or checkpoint tasks.
Checkpoint tasks can optionally retain the native conversation and loaded model.

## Requirements

- Apple Silicon Mac, Docker running, and an already-installed Sumika model.
- [uv](https://docs.astral.sh/uv/getting-started/installation/). The local uv
  project pins Harbor **0.24.0**, the version checked by the adapter, and locks
  its transitive dependencies in `uv.lock`. `.python-version` selects Python
  **3.14.8**. From the repository root, install and check the environment:

  ```sh
  uv sync --project script/harbor --locked
  uv run --project script/harbor --locked harbor --version
  ```

  uv creates the ignored `script/harbor/.venv/` and downloads Python if the
  selected version is unavailable. Initial setup may require network access.
  All Harbor recipes use this environment without shell activation or a global
  Harbor installation. `--locked` fails if project metadata and `uv.lock` disagree.

- Build the native runner in Release from the repository root:

  ```sh
  just build-harbor
  ```

The fixture image is `python:3.13.7-slim-bookworm`, with an unprivileged task user.
Image pulls and builds may require network access. The fixture disables network
access while running; no model download is performed by the runner.

The container worker is dependency-free and supports Python 3.7 or newer,
independently of the host's Python 3.14 environment. Adapter setup probes `python3` as the
task user, including its required Unix standard-library modules. If that fails,
setup installs `python3` with apt as root in the disposable container, then
repeats the probe as the task user. Existing working interpreters are reused.
Provisioning includes `ca-certificates`. Before launching a network-enabled
profile, the adapter also checks that Python's HTTPS trust store contains CA
certificates and attempts the same provisioning if needed. Offline profiles do
not require a trust store. Restricted task images must include their trusted
certificates when the task policy prevents downloading the missing package;
certificate verification and task network restrictions remain enforced.
Installation has a 180-second timeout and may require package-repository access;
unsupported package managers, denied permissions, and unavailable repositories
remain explicit setup failures before native execution. Task definitions and
the agent loop are unchanged. `agent/setup.log` records the commands, interpreter
path/version, exit codes, and bounded output, including failed setup attempts.

## Run the fixture

Run these recipes from the repository root:

```sh
just check-harbor-fixture
just run-harbor-smoke-test
```

All five Sumika run recipes load [sumika.yaml](sumika.yaml) for the agent, model,
Release binary, reasoning effort, Docker environment, concurrency, attempt count,
and jobs directory. Its paths are relative to the repository root. Task selection,
timeout multipliers, and the resume flag stay in `Justfile`, along with the Release
build, fresh job name, evidence plugin, and final evidence check. The evidence
check still runs after Harbor fails, and either failure makes the recipe fail.

The fixture check runs `nop` and `oracle` sequentially and fails unless their
fresh, completed trials have rewards `0` and `1`, respectively, with no trial
exceptions. Results are kept under `tmp/harbor/baseline` and `tmp/harbor/oracle`.
Run it during initial setup and after fixture, verifier, or container changes.

`run-harbor-smoke-test` builds `SumikaEval` in Release and runs only Sumika with
the installed `Swift-1.5-4bit-MLX` model. Its results are kept under `.harbor`.
Both recipes disable Harbor telemetry. To use another installed Sumika catalog
ID, replace `MODEL_ID` in this command. Keep `-n 1` to avoid competing local MLX
sessions:

```sh
harbor_job_name="$(uuidgen)"
HARBOR_TELEMETRY=0 PYTHONPATH="$PWD" uv run --project script/harbor --locked harbor run \
  -p script/harbor/tasks/merge-ranges \
  -a script.harbor.agent:SumikaAgent -m MODEL_ID -n 1 \
  --plugin script.harbor.evidence:EvidencePlugin \
  --ak binary="$PWD/.build/release/SumikaEval" \
  --jobs-dir "$PWD/tmp/harbor/sumika" --job-name "$harbor_job_name"
uv run --project script/harbor --locked python -B -m script.harbor.evidence \
  "$PWD/tmp/harbor/sumika/$harbor_job_name"
```

To override Work reasoning effort, add `--ak reasoning_effort=low` to the Harbor
command. The adapter forwards it as `SumikaEval --reasoning-level low`; accepted
levels are `low`, `medium`, and `xhigh`. Omitting the option preserves the selected
model's default. Invalid values and levels unsupported by the model fail explicitly.
Harbor validates the adapter's required `binary` path option and optional
`reasoning_effort` before queuing trials; unknown adapter options are rejected.
The provided run recipes explicitly select `low`. Harbor recognizes `reasoning_effort`
in its viewer's reasoning-effort column and filters. The old `reasoning_level`
option is rejected; use `reasoning_effort` instead.
The override is stored only in the trial's settings and appears in `runtime.json`,
`session.json`, and `mlx-trace.jsonl`; it does not change the app's settings or the
model's hard thinking-token ceiling.

The unchanged task must score `0`; the reference solution must score `1`. The
verifier checks the container's actual `/app/ranges.py`, independently of the
assistant's final answer. Reward `1` requires a fresh completion report after all
five verifier tests pass without skips, as well as a successful process exit.
An infrastructure error is not a model failure. Inspect
Harbor's trial `result.json` and verifier output separately from the native
`agent/result.json`, `agent/session.json`, `agent/runner.log`, and
`agent/mlx-trace.jsonl`.

Native `completed` and `needs_user` outcomes both proceed to Harbor's verifier;
neither implies a passing reward. `needs_user` records that the unattended runner
stopped at a question. Runner/model failures and timeouts remain trial exceptions.
The adapter never assigns the task reward.

## Run the development suite

```sh
just check-harbor-suite
just run-harbor-suite
```

Both recipes use `harbor_suite_dataset` and `harbor_suite_tasks` in `Justfile`.
The dataset is pinned by its full SHA-256 content digest, resolved from Hub's
`latest` on 2026-10-15 (dataset revision 1). Both calibration and evaluation use
the same dataset snapshot, including its task versions. To extend the suite, add
another `openthoughts/TASK_NAME` present in that snapshot to the shared task list.

`check-harbor-suite` runs `nop` followed by `oracle` on those tasks sequentially,
with one attempt per task and agent. It fails unless every selected task has
exactly one fresh, completed trial with no exception and reward `0` for `nop`
or `1` for `oracle`. Missing, duplicate, unexpected, or malformed results fail
the check. Results use fresh `suite-` job names under `tmp/harbor/baseline` and
`tmp/harbor/oracle`. No model or native build is needed. Run this during initial
suite setup and after task, verifier, image, or Harbor changes. The fixture check
above validates only `merge-ranges`; it does not calibrate these suite tasks.

`run-harbor-suite` builds `SumikaEval` once in Release and runs those tasks
sequentially, with one attempt each. Calibration remains a separate command.
Each run gets a fresh job directory under `.harbor`, followed by the evidence check.
Both recipes disable Harbor telemetry and use Docker. Retain Harbor's resolved
task digests when comparing runs. The dataset pin freezes task content; mutable
Docker image tags and external downloads still require separate pins.

To update the dataset, resolve the desired Hub version to its full SHA-256 digest
and replace `harbor_suite_dataset` in `Justfile`. Check that every selected task
exists in the new snapshot, then recalibrate before evaluating it. Updating
Harbor's `uv.lock` does not update this dataset pin.

Harbor owns the agent deadline, using the task's agent timeout and Harbor's
overrides and multipliers. The development recipes use an agent multiplier of 6.
The adapter requires a finite positive Harbor budget, validated from the retained
task, current checkpoint, and trial configuration before native launch. It passes
`--timeout-seconds harbor` to `SumikaEval`, which remains cancellable without
starting a second task timer. The old `--ak timeout_seconds` option is rejected;
configure the deadline through Harbor instead.

On Harbor timeout or cancellation, the adapter sends SIGTERM to the native process
group, allows five seconds for shutdown, then sends SIGKILL if necessary. Command
workers still drain before workspace capture. Command, HTTP, setup, and cleanup
limits are unchanged. Direct `SumikaEval` invocation retains its 600-second default
and accepts `--timeout-seconds` values greater than zero and at most 86,400.
Native `runtime.json` omits `timeoutSeconds` when Harbor owns the deadline; Harbor's
retained task and trial configurations describe that budget.

## Run the file_backup checkpoints

```sh
just run-harbor-file-backup
```

This recipe builds `SumikaEval` in Release and runs one trial of
`gabeorlanski/file_backup`, pinned to revision 6's SHA-256 digest in `Justfile`
(resolved from Hub on 2026-10-15). It uses the installed `Swift-1.5-4bit-MLX`
model, low reasoning, and a fresh job under `.harbor`, followed by the evidence
check even if Harbor fails. Calibrate the pinned task with `nop` and `oracle`
separately before its first evaluation and after task or environment changes.
This task reports core, isolated, and strict pass rates instead of a scalar
`reward`. No-op core correctness must be zero and oracle correctness must be one
at every checkpoint. No-op can earn partial strict credit from error cases that
accept any failing process exit.

The four checkpoints share the container workspace. This default recipe starts
a fresh native conversation and process at each checkpoint, with separate session
state, tool-loop budgets, model loading, and traces. For an explicitly resumed run:

```sh
just run-harbor-file-backup-resume
```

The resume recipe adds `--resume-trajectory` and retains the same pinned task,
model, low reasoning, Release build, Docker environment, sequential execution,
and evidence checks. Only a multi-checkpoint task with that flag uses the
persistent native worker. It keeps the loaded model, canonical conversation,
and eligible prompt cache in RAM between checkpoints. Each checkpoint appends
its instruction as a new user turn and gets a fresh tool-loop budget and its
own result, session snapshot, trace, and artifact capture. The worker is shut
down when the trial ends or fails; timeout and cancellation terminate it.
Task access is suspended while Harbor verifies each checkpoint. Resumed
checkpoints must keep the same network policy; a policy change stops the worker
before executing the next turn.
Nothing serializes the model's prompt cache to disk. Process reuse does not
guarantee a cache hit: model cache rules and the exact rendered prefix still
apply. No performance improvement has been verified.

Both recipes use timeout multiplier 1: the pinned task already allows 7,200
seconds per checkpoint and 600 seconds for each verifier. Task definitions,
continuation thresholds, and the mean reward strategy are unchanged. Report
fresh-conversation and resumed-conversation scores separately: retained history
changes the SlopCodeBench protocol. Inspect individual checkpoint rewards and
regressions too.

Harbor archives each checkpoint under `steps/<checkpoint>/{agent,verifier,artifacts}`.
Shared task and source provenance stays in the host-only `provenance/` directory,
outside Harbor's mounted logs. Each checkpoint retains its own environment,
instruction, native result, session, trace, and artifact manifest.
Harbor can omit the empty `/logs/artifacts` mount directory from a checkpoint
archive. Its exact empty manifest entry remains valid; other missing captures
still fail completeness.
The whole-trial `agent/completeness.json` checksums all archives and reports
attempted/skipped checkpoints. Invalid order, missing or changed evidence, and
unexplained skipped checkpoints fail completeness independently of reward.
Configured early stops do not require unattempted checkpoint artifacts; attempted
checkpoints with missing evidence remain incomplete.

Task, checkpoint, and run artifact declarations are validated together. Legacy
capture applies only when neither the task nor the current checkpoint declares
artifacts. This pinned task declares `/app` with build/cache exclusions at every
checkpoint. A root workspace requires declarations covering every checkpoint.

## Trial evidence

`just run-harbor` runs the selected single task, currently
`openthoughts/auth_token_race_condition` (working directory `/workspace`), pinned
by its full SHA-256 digest in the recipe's `-t` argument. This pin was resolved
from Hub's `latest` on 2026-10-15 and matches the task in the pinned suite dataset.
Update this standalone pin explicitly when selecting another task version.
The recipe uses the same model and checks only the newly created job under
`.harbor`. Task definitions are unchanged. Harbor collects the top-level
`artifacts` declared in the resolved `task.toml`, plus its conventional
`/logs/artifacts` directory, before verification. No recipe output paths are
required. Read `artifacts/manifest.json` for actual destinations and statuses;
a passing reward does not prove capture succeeded. No captured task or workspace
files are executed on the Mac.

For legacy tasks without artifact declarations, the adapter uses Harbor's own
collector to retain the resolved workspace and `/output` when the latter exists.
The workspace is probed with `pwd -P` through Harbor, honoring its configured
working directory or the image's `WORKDIR`, and passed to the bridge and native
runner. Collection runs after the native process and command workers drain.
An absent `/output` is not requested, so tasks such as pandas-etl and merge-ranges
only capture `/app`.
Probe failures and symlinked `/output` paths are recorded in
`agent/artifact-error.json`; copy failures remain failed manifest entries.
These failures make evidence incomplete without replacing the native outcome
or verifier reward. The checker requires the workspace recorded in
`agent/runtime.json` to appear in the capture manifest. Paths outside that
workspace and `/output` require task artifact declarations. Tasks whose workspace
is `/` must declare artifacts; legacy capture never archives the container root.

The checker reads the retained `provenance/task/task.toml` with the standard-library
TOML parser and validates saved reports with Pydantic. Run it from the repository
root in the locked host environment; it does not start Harbor or a model.
Declared files and directories must match the manifest's source, service,
destination, type, and configured exclusions. Run-level artifact requests are
also validated. Captures must stay under `artifacts/` without symlink ancestors.
Their contents are checksummed; correctness remains the verifier's job.
It also reads older root/first-checkpoint `agent/` provenance snapshots so existing
saved trials remain verifiable. New runs write only host-only `provenance/`;
the old layout exposed snapshots through Harbor's `/logs/agent` mount.

Legacy `openthoughts/python-api-rate-limit` tasks additionally require regular
`/output/report.json`, `/output/a.json`, and `/output/b.json` files. Missing files,
symlinks, or exclusions remain incomplete regardless of reward. This compatibility
check applies only while the task has no artifact declarations; remove it once
the task declares its outputs. Declared artifacts are the canonical contract.

Each trial additionally retains:

- `provenance/task/`: a host-side copy of the exact task, including setup, initial
  files, verifier, and reference solution. Its checksum must match Harbor's
  planned task. These copies are never exposed to the agent's workspace.
  Hub tasks use the resolved digest from Harbor's trial lock and its configured
  download directory, so mutable references such as `latest` are not resolved again.
- `provenance/reproduction.json`, `provenance/source.patch`, `provenance/source-untracked/`,
  and `provenance/Package.resolved`: source commit and working changes at run time,
  executable SHA-256, Swift and Python versions, installed Python package versions,
  the uv lockfile fingerprint, host architecture, and task fingerprints.
  Source metadata describes the checkout at run time; it does not claim that an
  arbitrary externally supplied binary was built from that checkout.
- `agent/environment.json`: resolved task image IDs/digests and effective
  workspace, network, CPU, memory, and storage configuration. Environment variable
  values and the bridge token are not included. The Compose image lookup uses
  the pinned Harbor version's Docker implementation.
- `agent/setup.log`: worker Python probes and any apt installation. Installed
  packages are container setup changes, separate from the retained base image ID.
- `agent/runtime.json`: effective model settings, Work/approval policy, budgets,
  native build configuration, host memory/OS, and SHA-256 fingerprints of every
  non-hidden regular file in the installed model directory. Weights are hashed
  before loading, not copied; this extra I/O counts toward the agent deadline.
- `agent/trajectory.json`: an ATIF projection derived from `session.json` and
  `mlx-trace.jsonl` for Harbor's trajectory viewer. Native messages, tool call IDs,
  arguments, results, and failures come from the session; generation metrics come
  from matching trace records. The native session remains the source of truth.
- `agent/completeness.json`: missing/invalid evidence, clipped trace rows, model
  request/response/stream-boundary counts, and checksums of retained files.
  Workspace symlinks are recorded without following their targets.

The plugin writes an incomplete marker before execution, assesses each ended
trial, and finalizes checksums after Harbor finishes logs and secret scrubbing.
Missing workspace/native/verifier artifacts, identity mismatches, malformed or
unpaired model traces, and clipped model content make evidence incomplete.
Bounded/redacted tool argument previews remain diagnostic projections; canonical
tool inputs and outputs stay in `session.json`. Tool output limits still apply.
Harbor reward and trial exceptions are preserved independently. Failed runs keep
their partial evidence; absent artifacts are never replaced with fabricated data.

Trajectory export runs after native execution and retains available partial
history on failed or interrupted runs. Assistant messages match trace generations
in order within each turn, only when their counts agree. Direct `finish_task`
summaries do not count as additional model calls. Prompt totals include cached
tokens (`fullPromptTokens`); cache hits use `reusedPromptTokens`; completion totals
use measured `generatedTokenCount`, including reasoning and tool-call tokens.
Missing or estimated counts stay unknown, and incomplete sums are omitted.
The same totals populate Harbor's agent usage fields for job summaries.
Export failures are recorded in `agent/trajectory-error.json` and
make evidence incomplete without replacing the native outcome or verifier reward.
Older archives without a trajectory remain valid under the existing evidence
requirements. The exporter changes no core agent, prompt, parser, or tool
execution behavior. Protocol-looking text in assistant output stays text; export
never interprets it as an executed tool or runs commands from the archive.

The recipe fails if the job has missing or changed evidence, regardless of reward.
For direct Sumika Harbor commands, include
`--plugin script.harbor.evidence:EvidencePlugin`. Task declarations and the
adapter's legacy fallback handle capture automatically. Then run the checker:

```sh
uv run --project script/harbor --locked python -B -m script.harbor.evidence /absolute/path/to/job-or-trial
```

The checker is read-only and also rejects changes since the plugin's final
assessment. It checks every discovered trial before failing, even when another
trial has a missing or malformed report, and still checks available trials when
job metadata is invalid or unfinished. It reports changed file paths, removes
duplicate saved/current issues, prints complete/incomplete totals, and exits
nonzero if any trial or job-level check fails. Harbor logs plugin errors without
necessarily returning a nonzero exit status, so the explicit check is required
for a complete-evidence gate.
Existing runs without these artifacts fail the check; they are not backfilled.
Retain the entire job directory, including Harbor config, lock, results, trial
logs, and verifier files. `.harbor/` and `tmp/` are ignored by Git; archive needed
runs separately.
Treat sessions, source/workspace copies, and traces as private diagnostic data.

## Transport contract

`bridge.py` binds a random port on `127.0.0.1`. The adapter passes its bearer token
only through the native process's `SUMIKA_HARBOR_TOKEN` environment variable. The
token is not placed in prompts, task commands, task environment variables, or
artifacts. HTTP requests use `POST /rpc`, `Authorization: Bearer ...`, and a JSON
object containing a unique string `id` and an `operation`.

| Operation | Request fields | Result fields |
| --- | --- | --- |
| `resolve` | `path` | `absolutePath`, `relativePath`, `isRegularFile` |
| `read` | `path`, `offset`, optional `maxBytes`, optional `expectedVersion` | `dataBase64`, `version` |
| `list` | `path` | `names` (basenames) |
| `write` | `path`, `dataBase64`, optional `expectedContentsBase64` | empty object |
| `run` | `executable`, `arguments`, `cwd`, `timeoutSeconds`, optional `standardInputBase64`, `maxStdoutBytes`, `maxStderrBytes`, `stdoutRetention`, `stderrRetention` | raw command result below |
| `resolveHost` | `host` | `addresses` (public addresses only) |
| `http` | `url`, `timeoutSeconds`, `maxRedirects`, optional `userAgent` | `url`, `statusCode`, `headers`, `dataBase64` |
| `cancel` | `targetRequestID` | `cancelled` |

Responses are `{id, result}` or `{id, error: {code, message}}`. File error codes
include `notFound`, `permissionDenied`, `pathOutsideWorkspace`,
`unsupportedURLScheme`, `contentChanged`, and `invalidArgument`; transport failures
use `transportFailure`. A null/absent expected value means unconditional write;
a supplied byte value must match the current file before atomic replacement.

The adapter passes Harbor's current `environment.network_policy` to SumikaEval
as `--network-policy` JSON. This includes agent-phase overrides and run-time host
merges, rather than reparsing the task's baseline. Public policies and nonempty
allowlists enable `web_search` and `web_fetch`; offline policies and empty
allowlists disable both. Direct CLI invocation defaults to offline. `runtime.json`
records this policy and the fixed DuckDuckGo/built-in web provider settings.

Web requests and DNS resolution use supervised Python children inside the task
container, with the same cancellation and descendant cleanup as commands.
The bridge rejects web operations while the effective policy is offline.
Public GET requests validate every redirect and resolved address, pin each
connection to a validated public IP, verify HTTPS certificates against the
original hostname, and cap response bytes. They do not use host HTTP clients,
DNS, proxies, or configured external scraping/search services; Harbor's container
firewall enforces the allowed destinations. Web errors never retry on the host.

Each read returns an opaque `version` from the opened file's identity, size,
and modification/change timestamps. The worker checks that version before and
again after reading. A read with `maxBytes: 0` pins a version without fetching
file content. Harbor's `withReader` supplies that version for every chunk,
including EOF reads; a mismatch fails with `contentChanged` before the page is
returned or recorded. This check is scoped to one tool call. Separate paginated
tool calls start fresh reads. Metadata checks detect ordinary changes; they do
not create an immutable filesystem snapshot.

Commands return `exitCode`, `durationMs`, `stdout`, `stderr`, `stdoutDataBase64`,
`timedOut`, `cancelled`, `stdoutTruncated`, `stderrTruncated`,
`stdoutOmittedBytes`, and `stderrOmittedBytes`. Retention accepts `prefix`,
`headTail`, and `tail`. Commands inherit only the task environment. The worker
terminates each command's process group on completion, timeout, or cancellation.
On Linux, each command worker is also a child subreaper: it kills and reaps
orphaned descendants even when they create a new session or double-fork. A command
response is returned only after this cleanup. Cleanup failures return
`transportFailure`; bridge shutdown fails if a command worker failed or could
not be drained, preventing the adapter from proceeding to verification.

## Checks and current limits

```sh
just check-harbor
```

`check-harbor` runs Ruff lint/format checks, builds the Release `SumikaEval`, and
runs Python adapter tests plus the native `SumikaEvalTests`. Use `lint-harbor`,
`build-harbor`, `test-harbor`, or `test-harbor-python` for narrower feedback.
`format-harbor` applies formatting. Ruff excludes task fixtures so their inputs,
reference solutions, and checksums stay stable. Its worker target stays Python 3.7.
`lint-harbor` also runs strict mypy checks on the new host boundary models in
`models.py`; the existing dynamic adapter modules are outside that initial scope.
`just final-check` includes the Python checks; its full Swift suite already covers
the native evaluation tests. CI runs Ruff and the Python suite on Linux, including
the descendant-cleanup tests that skip on macOS. These gates require neither Docker
nor an installed model. Fixture calibration and real-model smoke tests remain
explicit commands.

These tests use an explicit local fake environment and temporary files; they do
not prove Docker or MLX behavior. They cover authentication, token isolation,
binary reads, concurrent compare-and-swap, traversal and symlink rejection,
bounded output, command cancellation, and the fixture's failing/passing states.
Setup regressions cover interpreter reuse, provisioning, timeout, and failure
diagnostics. Reporting regressions cover stdout/stderr capture and checking all
trials after missing, malformed, or changed evidence. Worker errors retain bounded
head/tail excerpts from both returned streams; Harbor's Docker executor may merge
stderr into stdout. Request payloads and bridge credentials are not added to errors.
Loopback sockets must be permitted by the test runner's sandbox.
The locked environment includes Harbor for the adapter lifecycle and ATIF tests;
running with another Python interpreter may skip those tests if Harbor is absent.
Host result/checkpoint validation uses strict Pydantic types, preserving omitted
optional fields and additional native metadata. Saved evidence reports also use
strict validation. The container worker never imports these host models.
Recipe tests use `just --show` and `just --dry-run`, then execute recipes in a
temporary directory with fake `swift`, `uv`, and `uuidgen` commands. They check
the pinned resume invocation and evidence/exit-status handling without building
Swift packages or running Harbor, Docker, or a model. They skip if `just` is absent.

Detached-descendant regressions require Linux and skip on macOS. Run the bridge,
worker, and fixture tests in the pinned Linux image as the unprivileged task UID:

```sh
docker run --rm --network=none --user=10001:10001 --cap-drop=ALL \
  --security-opt=no-new-privileges --read-only --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount "type=bind,src=$PWD,dst=/repo,readonly" --workdir /repo \
  python:3.13.7-slim-bookworm python3 -B -m unittest -v script.harbor.test_bridge
```

These checks cover detached and double-forked children after completion,
cancellation, timeout, and bridge shutdown, including children that ignore TERM.
The non-Linux local fake retains process-group cleanup only. Descendant supervision
assumes the Linux worker remains alive; Docker remains the isolation and final
cleanup boundary if the worker is killed or cleanup fails.

The first bridge rejects all symlink paths, including internal symlinks that the
native filesystem adapter can accept. Full-file reads, writes, command input,
and each captured output stream have a 1 MiB limit; reads can page larger files.
Listings are capped at 10,000 entries and commands at 600 seconds. The workspace
root is the resolved container working directory; file operations accept POSIX
paths rather than file URLs.
Missing-file suggestions may be less complete remotely.
The Python image tag is versioned, not locked to an immutable image digest.

There is no host executor fallback, workspace bind mount, or Docker socket exposed
by this integration. Docker still supplies the isolation boundary: do not add
privileged mode or host mounts to these task definitions. Standard dataset
compatibility and repeated runs are not validated. This proof does not implement
ACP, MCP/skill injection, or native macOS task execution.
