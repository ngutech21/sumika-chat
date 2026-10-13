"""Transport checks run without Harbor, Docker, or an MLX model."""

import asyncio
import base64
import contextlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

from script.harbor.bridge import SandboxBridge
from script.harbor.worker import Capture, dispatch


def encoded(value):
    return base64.b64encode(value).decode("ascii")


class WorkerFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sumika-worker-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "workspace"
        self.control = Path(self.temporary.name) / "control"
        self.root.mkdir()
        self.control.mkdir()

    def request(self, operation, **arguments):
        return dispatch(str(self.root), self.control,
                        {"id": uuid.uuid4().hex, "operation": operation, **arguments})

    def test_binary_read_ranges_and_compare_and_swap(self):
        original = b"hello\x00\xffworld"
        self.assertIn("result", self.request("write", path="nested/data", dataBase64=encoded(original)))
        result = self.request("read", path="nested/data", offset=5, maxBytes=2)["result"]
        self.assertEqual(result["dataBase64"], encoded(b"\x00\xff"))
        self.assertIsInstance(result["version"], str)
        mismatch = self.request("write", path="nested/data", dataBase64=encoded(b"new"),
                                expectedContentsBase64=encoded(b"stale"))
        self.assertEqual(mismatch["error"]["code"], "contentChanged")
        self.assertEqual((self.root / "nested/data").read_bytes(), original)
        self.assertIn("result", self.request("write", path="nested/data", dataBase64=encoded(b"new"),
                                              expectedContentsBase64=encoded(original)))

    def test_paths_and_symlinks_are_denied(self):
        (self.root / "link").symlink_to(self.control, target_is_directory=True)
        for path in ("../control/secret", "a/../secret", str(self.control / "secret")):
            self.assertEqual(self.request("resolve", path=path)["error"]["code"], "pathOutsideWorkspace")
        for operation in ("read", "write", "list", "resolve"):
            response = self.request(operation, path="link/secret", dataBase64=encoded(b"x"))
            self.assertEqual(response["error"]["code"], "permissionDenied")
        self.assertFalse((self.control / "secret").exists())
        self.assertEqual(self.request("resolve", path="https://example.com")["error"]["code"],
                         "unsupportedURLScheme")

    def test_resolve_new_path_and_directory_file_type(self):
        result = self.request("resolve", path="new/nested/file")["result"]
        self.assertEqual(result["relativePath"], "new/nested/file")
        self.assertFalse(result["isRegularFile"])
        self.assertFalse(self.request("resolve", path=".")["result"]["isRegularFile"])
        (self.root / "regular").write_text("x")
        self.assertTrue(self.request("resolve", path="regular")["result"]["isRegularFile"])

    def test_full_read_rejects_truncation_but_paging_is_bounded(self):
        (self.root / "large").write_bytes(b"a" * (1024 * 1024 + 1))
        self.assertEqual(self.request("read", path="large")["error"]["code"], "invalidArgument")
        result = self.request("read", path="large", offset=1024 * 1024, maxBytes=10)["result"]
        self.assertEqual(result["dataBase64"], encoded(b"a"))

    def test_versioned_chunks_reject_atomic_replacement_including_eof(self):
        for suffix in (b"tail", b""):
            with self.subTest(suffix=suffix):
                original = b"a" * 8192 + suffix
                replacement = b"b" * 8192 + suffix
                self.request("write", path="notes", dataBase64=encoded(original))
                initial = self.request("read", path="notes", maxBytes=0)["result"]
                first = self.request("read", path="notes", offset=0, maxBytes=8192,
                                     expectedVersion=initial["version"])["result"]
                self.assertEqual(base64.b64decode(first["dataBase64"]), original[:8192])
                self.assertEqual(first["version"], initial["version"])
                unchanged = self.request("read", path="notes", offset=8192, maxBytes=8192,
                                         expectedVersion=initial["version"])["result"]
                self.assertEqual(base64.b64decode(unchanged["dataBase64"]), suffix)
                self.request("write", path="notes", dataBase64=encoded(replacement))
                changed = self.request("read", path="notes", offset=8192, maxBytes=8192,
                                       expectedVersion=initial["version"])
                self.assertEqual(changed["error"]["code"], "contentChanged")

    def test_version_check_rejects_in_place_change_during_chunk_read(self):
        target = self.root / "notes"
        target.write_bytes(b"original")
        initial = target.stat()
        real_fstat = os.fstat
        checks = 0

        def change_on_validation(descriptor):
            nonlocal checks
            checks += 1
            if checks == 2:
                target.write_bytes(b"modified")
                os.utime(target, ns=(initial.st_atime_ns, initial.st_mtime_ns + 1_000_000_000))
            return real_fstat(descriptor)

        with patch("script.harbor.worker.os.fstat", side_effect=change_on_validation):
            response = self.request("read", path="notes", maxBytes=8192)
        self.assertEqual(response["error"]["code"], "contentChanged")

    def test_invalid_expected_version_is_rejected(self):
        (self.root / "notes").write_bytes(b"content")
        for expected in (1, "", "x" * 257):
            with self.subTest(expected=expected):
                response = self.request("read", path="notes", expectedVersion=expected)
                self.assertEqual(response["error"]["code"], "invalidArgument")

    def test_malformed_output_does_not_expand_capture_budget(self):
        for retention in ("prefix", "headTail", "tail"):
            capture = Capture(32, retention)
            capture.append(b"\xff" * 100)
            data, text, omitted = capture.snapshot()
            self.assertLessEqual(len(text.encode("utf-8")), 32)
            self.assertEqual(len(data) + omitted, 100)
        capture = Capture(4, "prefix")
        capture.append(b"\xef\xbf\xbd\xff")
        self.assertEqual(capture.snapshot()[1], "\ufffd?")


