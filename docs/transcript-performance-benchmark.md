# Transcript Performance Benchmark

## Status

This document freezes the transcript performance baseline before any performance
optimization. The benchmark infrastructure and diagnostic counters are new, but
the transcript rendering, caching, diffing, and layout policies measured here
are unchanged.

The benchmark is designed around the product invariant that the transcript is
append-only: appending to the active assistant row must not recreate, parse,
measure, or configure stable historical rows. It covers the requested operating
range of 500 to 1,000 existing rows while retaining smaller fixtures as a scaling
reference.

The local review input that motivated this work is
`tmp/transcript-performance.md`. Because `tmp/` is ignored, the status matrix
below is the durable summary of those findings. The archived raw baseline and
the results below are the measurement source of truth for later optimization.

## Frozen baseline identity

| Field | Value |
|---|---|
| Run ID | `20260715T171532Z` |
| Generated | `2026-07-15T17:15:32Z` |
| Schema / fixture | `3` / `2` |
| Git commit / branch | `dc6c1505fb3bfc90669e62c2571affbb4ecbf2c0` / `master` |
| Git dirty | `true` because the benchmark infrastructure was uncommitted during capture |
| Source fingerprint | `b157619129400ebd276f3aec8158542356debfc661855cb112a9c190b2ba9610` |
| Protocol fingerprint | `a96bfa178918d21514386f6704ef716eb3287590d8c0eeee3fdb275a935b8cbb` |
| Machine | Mac16,9, Apple M4 Max, 16 cores, 128 GiB RAM |
| OS | macOS 26.5.2 (25F84) |
| Toolchain | Xcode 26.6 (17F113), Swift 6.3.3 |
| Build | Release app, whole-module `-O`; test harness `-Onone`; testability enabled |
| JSON SHA-256 | `3708fe7797bf09f0446a79c027336f1fd9cbc4036296213203e61e2d6e70de7b` |

The commit identifies the product baseline. The source fingerprint detects byte
changes in the explicitly listed measurement-relevant paths, including
untracked files, but it neither archives those bytes nor covers unrelated dirty
paths. The protocol fingerprint identifies the fixture, measurement, merge,
reporting, and `project.pbxproj` configuration used by the run. A candidate may have a
different source fingerprint, but it must retain the same schema, fixture,
protocol, settings, machine, toolchain, and build settings for a direct
comparison.

Instrumentation call sites, diagnostic-counter semantics, and the Xcode scheme
are covered by the source fingerprint, not the narrower protocol fingerprint.
Since source changes are expected during optimization, those semantics and the
scheme must remain manually invariant. If they change, increment the
fixture/schema contract and capture a new baseline rather than comparing across
the change.

The Release test target is intentionally compiled with `-Onone`. Xcode 26.6 / Swift
6.3.3 crashes in the SIL inliner while compiling existing test helpers at Release
optimization. The app and transcript implementation under measurement remain
whole-module `-O`; only benchmark orchestration is unoptimized.

## Measurement contract

- Each append adds exactly 40 ASCII characters to one active assistant message.
- Each append scenario runs one ordered, growing-tail trace: 5 warm-ups, one
  structural diagnostic sample, then 100 timed samples.
- Warm-ups and the structural sample mutate the same tail. The first timed
  sample therefore records `initial + 280` characters and the last records
  `initial + 4,240` characters.
- Each scenario runs in a fresh XCTest host process. The app is built once, then
  each case is executed with `test-without-building` in its own process.
- The viewport is 760 x 520 points. The resize case starts at 760 points and
  measures unseen widths down to 360 before revisiting cached widths.
- Timed work includes synchronous rendering, native row projection, AppKit
  update/reconfiguration, and a forced pending height/layout flush.
- The timer starts after the synthetic fixture has appended the text and rebuilt
  its `[ChatTurn]` input. It also bypasses the outer SwiftUI body/invalidation
  wrapper, callback wiring, and inset updates.
- Work counting and snapshot mutation are enabled only for the separate
  structural sample. Timed samples retain only the compiled no-recording guard.
