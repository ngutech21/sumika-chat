#!/usr/bin/env python3
"""Regression checks for legacy traces and prefill/cancellation report fields."""

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
        with tempfile.TemporaryDirectory(prefix="sumika-prefill-report-") as temporary:
            directory = Path(temporary)
            trace = directory / "trace.jsonl"
            trace.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            subprocess.run(["xcrun", "swift", "-module-cache-path", str(directory / "cache"),
                            str(ROOT / "script/trace_performance_report.swift"), str(trace),
                            "--output-dir", str(directory), "--limit", "all"],
                           cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            report = json.loads((directory / "latest.json").read_text())
            complete, cancelled, legacy = report["generations"]
            self.assertEqual(complete["prefillTokensPerSecond"], 4096)
            self.assertEqual(complete["prefillChunkSizes"], [1024] * 7 + [1023, 1])
            self.assertEqual(cancelled["cancellationLatencyMs"], 125.5)
            self.assertEqual(cancelled["prefillProcessedPositions"], 1640)
            self.assertNotIn("prefillTokensPerSecond", cancelled)
            self.assertNotIn("prefillTokensPerSecond", legacy)
            self.assertNotIn("prefillChunkSizes", legacy)
            markdown = (directory / "latest.md").read_text()
            self.assertIn("7 x 1024, 1 x 1023, 1 x 1", markdown)
            self.assertIn("1640 / 8200", markdown)


if __name__ == "__main__":
    unittest.main()