class LocalTestEnvironment:
    """An explicit local fake for trusted transport tests, never an adapter fallback."""
    def __init__(self):
        self.calls = []

    async def exec(self, command, cwd=None, timeout_sec=None, env=None):
        if env is not None:
            raise AssertionError("Host environment must not be forwarded.")
        self.calls.append(command)
        args = shlex.split(command)
        if args[0] == "python3":
            args[0] = sys.executable
        process = await asyncio.create_subprocess_exec(
            *args, cwd=cwd, env={"PATH": "/usr/bin:/bin"},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout_sec)
        return SimpleNamespace(return_code=process.returncode, stdout=stdout.decode(), stderr=stderr.decode())

    async def upload_file(self, source_path, target_path):
        shutil.copyfile(source_path, target_path)


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sumika-bridge-test-")
        self.addCleanup(self.temporary.cleanup)
        self.environment = LocalTestEnvironment()
        self.bridge = SandboxBridge(self.environment, self.temporary.name)
        self.addAsyncCleanup(self.bridge.close)
        await self.bridge.start()

    def run_request(self, script, **arguments):
        return {"id": uuid.uuid4().hex, "operation": "run", "executable": sys.executable,
                "arguments": ["-c", script], "cwd": self.temporary.name,
                "timeoutSeconds": 5, "maxStdoutBytes": 128, "maxStderrBytes": 128,
                "stdoutRetention": "prefix", "stderrRetention": "prefix", **arguments}

    async def test_http_authentication_and_no_token_in_container(self):
        payload = {"id": uuid.uuid4().hex, "operation": "list", "path": "."}

        def http(token):
            request = Request(self.bridge.url + "/rpc", json.dumps(payload).encode(),
                              {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            with urlopen(request, timeout=10) as response:
                return json.load(response)

        with self.assertRaises(HTTPError) as caught:
            await asyncio.to_thread(http, "wrong")
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()
        self.assertEqual((await asyncio.to_thread(http, self.bridge.token))["result"], {"names": []})
        response = await self.bridge.dispatch(self.run_request(
            "import os; print(os.environ.get('SUMIKA_HARBOR_TOKEN', 'absent'))"))
        self.assertEqual(response["result"]["stdout"], "absent\n")
        self.assertTrue(all(self.bridge.token not in command for command in self.environment.calls))

    async def test_bounded_output_and_raw_bytes(self):
        response = await self.bridge.dispatch(self.run_request(
            "import os; os.write(1,b'a'*1000+b'END'); os.write(2,b'error')",
            stdoutRetention="headTail"))
        result = response["result"]
        self.assertEqual(result["exitCode"], 0)
        self.assertTrue(result["stdoutTruncated"])
        self.assertLessEqual(len(result["stdout"].encode()), 128)
        self.assertTrue(base64.b64decode(result["stdoutDataBase64"]).endswith(b"END"))
        self.assertEqual(result["stdoutOmittedBytes"] + len(base64.b64decode(result["stdoutDataBase64"])), 1003)
        self.assertEqual(result["stderr"], "error")

    async def test_timeout_and_cancellation_stop_command(self):
        script = "import time; time.sleep(2); open('late', 'w').write('bad')"
        timed = await self.bridge.dispatch(self.run_request(script, timeoutSeconds=1))
        self.assertTrue(timed["result"]["timedOut"])
        request = self.run_request(script)
        running = asyncio.create_task(self.bridge.dispatch(request))
        await asyncio.sleep(0.2)
        cancellation = await self.bridge.dispatch({"id": uuid.uuid4().hex, "operation": "cancel",
                                                   "targetRequestID": request["id"]})
        self.assertTrue(cancellation["result"]["cancelled"])
        self.assertTrue((await running)["result"]["cancelled"])
        await asyncio.sleep(2)
        self.assertFalse((Path(self.temporary.name) / "late").exists())

    async def test_background_descendant_is_stopped(self):
        child = "import time; time.sleep(1); open('descendant', 'w').write('bad')"
        script = f"import subprocess,sys; subprocess.Popen([sys.executable,'-c',{child!r}])"
        response = await self.bridge.dispatch(self.run_request(script))
        self.assertEqual(response["result"]["exitCode"], 0)
        await asyncio.sleep(1.2)
        self.assertFalse((Path(self.temporary.name) / "descendant").exists())

    async def assert_detached_child_stopped(self, outcome, double_fork=False):
        root = Path(self.temporary.name)
        ready = root / (uuid.uuid4().hex + ".ready")
        release = root / (uuid.uuid4().hex + ".release")
        late = root / (uuid.uuid4().hex + ".late")
        child = f"""import os, signal, time
from pathlib import Path
if {double_fork!r} and os.fork():
    os._exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
ready = Path({str(ready)!r})
ready.with_suffix('.pid').write_text(str(os.getpid()))
ready.with_suffix('.pid').replace(ready)
deadline = time.monotonic() + 15
while not Path({str(release)!r}).exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if Path({str(release)!r}).exists():
    Path({str(late)!r}).write_text('after drain')
"""
        script = f"""import subprocess, sys, time
from pathlib import Path
subprocess.Popen([sys.executable, '-c', {child!r}], start_new_session=True,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 5
while not Path({str(ready)!r}).exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if {outcome != 'completion'!r}:
    time.sleep(10)
"""
        request = self.run_request(script, timeoutSeconds=2 if outcome == "timeout" else 10)
        running = asyncio.create_task(self.bridge.dispatch(request))
        pid = None
        try:
            async with asyncio.timeout(5):
                while not ready.exists():
                    await asyncio.sleep(0.01)
            pid = int(ready.read_text())
            if outcome == "cancellation":
                await self.bridge.dispatch({"id": uuid.uuid4().hex, "operation": "cancel",
                                            "targetRequestID": request["id"]})
            elif outcome == "shutdown":
                await self.bridge.close()
            response = await asyncio.wait_for(asyncio.shield(running), timeout=15)
            self.assertIn("result", response)
            result = response["result"]
            self.assertEqual(result["cancelled"], outcome in ("cancellation", "shutdown"))
            self.assertEqual(result["timedOut"], outcome == "timeout")
            self.assertEqual(result["exitCode"], 0 if outcome == "completion" else None)
            self.assertFalse(late.exists())
            release.touch()
            await asyncio.sleep(0.2)
            self.assertFalse(late.exists(), "Detached descendant wrote after drain")
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            pid = None
        finally:
            if not running.done():
                await self.bridge.dispatch({"id": uuid.uuid4().hex, "operation": "cancel",
                                            "targetRequestID": request["id"]})
                await asyncio.wait_for(running, timeout=15)
            if pid is not None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux descendant supervision")
    async def test_detached_children_stop_on_completion(self):
        for double_fork in (False, True):
            with self.subTest(double_fork=double_fork):
                await self.assert_detached_child_stopped("completion", double_fork)

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux descendant supervision")
    async def test_detached_children_stop_on_cancellation(self):
        for double_fork in (False, True):
            with self.subTest(double_fork=double_fork):
                await self.assert_detached_child_stopped("cancellation", double_fork)

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux descendant supervision")
    async def test_detached_children_stop_on_timeout(self):
        for double_fork in (False, True):
            with self.subTest(double_fork=double_fork):
                await self.assert_detached_child_stopped("timeout", double_fork)

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux descendant supervision")
    async def test_detached_children_stop_on_bridge_shutdown(self):
        await self.assert_detached_child_stopped("shutdown", double_fork=True)

    async def test_cancellation_before_command_starts(self):
        request = self.run_request("open('must-not-run', 'w').write('bad')")
        await self.bridge.dispatch({"id": uuid.uuid4().hex, "operation": "cancel",
                                    "targetRequestID": request["id"]})
        response = await self.bridge.dispatch(request)
        self.assertTrue(response["result"]["cancelled"])
        self.assertFalse((Path(self.temporary.name) / "must-not-run").exists())

    async def test_atomic_compare_and_swap_has_one_winner(self):
        target = Path(self.temporary.name) / "data"
        target.write_bytes(b"before")
        requests = [{"id": uuid.uuid4().hex, "operation": "write", "path": "data",
                     "dataBase64": encoded(value), "expectedContentsBase64": encoded(b"before")}
                    for value in (b"first", b"second")]
        responses = await asyncio.gather(*(self.bridge.dispatch(request) for request in requests))
        self.assertEqual(sum("result" in response for response in responses), 1)
        self.assertEqual([response["error"]["code"] for response in responses if "error" in response],
                         ["contentChanged"])

    async def test_large_edit_uses_file_transfer_not_command_arguments(self):
        data = b"a" * (256 * 1024)
        response = await self.bridge.dispatch({"id": uuid.uuid4().hex, "operation": "write",
                                               "path": "large", "dataBase64": encoded(data)})
        self.assertIn("result", response)
        self.assertEqual((Path(self.temporary.name) / "large").read_bytes(), data)
        self.assertTrue(all(len(command) < 1024 for command in self.environment.calls))


class BridgeDrainTests(unittest.IsolatedAsyncioTestCase):
    async def test_completed_worker_failure_blocks_trial_shutdown(self):
        for failure in (RuntimeError("Worker exited without a response"),
                        {"id": "run", "error": {"code": "transportFailure",
                                                "message": "Cannot drain descendants"}}):
            with self.subTest(failure=failure):
                environment = SimpleNamespace(exec=AsyncMock())
                bridge = SandboxBridge(environment)
                execute = (AsyncMock(side_effect=failure) if isinstance(failure, Exception)
                           else AsyncMock(return_value=failure))
                with patch.object(bridge, "_execute", execute):
                    response = await bridge.dispatch({"id": "run", "operation": "run"})
                    self.assertEqual(response["error"]["code"], "transportFailure")
                    self.assertFalse(bridge.active)
                    with self.assertRaisesRegex(RuntimeError, "Cannot drain task commands"):
                        await bridge.close()
                environment.exec.assert_not_awaited()

    async def test_cancelled_transport_blocks_trial_shutdown(self):
        bridge = SandboxBridge(SimpleNamespace(exec=AsyncMock()))
        with patch.object(bridge, "_execute", AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await bridge.dispatch({"id": "run", "operation": "run"})
            with self.assertRaisesRegex(RuntimeError, "cancelled before the worker drained"):
                await bridge.close()

    async def test_undrained_worker_blocks_trial_shutdown(self):
        environment = SimpleNamespace(exec=AsyncMock())
        bridge = SandboxBridge(environment)
        started = asyncio.Event()

        async def execute(request):
            if request["operation"] == "run":
                started.set()
                await asyncio.Event().wait()
            return {"result": {"cancelled": True}}

        with patch.object(bridge, "_execute", execute):
            running = asyncio.create_task(bridge.dispatch({"id": "run", "operation": "run"}))
            await started.wait()
            with patch("script.harbor.bridge.asyncio.wait",
                       AsyncMock(return_value=(set(), {running}))):
                with self.assertRaisesRegex(RuntimeError, "Cannot drain task commands"):
                    await bridge.close()
            self.assertTrue(running.cancelled())
        environment.exec.assert_not_awaited()


class FixtureTests(unittest.TestCase):
    def run_verifier(self, source, suffix=""):
        fixture = Path(__file__).with_name("tasks") / "merge-ranges"
        with tempfile.TemporaryDirectory(prefix="sumika-fixture-test-") as directory:
            root = Path(directory)
            workspace = root / "app"
            logs = root / "logs/verifier"
            binaries = root / "bin"
            for path in (workspace, logs, binaries):
                path.mkdir(parents=True)
            (workspace / "ranges.py").write_text((fixture / source / "ranges.py").read_text() + suffix)
            (binaries / "python3").symlink_to(sys.executable)
            (logs / "reward.txt").write_text("1\n")
            (logs / "completion.txt").write_text("passed\n")
            # Redirect only container paths; execute the actual verifier's shell logic.
            script = (fixture / "tests/test.sh").read_text()
            for original, replacement in (("/app", workspace), ("/tests", fixture / "tests"),
                                          ("/logs/verifier", logs)):
                script = script.replace(original, shlex.quote(str(replacement)))
            verifier = root / "test.sh"
            verifier.write_text(script)
            result = subprocess.run(["/bin/sh", str(verifier)], cwd=workspace,
                                    env={**os.environ, "PATH": f"{binaries}:{os.defpath}",
                                         "PYTHONDONTWRITEBYTECODE": "1"},
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return (logs / "reward.txt").read_text().strip(), result

    def test_verifier_rejects_starter_and_accepts_reference(self):
        for source, expected in (("environment", "0"), ("solution", "1")):
            with self.subTest(source=source):
                reward, result = self.run_verifier(source)
                self.assertEqual(reward, expected, result.stderr)
                self.assertIn("Ran 5 tests", result.stderr)

    def test_verifier_rejects_successful_exit_during_import(self):
        for suffix in ("\nimport os; os._exit(0)\n", "\nraise SystemExit(0)\n"):
            with self.subTest(suffix=suffix):
                reward, result = self.run_verifier("environment", suffix)
                self.assertEqual(reward, "0", result.stderr)
                self.assertEqual(result.stdout + result.stderr, "")

    def test_verifier_rejects_incomplete_test_runs(self):
        cases = (
            ("\nimport unittest\nunittest.TestLoader.testMethodPrefix = 'missing_'\n", "Ran 0 tests"),
            ("\nimport unittest\nunittest.TestLoader.testNamePatterns = ['*.test_empty']\n", "Ran 1 test"),
            ("\ndef merge_ranges(ranges):\n    import unittest\n    raise unittest.SkipTest('skip')\n",
             "skipped=5"),
        )
        for suffix, output in cases:
            with self.subTest(output=output):
                reward, result = self.run_verifier("solution", suffix)
                self.assertEqual(reward, "0", result.stderr)
                self.assertIn(output, result.stderr)


if __name__ == "__main__":
    unittest.main()