- Percentiles use nearest rank: `ceil(p * count) - 1` after sorting.
- Every raw sample records trial, iteration, operation, effective active-tail
  length, width, total time, and all phase times.
- Memory is sampled before fixture creation, before harness creation, after cold
  apply, before timed samples, and after timed samples. CPU time is recorded for
  the timed trace.
- Debug trace, Main Thread Checker, Xcode performance diagnostics, code coverage,
  automatic package resolution, and parallel testing are disabled. XCTest
  injection is retained.
- Existing `ChatDiagnostics` signposts are enabled by
  `SUMIKA_PERFORMANCE_DIAGNOSTICS`. Per-case raw signposts are supplemental and
  are not used for benchmark gates.

The absolute streaming budgets are p95 at or below 8.0 ms and p99 below 16.7 ms.
The history-scaling gate requires the 1,000-row p95 to stay within the larger of
20% or 0.5 ms above the 10-row p95. The active-tail gate requires the 50,000-char
p95 to stay within the smaller of 2x or 2 ms above the 1,000-char p95.

The stricter append-only structural gate requires zero stable item projections,
row-wrapper projections, Markdown parses, height misses, and cell configurations.
Only the active row may do those kinds of work. Steady-state append scenarios
also require exact cache-entry-count stability.

## Scenario matrix

| Family | Cases | Purpose |
|---|---|---|
| History scaling | 10, 100, 500, and 1,000 stable rows with a 10,000-char paragraph tail | Isolate historical-row cost |
| Paragraph tail scaling | 500 stable rows with 1,000, 10,000, and 50,000-char tails | Isolate active Markdown paragraph cost |
| Open-fence tail scaling | 500 stable rows with 1,000, 10,000, and 50,000-char open code fences | Isolate the streaming code path without final highlighting |
| Combined worst case | 1,000 stable rows and a 50,000-char paragraph tail | Exercise both scaling dimensions together |
| Tool-heavy | One adversarial canonical batch of 500 completed `run_command` rows, each with a deterministic 2,048-char collapsed output | Expose worst-case tool-batch reconciliation cost |
| Mixed | 500 user, thinking, Markdown/table/open-code-fence, and completed tool rows | Heterogeneous smoke case without finalized highlighting |
| Attachment history | 500 stable rows; each of 250 user rows owns two text attachments; active assistant has none | Measure historical attachment identity, hash, layout, and view cost without thumbnail I/O |
| Resize | 1,000 stable rows, 10,000-char tail, 760 -> 360 -> 760 points | Separate cold unseen-width remeasurement from warm cached revisits |

Image attachments are deliberately excluded. Their visible path includes local
directory I/O, detached work, ImageIO decoding, and asynchronous row
reconfiguration. Cache-miss, cache-hit, and failure behavior need a separate
benchmark with an injectable thumbnail loader.

## Baseline results

| Scenario | Cold apply ms | p50 ms | p95 ms | p99 ms | Samples >=16.7 ms |
|---|---:|---:|---:|---:|---:|
| History 10 / tail 10k | 47.288 | 1.856 | 2.083 | 2.131 | 0 |
| History 100 / tail 10k | 173.764 | 2.251 | 2.572 | 2.666 | 0 |
| History 500 / tail 10k | 874.819 | 3.902 | 4.196 | 4.236 | 0 |
| History 1,000 / tail 10k | 1,760.164 | 6.013 | 6.529 | 6.666 | 0 |
| History 500 / paragraph tail 1k | 855.538 | 3.638 | 4.442 | 4.545 | 0 |
| History 500 / paragraph tail 10k | 878.076 | 3.795 | 4.235 | 4.269 | 0 |
| History 500 / paragraph tail 50k | 885.570 | 8.817 | 9.436 | 9.747 | 0 |
| History 500 / open fence 1k | 870.110 | 2.638 | 2.741 | 2.785 | 0 |
| History 500 / open fence 10k | 871.971 | 2.883 | 3.128 | 3.224 | 0 |
| History 500 / open fence 50k | 888.227 | 4.503 | 4.812 | 4.956 | 0 |
| Worst: history 1,000 / paragraph tail 50k | 1,757.027 | 10.961 | 11.521 | 11.610 | 0 |
| Tool-heavy 500 / tail 10k | 1,048.872 | 99.008 | 105.364 | 106.318 | 100 |
| Mixed 500 / tail 10k | 926.442 | 4.913 | 5.139 | 5.198 | 0 |
| Attachment history 500 / tail 10k | 1,363.149 | 4.023 | 4.298 | 4.313 | 0 |
| Resize 1,000 / 760 -> 360 -> 760 | 1,752.713 | 6.854 | 1,135.688 | 1,135.688 | 9 of 19 |

