"""Authenticated host-only RPC; every task operation is delegated to BaseEnvironment."""

import asyncio
import concurrent.futures
import contextlib
import json
import secrets
import shlex
import socketserver
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY_BYTES = 4 * 1024 * 1024


def web_access_enabled(policy):
    return policy.network_mode == "public" or (policy.network_mode == "allowlist" and bool(policy.allowed_hosts))


def exec_diagnostics(result):
    def excerpt(value):
        text = value or "<empty>"
        if len(text) > 4096:
            text = text[:2048] + "\n... [truncated] ...\n" + text[-2048:]
        return text

    # Harbor's Docker executor merges stderr into stdout.
    return (
        f"exit {result.return_code}\nstdout (may include stderr):\n{excerpt(result.stdout)}\n"
        f"stderr:\n{excerpt(result.stderr)}"
    )


class SandboxBridge:
    def __init__(self, environment, workspace_root):
        self.environment = environment
        self.workspace_root = workspace_root
        self.control = "/tmp/sumika-harbor-" + uuid.uuid4().hex
        self.worker = self.control + "/worker.py"
        self.token = secrets.token_urlsafe(32)
        self.active = {}
        self.command_failure = None
        self.closed = False
        self.suspended = False

    async def start(self):
        result = await self.environment.exec(f"mkdir -m 700 {shlex.quote(self.control)}", timeout_sec=10)
        if result.return_code:
            raise RuntimeError(f"Could not create the task RPC directory: {exec_diagnostics(result)}")
        await self.environment.upload_file(Path(__file__).with_name("worker.py"), self.worker)
        check = await self.dispatch({"id": uuid.uuid4().hex, "operation": "list", "path": "."})
        if "error" in check:
            label = (
                "Task RPC startup failed" if check["error"]["code"] == "transportFailure" else "Invalid task workspace"
            )
            raise RuntimeError(f"{label}: {check['error']['message']}")
        self.loop = asyncio.get_running_loop()
        bridge = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                authorization = self.headers.get("Authorization", "").encode("utf-8")
                expected = ("Bearer " + bridge.token).encode("utf-8")
                if self.path != "/rpc" or not secrets.compare_digest(authorization, expected):
                    self.send_error(403)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= MAX_BODY_BYTES:
                        raise ValueError("Invalid request size.")
                    request = json.loads(self.rfile.read(length))
                    future = asyncio.run_coroutine_threadsafe(bridge.dispatch(request), bridge.loop)
                    response = future.result(timeout=640)
                except (ValueError, UnicodeError) as error:
                    self.send_error(400, str(error))
                    return
                except (concurrent.futures.TimeoutError, RuntimeError):
                    self.send_error(503, "Task transport unavailable.")
                    return
                payload = json.dumps(response).encode("utf-8")
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)

        class LoopbackServer(ThreadingHTTPServer):
            def server_bind(self):
                # Reverse DNS is unnecessary for the fixed loopback listener.
                socketserver.TCPServer.server_bind(self)
                self.server_name = "localhost"
                self.server_port = self.server_address[1]

        self.server = LoopbackServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    async def _execute(self, request):
        encoded = json.dumps(request, separators=(",", ":"))
        request_path = self.control + "/request-" + uuid.uuid4().hex + ".json"
        # File transfer avoids the OS argument-size limit for edits and binary input.
        with tempfile.TemporaryDirectory(prefix="sumika-rpc-") as directory:
            payload = Path(directory) / "request.json"
            payload.write_text(encoded, encoding="utf-8")
            payload.chmod(0o644)
            await self.environment.upload_file(payload, request_path)
        command = shlex.join(["python3", self.worker, self.workspace_root, self.control, request_path])
        timeout = request.get("timeoutSeconds", 0)
        timeout = timeout if type(timeout) is int and 1 <= timeout <= 600 else 0
        result = await self.environment.exec(command, cwd=self.workspace_root, timeout_sec=timeout + 20)
        if result.return_code or not result.stdout or len(result.stdout) > MAX_BODY_BYTES * 2:
            raise RuntimeError(f"Task RPC worker failed for {request.get('operation')}: {exec_diagnostics(result)}")
        try:
            response = json.loads(result.stdout)
        except (ValueError, TypeError) as error:
            raise RuntimeError(
                f"Invalid task RPC response for {request.get('operation')}: {exec_diagnostics(result)}"
            ) from error
        if not isinstance(response, dict) or response.get("id") != request.get("id"):
            raise RuntimeError(
                f"Task RPC response ID mismatch for {request.get('operation')}: {exec_diagnostics(result)}"
            )
        return response

    async def dispatch(self, request):
        if not isinstance(request, dict) or not isinstance(request.get("id"), str):
            return {"error": {"code": "invalidArgument", "message": "Invalid RPC request."}}
        identifier = request["id"]
        operation = request.get("operation")
        supervised = operation in ("run", "http", "resolveHost")
        try:
            if self.closed:
                raise RuntimeError("Task transport is closed.")
            if self.suspended:
                return {
                    "id": identifier,
                    "error": {"code": "permissionDenied", "message": "The agent is idle between checkpoints."},
                }
            if operation in ("http", "resolveHost"):
                if not web_access_enabled(self.environment.network_policy):
                    return {
                        "id": identifier,
                        "error": {
                            "code": "permissionDenied",
                            "message": "The task network policy disables web access.",
                        },
                    }
            if supervised:
                if identifier in self.active:
                    raise RuntimeError("Duplicate command request ID.")
                self.active[identifier] = asyncio.current_task()
            try:
                response = await self._execute(request)
                if supervised and response.get("error", {}).get("code") == "transportFailure":
                    self.command_failure = response["error"]["message"]
                return response
            finally:
                if supervised:
                    self.active.pop(identifier, None)
        except asyncio.CancelledError:
            if supervised:
                self.command_failure = "Command transport was cancelled before the worker drained."
            raise
        except Exception as error:
            if supervised:
                self.command_failure = str(error)
            return {"id": identifier, "error": {"code": "transportFailure", "message": str(error)}}

    async def suspend(self):
        self.suspended = True
        await self._drain()

    def resume(self):
        if self.closed:
            raise RuntimeError("Task transport is closed.")
        self.suspended = False

    async def close(self, *, cleanup_environment=True):
        self.closed = True
        if hasattr(self, "server"):
            await asyncio.to_thread(self.server.shutdown)
            self.server.server_close()
            self.thread.join(timeout=2)
        await self._drain()
        if cleanup_environment:
            await self.environment.exec(f"rm -rf {shlex.quote(self.control)}", timeout_sec=10)

    async def _drain(self):
        pending = list(self.active.items())
        await asyncio.gather(
            *(
                self._execute({"id": uuid.uuid4().hex, "operation": "cancel", "targetRequestID": identifier})
                for identifier, _ in pending
            ),
            return_exceptions=True,
        )
        if pending:
            _, unfinished = await asyncio.wait([task for _, task in pending], timeout=8)
            if unfinished:
                self.command_failure = "Timed out waiting for command workers."
            for task in unfinished:
                task.cancel()
            await asyncio.gather(*unfinished, return_exceptions=True)
        if self.command_failure is not None:
            raise RuntimeError(f"Cannot drain task commands: {self.command_failure}")
