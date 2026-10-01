#!/usr/bin/env python3
"""Run isolated local-model cases and summarize the existing MLX performance reports."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parent.parent


def command_output(arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def summarize(results, destination, planned_cases):
    lines = [
        "# MLX prefill benchmark", "",
        f"Completed cases: {len(results)} / {planned_cases}.", "",
        "Cold means an empty conversation cache after kernel warmup. Warm uses an independently seeded 2K prefix.",
        "Each case runs in a separate process. Peak MLX memory is reset after warmup/seeding, immediately before the measured request.",
        "Chunk counts describe graph submission. Cancellation is requested 250 ms after stream creation and measured through producer/GPU drain.",
        "Throughput and TTFT are medians; peak memory and cancellation latency are maxima across repetitions.",
        "",
        "| Model | Mode | Requested positions | Ceiling | Runs | Actual positions | TTFT ms | Prefill tok/s | Decode tok/s | Peak MiB | Cancel ms |",
        "|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|",
    ]
    groups = {}
    for case, generation, peak in results:
        key = tuple(case[name] for name in ("model", "mode", "tokens", "step"))
        groups.setdefault(key, []).append((generation, peak))
    for key, values in sorted(groups.items()):
        def metric(name, maximum=False):
            samples = [value[name] for value, _ in values if value.get(name) is not None]
            if not samples:
                return "-"
            return f"{(max(samples) if maximum else statistics.median(samples)):.2f}"

        actual = sorted({value["prefillTotalPositions"] for value, _ in values
                         if value.get("prefillTotalPositions") is not None})
        peaks = [peak for _, peak in values if peak is not None]
        row = [*map(str, key), str(len(values)), ", ".join(map(str, actual)) or "-",
               metric("ttftMs"), metric("prefillTokensPerSecond"), metric("tokensPerSecond"),
               f"{max(peaks) / 1048576:.2f}" if peaks else "-", metric("cancellationLatencyMs", True)]
        lines.append("| " + " | ".join(row) + " |")
    lines += ["", "Per-case reports contain the actual chunk sizes, cache decisions, and all timing samples.", ""]
    destination.write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", required=True, help="Installed Sumika model IDs")
    parser.add_argument("--tokens", nargs="+", type=int, default=[512, 2048, 8192, 8200, 16384])
    parser.add_argument("--steps", nargs="+", type=int, choices=[512, 1024, 2048], default=[512, 1024, 2048])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--modes", nargs="+", choices=["cold", "warm", "cancel-cold", "cancel-warm"],
                        default=["cold", "warm", "cancel-cold", "cancel-warm"])
    parser.add_argument("--models-path", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.repeats < 1 or any(tokens < 128 or tokens > 32768 for tokens in args.tokens):
        parser.error("Use at least one repetition and prompt sizes between 128 and 32768.")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output_dir or ROOT / ".perf" / "prefill" / stamp).resolve()
    output.mkdir(parents=True, exist_ok=False)
    planned_cases = len(args.models) * len(args.steps) * args.repeats * sum(
        1 for tokens in args.tokens for mode in args.modes
        if not mode.startswith("cancel-") or tokens >= 8192)
    models_path = args.models_path or Path.home() / "Library/Application Support/Sumika/Models"
    checkpoints = {}
    for model in args.models:
        directory = next((path for path in models_path.iterdir()
                          if path.is_dir() and path.name.lower() == model.lower()), None)
        if directory:
            print(f"Fingerprinting installed checkpoint: {directory.name}", flush=True)
            checkpoints[model] = {
                "directory": str(directory.resolve()),
                "files": {path.name: digest(path) for path in sorted(directory.iterdir())
                          if path.is_file() and path.suffix in (".json", ".safetensors")},
            }
    provenance = {
        "timestamp": stamp, "chip": command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "physicalMemoryBytes": int(command_output(["sysctl", "-n", "hw.memsize"])),
        "macOS": platform.mac_ver()[0], "gitCommit": command_output(["git", "rev-parse", "HEAD"]),
        "swiftVersion": command_output(["xcrun", "swift", "--version"]),
        "xcodeVersion": command_output(["xcodebuild", "-version"]),
        "gitStatus": command_output(["git", "status", "--short"]),
        "packages": json.loads((ROOT / "Package.resolved").read_text()),
        "checkpoints": checkpoints,
        "plannedCases": planned_cases,
        "arguments": {name: str(value) if isinstance(value, Path) else value for name, value in vars(args).items()},
        "sourceHashes": {str(path.relative_to(ROOT)): digest(path)
                         for base in ("Sources/SumikaRuntimeMLX", "Tests/SumikaRuntimeMLXTests", "script")
                         for path in sorted((ROOT / base).rglob("*"))
                         if path.is_file() and path.suffix in (".swift", ".py")},
    }
    (output / "environment.json").write_text(json.dumps(provenance, indent=2) + "\n")
    if not args.skip_build:
        print("Building Release benchmark tests...", flush=True)
        with (output / "build.log").open("w") as log:
            subprocess.run(["xcrun", "swift", "build", "--build-system", "swiftbuild", "-c", "release",
                            "--target", "SumikaRuntimeMLXTests", "-Xswiftc", "-enable-testing"],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    products = Path(command_output(["xcrun", "swift", "build", "--build-system", "swiftbuild",
                                    "-c", "release", "--show-bin-path"]))
    bundle = products / "SumikaRuntimeMLXTests.xctest"
    if not bundle.exists():
        raise RuntimeError(f"Release benchmark bundle missing: {bundle}")
    results = []
    prompt_hashes = {}
    for repetition in range(args.repeats):
        # Rotate ceiling order so the same variant is not always first.
        shift = repetition % len(args.steps)
        steps = args.steps[shift:] + args.steps[:shift]
        for model in args.models:
            for tokens in args.tokens:
                for mode in args.modes:
                    if mode.startswith("cancel-") and tokens < 8192:
                        continue
                    for step in steps:
                        case = dict(model=model, tokens=tokens, mode=mode, step=step)
                        name = f"{model.replace('/', '-')}-{mode}-{tokens}-{step}-r{repetition + 1}"
                        directory = output / name
                        directory.mkdir()
                        trace = directory / "mlx-trace.jsonl"
                        environment = {key: os.environ[key] for key in
                                       ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "LANG", "LC_ALL")
                                       if key in os.environ}
                        environment.update({
                            "SUMIKA_DEBUG_TRACE": "1", "SUMIKA_PREFILL_BENCHMARK_MODEL_ID": model,
                            "SUMIKA_PREFILL_BENCHMARK_STEP": str(step), "SUMIKA_PREFILL_BENCHMARK_TOKENS": str(tokens),
                            "SUMIKA_PREFILL_BENCHMARK_MODE": mode, "SUMIKA_PREFILL_BENCHMARK_TRACE": str(trace),
                        })
                        if args.models_path:
                            environment["SUMIKA_PREFILL_BENCHMARK_MODELS_PATH"] = str(args.models_path.resolve())
                        print(name, flush=True)
                        with (directory / "test.log").open("w") as log:
                            subprocess.run(["xcrun", "xctest", "-XCTest",
                                            "SumikaRuntimeMLXTests.MLXPrefillBenchmarkTests/testInstalledModelPrefill",
                                            str(bundle)], cwd=ROOT, env=environment,
                                           stdout=log, stderr=subprocess.STDOUT, check=True)
                        if not trace.exists():
                            raise RuntimeError(f"Benchmark skipped; inspect {directory / 'test.log'}")
                        subprocess.run(["xcrun", "swift", "script/trace_performance_report.swift", str(trace),
                                        "--output-dir", str(directory), "--model-id", model, "--scenario", name,
                                        "--limit", "1"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
                        report = json.loads((directory / "latest.json").read_text())
                        generation = report["generations"][-1]
                        if generation.get("prefillStepSize") != step:
                            raise RuntimeError("Trace does not confirm the requested prefill ceiling")
                        if not mode.startswith("cancel-"):
                            expected = "cold_prefill" if mode == "cold" else "exact_suffix_reuse"
                            if generation.get("mlxCacheDecision") != expected:
                                raise RuntimeError(f"Unexpected cache path: {generation.get('mlxCacheDecision')}")
                        rows = [json.loads(line) for line in trace.read_text().splitlines()]
                        request = next(row for row in rows if row.get("kind") == "mlx_request"
                                       and row.get("id") == generation["generationID"])
                        if request.get("promptTruncated") or any(message.get("truncated")
                                                                 for message in request["history"]):
                            raise RuntimeError("Trace truncated a benchmark input; use a smaller prompt to verify identical inputs")
                        prompt = json.dumps([request["history"], request["prompt"], request["settings"]], sort_keys=True)
                        key = (model, tokens, mode)
                        prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()
                        if prompt_hashes.setdefault(key, prompt_hash) != prompt_hash:
                            raise RuntimeError(f"Inputs differ between variants for {key}; do not compare these runs")
                        peak = next((row["peakMemoryBytes"] for row in report["memorySnapshots"]
                                     if row.get("generationID") == generation["generationID"]
                                     and row["memoryPhase"] == "generation_terminal"), None)
                        results.append((case, generation, peak))
                        summarize(results, output / "summary.md", planned_cases)
    print(f"Report: {output / 'summary.md'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        sys.exit(1)