The resize distribution combines two intentionally different legs. Cold unseen
widths have p50 1,005.111 ms and p95 1,135.688 ms. Warm revisits have p50 6.507
ms and p95 6.854 ms. No streaming budget is applied to resize.

Two independently hosted cases use the same effective 500-row/10,000-char
fixture: history scaling measured p95 4.196 ms and tail scaling measured p95
4.235 ms. Their 0.039 ms difference is a useful within-run indication of noise;
it is not a regression.

## What is already incremental

For every append case, the structural sample recorded all of the following for
stable history:

- zero semantic rendered-item projections;
- zero Markdown parses;
- zero height-cache misses;
- zero visible-cell configurations; and
- zero unattributed diagnostic events.

All append-case renderer, height, and Markdown cache entry counts were identical
before the structural sample, after it, and after 100 timed appends. The active
row alone was reprojected, remeasured, parsed when appropriate, and configured.
Open code fences intentionally recorded no active Markdown parse.

This proves that stable message content is not semantically rerendered. It does
not yet satisfy the stricter append-only goal because
`NativeTranscriptRow.rows(for:showsGenerationIndicator:)` still reconstructs one
lightweight row wrapper
for every stable item on every append: 10, 100, 500, or 1,000 wrappers exactly.
That is only the directly counted part: renderer cache pruning still scans its
collections, and the coordinator rebuilds row-ID arrays, dictionaries, diff
inputs, and cache-pruning sets. These O(N) reconciliation passes are visible in
the renderer and AppKit phases even though stable cells and their content remain
untouched.

## Open performance findings

1. **Historical row count still affects every append.** The 10-row p95 is 2.083
   ms and the 1,000-row p95 is 6.529 ms, or 3.13x. The allowed value was 2.583
   ms. Absolute latency is still below 8 ms, but the append-only scaling gate
   fails. Stable wrapper creation, full-collection cache pruning, row-ID and
   dictionary construction, and diff preparation are remaining O(N) work.

2. **Tool-heavy history dominates the renderer phase.** The 500-tool-row case
   has p95 105.364 ms, with 101.047 ms in the renderer phase. All 100 samples
   exceed 16.7 ms despite zero stable semantic projections. Code inspection
   identifies a primary quadratic path: before checking whether an anchor was
   already visited, `ToolApprovalBatchPresentation.presentations` calls
   `turn.toolCallBatch(containing:)` for every tool record; that method rebuilds
   and scans all tool batches each time. This is O(N^2) for the 500-record single
   batch and is consistent with the renderer timing. A long history split across
   many normal-sized turns/batches is not yet measured and may behave very
   differently.

3. **A very long active paragraph exceeds the tail-scaling budget.** With 500 stable rows, the
   50,000-char paragraph p95 is 9.436 ms versus 4.442 ms at 1,000 chars. It
   exceeds both the 8 ms absolute budget and the 6.442 ms scaling allowance. The
   renderer, AppKit update, and height/layout phases all grow.

   The equivalent open-fence p95 is much lower at 4.812 ms, consistent with
   avoiding live Markdown parsing while the fence is open. It nevertheless
   misses its strict scaling allowance of 4.741 ms by 0.071 ms. This gate is
   noise-sensitive because the allowance itself depends on the 1,000-char
   sample. Treat it as borderline until repeated A/B runs establish a
   distribution.

4. **The combined requested worst case misses p95 but stays below the 60 Hz
   frame budget.**
   At 1,000 stable rows and a 50,000-char paragraph, p95 is 11.521 ms and p99 is
   11.610 ms. No sample exceeds 16.7 ms, but the 8 ms headroom target fails.

