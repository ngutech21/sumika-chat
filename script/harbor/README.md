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

- Build the native runner from the repository root:

  ```sh
  swift build --product SumikaEval
  ```

The task image is `python:3.13.7-slim-bookworm`, with an unprivileged task user.
Image pulls and builds may require network access. The task disables network
access while running; no model download is performed by the runner.

## Run the fixture

Run these recipes from the repository root:

```sh
just check-harbor-fixture
just run-harbor
```

The fixture check runs `nop` and `oracle` sequentially and fails unless their
fresh, completed trials have rewards `0` and `1`, respectively, with no trial
exceptions. Results are kept under `tmp/harbor/baseline` and `tmp/harbor/oracle`.
Run it during initial setup and after fixture, verifier, or container changes.

`run-harbor` builds `SumikaEval` and runs only Sumika with the installed
`Swift-1.5-4bit-MLX` model. Its results are kept under `tmp/harbor/sumika`.
Both recipes disable Harbor telemetry. To use another installed Sumika catalog
ID, replace `MODEL_ID` in this command. Keep `-n 1` to avoid competing local MLX
sessions:

```sh
harbor_job_name="$(uuidgen)"
HARBOR_TELEMETRY=0 PYTHONPATH="$PWD" harbor run -p script/harbor/tasks/merge-ranges \
  -a script.harbor.agent:SumikaAgent -m MODEL_ID -n 1 \
  --artifact /app --plugin script.harbor.evidence:EvidencePlugin \
  --ak binary="$PWD/.build/debug/SumikaEval" \
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

## Trial evidence

`run-harbor` enables workspace capture and the evidence plugin, then checks only
the newly created job. Task definitions are unchanged. Harbor collects `/app`
after Sumika and its command workers drain, before verification, under the
existing `artifacts/` directory. Read `artifacts/manifest.json` for the actual
destination and collection status; a passing reward does not prove capture
succeeded. No captured task or workspace files are executed on the Mac.

Each trial additionally retains:

- `agent/task/`: a host-side copy of the exact task, including setup, initial
  files, verifier, and reference solution. Its checksum must match Harbor's
  planned task. These copies are never exposed to the agent's workspace.
- `agent/reproduction.json`, `agent/source.patch`, `agent/source-untracked/`,
  and `agent/Package.resolved`: source commit and working changes at run time,
  executable SHA-256, Swift version, host architecture, and task fingerprints.
  Source metadata describes the checkout at run time; it does not claim that an
  arbitrary externally supplied binary was built from that checkout.
- `agent/environment.json`: resolved task image IDs/digests and effective
  workspace, network, CPU, memory, and storage configuration. Environment variable
  values and the bridge token are not included. The Compose image lookup uses
  the pinned Harbor version's Docker implementation.
- `agent/runtime.json`: effective model settings, Work/approval policy, budgets,
  native build configuration, host memory/OS, and SHA-256 fingerprints of every
  non-hidden regular file in the installed model directory. Weights are hashed
  before loading, not copied; this extra I/O counts toward the runner deadline.
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

The recipe fails if the job has missing or changed evidence, regardless of reward.
For direct Harbor commands, include both evidence flags above and run the checker:

```sh
python3 -B script/harbor/evidence.py /absolute/path/to/job-or-trial
```

The checker is read-only and also rejects changes since the plugin's final
assessment. Harbor logs plugin errors without necessarily returning a nonzero
exit status, so the explicit check is required for a complete-evidence gate.
Existing runs without these artifacts fail the check; they are not backfilled.
Retain the entire job directory, including Harbor config, lock, results, trial
logs, and verifier files. `tmp/` is ignored by Git; archive needed runs separately.
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
| `cancel` | `targetRequestID` | `cancelled` |

Responses are `{id, result}` or `{id, error: {code, message}}`. File error codes
include `notFound`, `permissionDenied`, `pathOutsideWorkspace`,
`unsupportedURLScheme`, `contentChanged`, and `invalidArgument`; transport failures
use `transportFailure`. A null/absent expected value means unconditional write;
a supplied byte value must match the current file before atomic replacement.

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
Loopback sockets must be permitted by the test runner's sandbox.
Adapter lifecycle tests also need Harbor installed in that Python interpreter;
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
privileged mode or host mounts to these task definitions. This proof does not
implement standard datasets, repeated runs, ACP, ATIF export, MCP/skill injection,
or native macOS task execution.
