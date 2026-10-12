"""Transport checks run without Harbor, Docker, or an MLX model."""

import asyncio
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
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
        self.assertEqual(self.request("read", path="nested/data", offset=5, maxBytes=2)["result"],
                         {"dataBase64": encoded(b"\x00\xff")})
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
        self.assertEqual(self.request("read", path="large", offset=1024 * 1024, maxBytes=10)["result"],
                         {"dataBase64": encoded(b"a")})

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


class FixtureTests(unittest.TestCase):
    def test_verifier_rejects_starter_and_accepts_reference(self):
        fixture = Path(__file__).with_name("tasks") / "merge-ranges"
        verifier = fixture / "tests/test_ranges.py"
        for source, expected in (("environment", 1), ("solution", 0)):
            with tempfile.TemporaryDirectory(prefix="sumika-fixture-test-") as directory:
                shutil.copyfile(fixture / source / "ranges.py", Path(directory) / "ranges.py")
                result = subprocess.run([sys.executable, str(verifier)], cwd=directory,
                                        env={"PYTHONPATH": directory}, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr.decode())


if __name__ == "__main__":
    unittest.main()