5. **Unseen widths trigger full-history layout.** Each cold resize width costs
   roughly one second for 1,001 rows. Height-cache entries grow from 2,002 before
   resize to 3,003 after the structural width, then 12,012 after all unseen
   widths. Warm revisits are much faster, but the cache retains each active
   row's current revision at every visited width and has no global capacity or
   LRU bound.

6. **Text attachments are not a steady-stream bottleneck.** Compared with the
   same-size plain 500-row fixture, attachment-history p95 is only 0.102 ms
   higher (4.298 vs 4.196 ms). Cold apply is 488.330 ms higher (1,363.149 vs
   874.819 ms), and final RSS is 400.1 vs 302.5 MiB. This single run suggests that
   text attachments matter more for initial construction and memory than for
   steady append latency; repeated runs are required for a causal conclusion.

7. **Cold construction grows materially with history, but is only informational.** Cold
   apply grows from 47.288 ms for 10 rows to 874.819 ms for 500 and 1,760.164 ms
   for 1,000. This does not affect a steady append, but it matters when opening a
   long existing chat. These are single observations; a dedicated repeated,
   multi-process cold benchmark with phase attribution is required before
   setting an acceptance target.

## Status of the original review findings

| Original finding | Current status | Evidence / remaining gap |
|---|---|---|
| Hand-coded row heights diverge from actual view layout | Resolved | Height now comes from the configured native cell and `fittingSize` rather than parallel arithmetic. |
| Height and content parse the same Markdown twice | Resolved | Height and visible configuration share `NativeTranscriptMarkdownCache`; stable parses are zero. |
| Streaming rebuilds the complete cell tree | Resolved for the normal active-row path | Stable cells are never configured; the active text host uses incremental storage/block behavior. Stateful reuse still lacks direct lifecycle coverage. |
| Streaming revisions grow content caches without bound | Partially resolved | Old active revisions are pruned and steady append counts stay constant. There is still no global max/LRU, and height entries accumulate by width. |
| Horizontal resize leaves stale heights | Partially resolved | A coordinator update detects width changes and the synthetic resize case remeasures without semantic recreation. The real window/clip-view resize lifecycle is not covered, so a missed update remains possible. |
| Table measurement and live layout use different widths | Resolved | Shared table layout metrics drive measurement and layout. |
| Scroll-to-bottom races the 60 ms height debounce | Resolved in code | Scrolling is re-anchored in the height flush. The benchmark forces the flush and does not test the real async cadence. |
| Selection is lost during streaming | Partially open | Plain text storage is stable; the volatile Markdown tail can still replace rendered structure. This is primarily a UX lifecycle issue. |
| Live code highlighting causes repeated work | Resolved by design for open streaming fences | Open fences remain unhighlighted during streaming. Finalized code and asynchronous highlighting are outside this microbenchmark. |
| Image thumbnail lifecycle / zero-sized image | Open, not measured | Image fixtures are excluded; correctness and async cache lifecycle need separate tests. |
| Emoji/CJK highlight ranges | Open correctness issue | Not a demonstrated performance bottleneck. |
| `scrollRevision` dead code | Resolved | Removed. |
| URL spaces/unicode, editing attributes, thematic-break rendering | Open correctness/polish | Not performance findings. |
| Main-actor isolation and inline-code background | Resolved | Current implementation carries the intended isolation and styling. |
| Link-scheme security policy | Product decision still open | Not a demonstrated performance issue. |
| Notification observer cleanup | Resolved by removal | The reviewed bounds observer no longer exists. |

Remaining test gaps from the original review are the actual window-resize
lifecycle, real 60 ms run-loop scheduling, cell `prepareForReuse`, thumbnail-store
lifecycle, image decode/reconfiguration, and the 48-point pinned-to-bottom
threshold. Large transcript behavior now has a repeatable synchronous
microbenchmark but not an end-to-end display test.

## Reproduce a candidate

Run on the same machine and toolchain while the machine is otherwise idle:

```sh
just transcript-benchmark 100 5
```

The command writes ignored local artifacts under `.perf/`:

