#!/usr/bin/env python3
"""Regression checks for legacy traces and generation diagnostic reports."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class TracePerformanceReportTests(unittest.TestCase):
    def test_prefill_and_cancelled_partial_generation(self):
        rows = [
            dict(kind="turn_trace", generationID="completed", phase="runtime_prefill",
                 durationMs=2000, promptTokens=8192, fullPromptTokens=16384, reusedPromptTokens=8192),
            dict(kind="turn_trace", generationID="completed", phase="runtime_stream_end",
                 prefillStepSize=1024, prefillChunkSizes=[1024] * 7 + [1023, 1],
                 prefillProcessedPositions=8192, prefillTotalPositions=8192),
            dict(kind="turn_trace", generationID="cancelled", phase="runtime_stream_end",
                 prefillStepSize=2048, prefillChunkSizes=[1640],
                 prefillProcessedPositions=1640, prefillTotalPositions=8200, cancellationLatencyMs=125.5),
            dict(kind="turn_trace", generationID="legacy", phase="runtime_prefill",
                 durationMs=0, promptTokens=512),
        ]
        report, markdown = self.report(rows)
        complete, cancelled, legacy = report["generations"]
        self.assertEqual(complete["prefillTokensPerSecond"], 4096)
        self.assertEqual(complete["prefillChunkSizes"], [1024] * 7 + [1023, 1])
        self.assertEqual(cancelled["cancellationLatencyMs"], 125.5)
        self.assertEqual(cancelled["prefillProcessedPositions"], 1640)
        self.assertNotIn("prefillTokensPerSecond", cancelled)
        self.assertNotIn("prefillTokensPerSecond", legacy)
        self.assertNotIn("prefillChunkSizes", legacy)
        self.assertIn("7 x 1024, 1 x 1023, 1 x 1", markdown)
        self.assertIn("1640 / 8200", markdown)

    def test_completion_counts_and_cache_allocations(self):
        before = dict(phase="planned", allocatedBytes=0, layers=[])
        after = dict(phase="realized", allocatedBytes=2 * 1024 * 1024, layers=[
            dict(path=[0], kind="attention(maxSize: nil)", allocatedBytes=1024 * 1024),
            dict(path=[1, 0], kind="stateSpace", allocatedBytes=1024 * 1024),
        ])
        rows = [
            dict(kind="turn_trace", generationID="complete", phase="runtime_stream_end",
                 evictedTokenCount=0, reasoningTokenCount=8, answerTokenCount=12,
                 proposedDraftTokens=10, acceptedDraftTokens=7, mtpAcceptanceRate=0.7,
                 cacheAllocationBefore=before, cacheAllocationAfter=after),
            dict(kind="turn_trace", generationID="zero-proposals", phase="runtime_stream_end",
                 evictedTokenCount=12, proposedDraftTokens=0, acceptedDraftTokens=0),
            dict(kind="turn_trace", generationID="zero-accepted", phase="runtime_stream_end",
                 proposedDraftTokens=10, acceptedDraftTokens=0, mtpAcceptanceRate=0.0),
            dict(kind="turn_trace", generationID="legacy", phase="runtime_stream_end"),
        ]
        report, markdown = self.report(rows)
        complete, zero_proposals, zero_accepted, legacy = report["generations"]
        for key in ("evictedTokenCount", "reasoningTokenCount", "answerTokenCount",
                    "proposedDraftTokens", "acceptedDraftTokens", "mtpAcceptanceRate"):
            self.assertEqual(complete[key], rows[0][key])
            self.assertNotIn(key, legacy)
        self.assertEqual(complete["cacheAllocationBefore"], before)
        self.assertEqual(complete["cacheAllocationAfter"], after)
        self.assertEqual(zero_proposals["evictedTokenCount"], 12)
        self.assertEqual(zero_proposals["proposedDraftTokens"], 0)
        self.assertEqual(zero_proposals["acceptedDraftTokens"], 0)
        self.assertNotIn("mtpAcceptanceRate", zero_proposals)
        self.assertNotIn("reasoningTokenCount", zero_proposals)
        self.assertNotIn("cacheAllocationAfter", zero_proposals)
        self.assertEqual(zero_accepted["mtpAcceptanceRate"], 0)
        self.assertIn("0.00 (planned)", markdown)
        self.assertIn("2.00 (realized)", markdown)
        self.assertIn("| 0 | 8 | 12 | 10 | 7 | 70.0 |", markdown)
        self.assertIn("| zero-proposals | - | - | 12 | - | - | 0 | 0 | - |", markdown)
        self.assertIn("| zero-accepted | - | - | - | - | - | 10 | 0 | 0.0 |", markdown)
        self.assertIn("| legacy | - | - | - | - | - | - | - | - |", markdown)

    def report(self, rows):
        with tempfile.TemporaryDirectory(prefix="sumika-trace-report-") as temporary:
            directory = Path(temporary)
            trace = directory / "trace.jsonl"
            trace.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            result = subprocess.run(
                ["xcrun", "swift", "-module-cache-path", str(directory / "cache"),
                 str(ROOT / "script/trace_performance_report.swift"), str(trace),
                 "--output-dir", str(directory), "--limit", "all"],
                cwd=ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((directory / "latest.json").read_text())
            markdown = (directory / "latest.md").read_text()
            return report, markdown


if __name__ == "__main__":
    unittest.main()
