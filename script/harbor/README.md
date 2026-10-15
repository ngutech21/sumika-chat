# Sumika Harbor proof

This adapter runs the real Sumika Work loop and MLX model on the Mac. Its file
operations and commands execute inside a fresh Harbor Docker task. Task files are
never copied to the Mac for execution. The adapter currently supports one local
trial at a time and the included Python repair task.

## Requirements

- Apple Silicon Mac, Docker running, and an already-installed Sumika model.
- Python 3.13 and Harbor **0.24.0**. This is the version checked by the adapter.
  `requirements.txt` pins it; an existing installation can be checked with
  `harbor --version`. To install that exact version:

  ```sh
  uv tool install --python 3.13 'harbor==0.24.0'
  ```

- Build the native runner in Release from the repository root:

  ```sh
  swift build --configuration release --product SumikaEval
  ```

The fixture image is `python:3.13.7-slim-bookworm`, with an unprivileged task user.
Image pulls and builds may require network access. The fixture disables network
access while running; no model download is performed by the runner.

The container worker also needs Python. Adapter setup probes `python3` as the
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
HARBOR_TELEMETRY=0 PYTHONPATH="$PWD" harbor run -p script/harbor/tasks/merge-ranges \
  -a script.harbor.agent:SumikaAgent -m MODEL_ID -n 1 \
  --plugin script.harbor.evidence:EvidencePlugin \
  --ak binary="$PWD/.build/release/SumikaEval" \
  --ak timeout_seconds=600 --jobs-dir "$PWD/tmp/harbor/sumika" --job-name "$harbor_job_name"
python3 -B script/harbor/evidence.py "$PWD/tmp/harbor/sumika/$harbor_job_name"
```

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
To extend the suite, add another `openthoughts/TASK_NAME` to that shared task list.

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
Both recipes disable Harbor telemetry and use Docker. The dataset reference is
unversioned; retain Harbor's resolved task digests when comparing runs.

The native runner has a 3,300-second deadline per task. Harbor independently
enforces each task's agent timeout multiplied by 6. A shorter Harbor deadline
can end a task before the native runner's deadline.

## Trial evidence

`just run-harbor` runs the selected single task, currently
`openthoughts/pandas-etl`, with the same model and checks only the newly created
job under `.harbor`. Task definitions are unchanged. Harbor collects the
top-level `artifacts` declared in the resolved `task.toml`, plus its conventional
`/logs/artifacts` directory, before verification. No recipe output paths are
required. Read `artifacts/manifest.json` for actual destinations and statuses;
a passing reward does not prove capture succeeded. No captured task or workspace
files are executed on the Mac.

For legacy tasks without artifact declarations, the adapter uses Harbor's own
collector to retain `/app` and `/output` when the latter exists. Collection runs
after the native process and command workers drain. An absent `/output` is not
requested, so tasks such as pandas-etl and merge-ranges only capture `/app`.
Probe failures and symlinked `/output` paths are recorded in
`agent/artifact-error.json`; copy failures remain failed manifest entries.
These failures make evidence incomplete without replacing the native outcome
or verifier reward. This legacy fallback covers `/app` and `/output`, not
arbitrary undeclared paths elsewhere in the container.

The checker reads the retained `agent/task/task.toml` with the standard-library
TOML parser, so it still runs without Harbor installed in that Python interpreter.
Declared files and directories must match the manifest's source, service,
destination, type, and configured exclusions. Run-level artifact requests are
also validated. Captures must stay under `artifacts/` without symlink ancestors.
Their contents are checksummed; correctness remains the verifier's job.

Legacy `openthoughts/python-api-rate-limit` tasks additionally require regular
`/output/report.json`, `/output/a.json`, and `/output/b.json` files. Missing files,
symlinks, or exclusions remain incomplete regardless of reward. This compatibility
check applies only while the task has no artifact declarations; remove it once
the task declares its outputs. Declared artifacts are the canonical contract.

Each trial additionally retains:

- `agent/task/`: a host-side copy of the exact task, including setup, initial
  files, verifier, and reference solution. Its checksum must match Harbor's
  planned task. These copies are never exposed to the agent's workspace.
  Hub tasks use the resolved digest from Harbor's trial lock and its configured
  download directory, so mutable references such as `latest` are not resolved again.
- `agent/reproduction.json`, `agent/source.patch`, `agent/source-untracked/`,
  and `agent/Package.resolved`: source commit and working changes at run time,
  executable SHA-256, Swift version, host architecture, and task fingerprints.
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
  before loading, not copied; this extra I/O counts toward the runner deadline.
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
python3 -B script/harbor/evidence.py /absolute/path/to/job-or-trial
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
python3 -m unittest discover -s script/harbor -v
```

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
Adapter lifecycle and ATIF tests need Harbor installed in that Python interpreter;
they skip explicitly when it is unavailable.

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
root is fixed to `/app`; file operations accept POSIX paths rather than file URLs.
Missing-file suggestions may be less complete remotely.
The Python image tag is versioned, not locked to an immutable image digest.

There is no host executor fallback, workspace bind mount, or Docker socket exposed
by this integration. Docker still supplies the isolation boundary: do not add
privileged mode or host mounts to these task definitions. Standard dataset
compatibility and repeated runs are not validated. This proof does not implement
ACP, MCP/skill injection, or native macOS task execution.
