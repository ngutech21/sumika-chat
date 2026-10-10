#!/usr/bin/env python3
"""Exercise Metal setup without downloading or changing the host toolchain."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("ensure-metal.sh")
MOCK = """#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\\n' "${0##*/}" "$*" >> "$METAL_TEST_DIR/calls"
case "${0##*/}" in
  xcrun)
    if [[ "$*" == '--kill-cache' ]]; then
      rm -f "$METAL_TEST_DIR/stale"
      exit 0
    fi
    [[ "$*" == '--sdk macosx metal --version' ]] || exit 99
    if [[ ! -f "$METAL_TEST_DIR/installed" || -f "$METAL_TEST_DIR/stale" ]] ||
       [[ "$(cat "$METAL_TEST_DIR/waits")" -lt "$METAL_TEST_DELAY" ]]; then
      touch "$METAL_TEST_DIR/stale"
      printf "error: cannot execute tool 'metal' due to missing Metal Toolchain\\n" >&2
      exit 1
    fi
    printf 'Apple metal version test\\n'
    ;;
  xcodebuild)
    [[ "$*" == '-downloadComponent metalToolchain' ]] || exit 99
    [[ "$METAL_TEST_DOWNLOAD_FAILS" == 0 ]] || exit 42
    touch "$METAL_TEST_DIR/installed"
    ;;
  sleep)
    [[ "$*" == 5 ]] || exit 99
    waits="$(cat "$METAL_TEST_DIR/waits")"
    printf '%s\\n' "$((waits + 1))" > "$METAL_TEST_DIR/waits"
    ;;
esac
"""


class MetalToolchainTests(unittest.TestCase):
    def run_setup(self, *, installed=False, stale=False, delay=0, download_fails=False):
        with tempfile.TemporaryDirectory(prefix="sumika-metal-test-") as temporary:
            directory = Path(temporary)
            for name in ("xcrun", "xcodebuild", "sleep"):
                command = directory / name
                command.write_text(MOCK)
                command.chmod(0o755)
            for name, present in (("installed", installed), ("stale", stale)):
                if present:
                    (directory / name).touch()
            (directory / "waits").write_text("0\n")
            env = dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                       METAL_TEST_DIR=str(directory), METAL_TEST_DELAY=str(delay),
                       METAL_TEST_DOWNLOAD_FAILS=str(int(download_fails)))
            result = subprocess.run(["bash", "-e", "-o", "pipefail", str(SCRIPT)],
                                    env=env, capture_output=True, text=True, timeout=10)
            return result, (directory / "calls").read_text().splitlines()

    def test_available_toolchain_skips_download(self):
        result, calls = self.run_setup(installed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("xcodebuild ") for call in calls))

    def test_stale_lookup_skips_unnecessary_download(self):
        result, calls = self.run_setup(installed=True, stale=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("xcodebuild ") for call in calls))

    def test_download_clears_cached_placeholder(self):
        result, calls = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("xcodebuild -downloadComponent metalToolchain"), 1)

    def test_delayed_registration_retries(self):
        for delay in (2, 11):
            with self.subTest(delay=delay):
                result, calls = self.run_setup(delay=delay)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls.count("sleep 5"), delay)
                self.assertEqual(calls.count("xcodebuild -downloadComponent metalToolchain"), 1)

    def test_failed_download_stops_immediately(self):
        result, calls = self.run_setup(download_fails=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(calls[-1], "xcodebuild -downloadComponent metalToolchain")

    def test_unavailable_toolchain_has_bounded_retries(self):
        result, calls = self.run_setup(delay=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::", result.stderr)
        self.assertEqual(calls.count("sleep 5"), 11)
        self.assertEqual(calls.count("xcrun --sdk macosx metal --version"), 13)


if __name__ == "__main__":
    unittest.main()