- `.perf/transcript/<run>-baseline.json`: complete raw samples and metadata;
- `.perf/transcript/<run>-baseline.md`: generated human-readable report;
- `.perf/xcresults/<run>-transcript-benchmark/`: one result bundle per case; and
- `.perf/signposts/<run>-transcript-benchmark/`: per-case reports and gzipped raw
  signpost exports.

This frozen run produced 15 XCTest result bundles and 15 gzipped raw signpost
files. Its local raw JSON is approximately 660 KiB. `.perf/transcript/latest.*`
points to the most recent local run and must not be treated as a stable baseline
name.

The repository baseline archive is
`docs/benchmarks/transcript/20260715T171532Z-baseline.json.gz`. Restore it after a
clean checkout before comparison:

```sh
mkdir -p .perf/transcript
gzip -dc docs/benchmarks/transcript/20260715T171532Z-baseline.json.gz \
  > .perf/transcript/20260715T171532Z-baseline.json
```

The per-case signpost exports from this baseline did not pass PID/interval-count
isolation: second-resolution windows either truncate a test host or include an
adjacent one. Their generated `source` field also names the pre-gzip `.json`
instead of the retained `.json.gz`. Preserve them only as troubleshooting data;
the benchmark JSON, generated report, and passing XCResults are the quantitative
sources of truth.

Compare the frozen JSON with a candidate JSON:

```sh
just transcript-benchmark-compare \
  .perf/transcript/20260715T171532Z-baseline.json \
  .perf/transcript/<candidate>-baseline.json \
  .perf/transcript/<candidate>-vs-20260715T171532Z.md
```

The comparison rejects incompatible schema, protocol, fixture/settings,
machine, OS/toolchain, or build configuration. A different source fingerprint
is expected after an optimization. Failed benchmark gates describe the measured
baseline or candidate; they do not make the comparison command itself a test
failure, and the comparer intentionally does not invent a regression threshold.
After an OS, Xcode, or Swift update, rerun both revisions in the same new
environment instead of weakening compatibility checks.

For a decision-quality A/B result, collect at least three full runs of each
revision and interleave their order (A/B, then B/A) to reduce thermal and system
load bias. Report the median run plus the individual raw reports. Fresh case
processes reduce allocator carry-over, but do not eliminate thermal state,
case-order bias, OS/font/shared caches, or machine noise. Cross-scenario gates
are only intra-run invariants. Do not compare smoke runs with fewer samples to
this 100-sample baseline.

## Limitations

- This is an offscreen AppKit microbenchmark, not visible display-frame latency.
- The benchmark forces the pending height flush synchronously and therefore does
  not measure the real 60 ms coalescing delay, batching across appends, run-loop
  scheduling, or scroll animation behavior. Per-append forced layout is
  intentionally conservative.
- One trace per case means samples are ordered and correlated as the active tail
  grows. They are not independent trials. With 100 samples, p99 is the
  second-largest sample; the 19-leg resize quantiles are much coarser.
- Model generation, tokenization, persistence, networking, workspace tools, and
  user input are excluded.
- Each cold-apply number is one observation, not a distribution. Resize
  quantiles aggregate nine different cold widths or ten different warm widths;
  they are not repeated trials at one width.
- No case finalizes a code fence or exercises asynchronous syntax highlighting;
  the mixed fixture's code fence remains open and highlight caches stay empty.
- History scaling uses short alternating user text and short assistant lists to
  isolate row count. It does not represent 1,000 historically long Markdown,
  code, or tool payloads.
- Cold apply, memory, and CPU numbers include the XCTest host and are best used
  as same-environment deltas, not standalone app resource claims.
- Signposts are selected by subsystem, category, process name, and case time
  window, not an exact process identifier. The benchmark flag also enables those
  signposts, so their overhead is present in absolute timings. Exports can contain
  an adjacent test-host PID or incomplete intervals; validate PID and interval
  counts before using them. They include cold, structural, and timed work and are
  supplemental evidence only.
- The synthetic resize calls the coordinator with each width. It does not prove
  that every real window/clip-view resize produces the required SwiftUI update.
- Text attachments exclude thumbnail I/O and asynchronous image decode.
