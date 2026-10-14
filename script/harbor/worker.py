#!/usr/bin/env python3
"""Runs only inside a Harbor task environment; contains no host transport credentials."""

import base64
import codecs
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urljoin, urlsplit


MAX_BYTES = 1024 * 1024
MAX_ENTRIES = 10_000
codecs.register_error("sumika_bounded_utf8", lambda error: ("?", error.end))


class RPCError(Exception):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def integer(value, name, minimum=0, maximum=MAX_BYTES):
    if type(value) is not int or not minimum <= value <= maximum:
        raise RPCError("invalidArgument", f"Invalid {name}.")
    return value


def decode(value):
    if not isinstance(value, str) or len(value) > (MAX_BYTES + 2) // 3 * 4:
        raise RPCError("invalidArgument", "Invalid byte payload.")
    try:
        result = base64.b64decode(value, validate=True)
    except ValueError as error:
        raise RPCError("invalidArgument", "Invalid base64 payload.") from error
    if len(result) > MAX_BYTES:
        raise RPCError("invalidArgument", "Byte payload exceeds limit.")
    return result


def relative_path(root, path):
    if not isinstance(path, str) or not path or "\0" in path:
        raise RPCError("invalidArgument", "Expected a workspace path.")
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", path):
        raise RPCError("unsupportedURLScheme", "Expected a file path, not a URL.")
    if ".." in path.split("/"):
        raise RPCError("pathOutsideWorkspace", "Parent traversal is not allowed.")
    absolute = os.path.normpath(os.path.join(root, path))
    if os.path.commonpath((root, absolute)) != root:
        raise RPCError("pathOutsideWorkspace", "Path is outside the task workspace.")
    return os.path.relpath(absolute, root)


@contextlib.contextmanager
def directory_fd(root, parts, create=False):
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts:
            if create:
                with contextlib.suppress(FileExistsError):
                    os.mkdir(part, dir_fd=descriptor)
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def file_version(info):
    # shortcut: metadata is not an immutable snapshot; use filesystem snapshots for that guarantee.
    return f"{info.st_dev}:{info.st_ino}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}"


def read_file(parent, name, offset=0, maximum=None, expected_version=None):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=parent)
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise RPCError("invalidArgument", "Expected a regular file.")
        version = file_version(info)
        if expected_version is not None and expected_version != version:
            raise RPCError("contentChanged", "File changed while it was being read.")
        handle.seek(offset)
        data = handle.read(MAX_BYTES + 1 if maximum is None else maximum)
        if len(data) > MAX_BYTES:
            raise RPCError("invalidArgument", "File exceeds the full-read limit.")
        if file_version(os.fstat(handle.fileno())) != version:
            raise RPCError("contentChanged", "File changed while it was being read.")
        return data, version


def files(root, control, request):
    relative = relative_path(root, request["path"])
    parts = [] if relative == "." else relative.split("/")
    operation = request["operation"]
    if operation == "resolve":
        regular = False
        for index, part in enumerate(parts):
            try:
                with directory_fd(root, parts[:index]) as parent:
                    info = os.stat(part, dir_fd=parent, follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    raise RPCError("permissionDenied", "Symlink paths are not supported.")
                regular = index == len(parts) - 1 and stat.S_ISREG(info.st_mode)
            except FileNotFoundError:
                break
        return {"absolutePath": os.path.normpath(os.path.join(root, relative)),
                "relativePath": relative, "isRegularFile": regular}
    if operation == "list":
        with directory_fd(root, parts) as descriptor:
            names = []
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    names.append(entry.name)
                    if len(names) > MAX_ENTRIES:
                        raise RPCError("invalidArgument", "Directory listing exceeds limit.")
            return {"names": sorted(names)}
    with directory_fd(root, parts[:-1], create=operation == "write") as parent:
        name = parts[-1] if parts else "."
        if operation == "read":
            offset = integer(request.get("offset", 0), "offset", maximum=2**53)
            maximum = request.get("maxBytes")
            if maximum is not None:
                maximum = integer(maximum, "maxBytes")
            expected_version = request.get("expectedVersion")
            if expected_version is not None and (
                    not isinstance(expected_version, str) or not 0 < len(expected_version) <= 256):
                raise RPCError("invalidArgument", "Invalid expected file version.")
            data, version = read_file(parent, name, offset, maximum, expected_version)
            return {"dataBase64": base64.b64encode(data).decode("ascii"), "version": version}
        if operation != "write" or not parts:
            raise RPCError("invalidArgument", "Unsupported file operation.")
        data = decode(request["dataBase64"])
        expected = request.get("expectedContentsBase64")
        expected = None if expected is None else decode(expected)
        lock_path = control / (hashlib.sha256(relative.encode()).hexdigest() + ".lock")
        with lock_path.open("a") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                info = None
            if info is not None and not stat.S_ISREG(info.st_mode):
                raise RPCError("permissionDenied", "Only regular files may be written.")
            if expected is not None and (info is None or read_file(parent, name)[0] != expected):
                raise RPCError("contentChanged", "File changed since it was read.")
            temporary = ".sumika-" + os.urandom(12).hex()
            try:
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                     stat.S_IMODE(info.st_mode) if info else 0o644,
                                     dir_fd=parent)
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.rename(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
            finally:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary, dir_fd=parent)
        return {}


class Capture:
    def __init__(self, limit, retention):
        self.limit = integer(limit, "capture limit")
        if retention not in ("prefix", "headTail", "tail"):
            raise RPCError("invalidArgument", "Invalid output retention.")
        self.retention = retention
        self.head = b""
        self.tail = b""
        self.total = 0

    def append(self, data):
        self.total += len(data)
        head_limit = (self.limit if self.retention == "prefix" else
                      self.limit - self.limit // 2 if self.retention == "headTail" else 0)
        added = min(max(0, head_limit - len(self.head)), len(data))
        self.head += data[:added]
        tail_limit = self.limit if self.retention == "tail" else self.limit // 2
        if self.retention != "prefix" and tail_limit:
            self.tail = (self.tail + data[added:])[-tail_limit:]

    def snapshot(self):
        data = self.head + self.tail
        omitted = self.total - len(data)
        if self.retention == "headTail" and omitted:
            marker = f"\n[... {self.total} bytes omitted during capture ...]\n"
            if len(marker) > self.limit // 2:
                marker = "[...]" if self.limit >= 5 else "." * min(self.limit, 3)
            available = max(0, self.limit - len(marker))
            head = self.head[:(available + 1) // 2]
            tail = self.tail[-(available // 2):] if available // 2 else b""
            data = head + tail
            omitted = self.total - len(data)
            if "bytes omitted" in marker:
                marker = f"\n[... {omitted} bytes omitted during capture ...]\n"
            text = (head.decode("utf-8", "sumika_bounded_utf8") + marker
                    + tail.decode("utf-8", "sumika_bounded_utf8"))
        else:
            text = data.decode("utf-8", "sumika_bounded_utf8")
        return data, text, omitted


def request_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value):
        raise RPCError("invalidArgument", "Invalid request ID.")
    return value


def stop_descendants():
    if sys.platform != "linux":
        return
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid:
                continue
            children = Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()
            for child in children:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(child), signal.SIGKILL)
            time.sleep(0.01)
    except OSError as error:
        raise RPCError("transportFailure", f"Cannot drain command descendants: {error}") from error
    raise RPCError("transportFailure", "Timed out draining command descendants.")


def run_command(root, control, request):
    identifier = request_id(request["id"])
    marker = control / (identifier + ".cancel")
    relative = relative_path(root, request.get("cwd", root))
    executable = request["executable"]
    arguments = request["arguments"]
    if (not isinstance(executable, str) or not executable or "\0" in executable
            or not isinstance(arguments, list)
            or any(not isinstance(value, str) or "\0" in value for value in arguments)):
        raise RPCError("invalidArgument", "Invalid command arguments.")
    timeout = integer(request["timeoutSeconds"], "timeoutSeconds", 1, 600)
    stdout = Capture(request["maxStdoutBytes"], request.get("stdoutRetention", "prefix"))
    stderr = Capture(request["maxStderrBytes"], request.get("stderrRetention", "prefix"))
    stdin = request.get("standardInputBase64")
    started = time.monotonic()
    timed_out = cancelled = False
    process = None
    try:
        parts = [] if relative == "." else relative.split("/")
        with directory_fd(root, parts) as directory, tempfile.TemporaryFile() as input_file:
            if stdin is not None:
                input_file.write(decode(stdin))
                input_file.seek(0)
            if marker.exists():
                cancelled = True
            else:
                # Each Linux RPC worker adopts orphaned descendants, including detached sessions.
                if sys.platform == "linux":
                    libc = ctypes.CDLL(None, use_errno=True)
                    libc.prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
                    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
                        raise RPCError("transportFailure", "Cannot supervise command descendants: "
                                       + os.strerror(ctypes.get_errno()))
                process = subprocess.Popen(
                    [sys.executable, "-c", "import os,sys; os.fchdir(int(sys.argv[1])); "
                     "os.close(int(sys.argv[1])); os.execvpe(sys.argv[2],sys.argv[2:],os.environ)",
                     str(directory), executable, *arguments],
                    pass_fds=(directory,), stdin=input_file,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ, stdout)
                    selector.register(process.stderr, selectors.EVENT_READ, stderr)
                    stopping = None
                    while selector.get_map() or process.poll() is None:
                        now = time.monotonic()
                        if stopping is None:
                            cancelled = marker.exists()
                            timed_out = now - started >= timeout
                            if cancelled or timed_out or process.poll() is not None:
                                stopping = now
                                with contextlib.suppress(ProcessLookupError):
                                    os.killpg(process.pid, signal.SIGTERM)
                        elif now - stopping >= 1:
                            with contextlib.suppress(ProcessLookupError):
                                os.killpg(process.pid, signal.SIGKILL)
                        for key, _ in selector.select(0.05):
                            chunk = os.read(key.fileobj.fileno(), 65536)
                            if chunk:
                                key.data.append(chunk)
                            else:
                                selector.unregister(key.fileobj)
                        if stopping is not None and now - stopping > 3:
                            break
    finally:
        try:
            if process is not None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                try:
                    process.wait(timeout=5)
                finally:
                    process.stdout.close()
                    process.stderr.close()
                    stop_descendants()
        finally:
            with contextlib.suppress(FileNotFoundError):
                marker.unlink()
    stdout_data, stdout_text, stdout_omitted = stdout.snapshot()
    _, stderr_text, stderr_omitted = stderr.snapshot()
    return {"exitCode": None if timed_out or cancelled else process.returncode,
            "durationMs": int((time.monotonic() - started) * 1000),
            "stdout": stdout_text, "stderr": stderr_text,
            "stdoutDataBase64": base64.b64encode(stdout_data).decode("ascii"),
            "timedOut": timed_out, "cancelled": cancelled,
            "stdoutTruncated": stdout_omitted > 0, "stderrTruncated": stderr_omitted > 0,
            "stdoutOmittedBytes": stdout_omitted, "stderrOmittedBytes": stderr_omitted}


def public_addresses(host):
    if (not isinstance(host, str) or not host or "\0" in host
            or host.lower().rstrip(".") == "localhost"
            or host.lower().rstrip(".").endswith((".localhost", ".local"))):
        raise RPCError("permissionDenied", "Expected a public web host.")
    addresses = list(dict.fromkeys(
        entry[4][0] for entry in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)))
    if not addresses or any(not ip.is_global or ip.is_multicast
                            for ip in map(ipaddress.ip_address, addresses)):
        raise RPCError("permissionDenied", "Web host resolves to a non-public address.")
    return addresses


def web_operation(request):
    if request["operation"] == "resolveHost":
        return {"addresses": public_addresses(request["host"])}
    url = request["url"]
    redirects = integer(request["maxRedirects"], "maxRedirects", 0, 4)
    timeout = integer(request["timeoutSeconds"], "timeoutSeconds", 1, 60)
    user_agent = request.get("userAgent", "Sumika/1.0")
    if not isinstance(user_agent, str) or any(c in user_agent for c in "\r\n\0"):
        raise RPCError("invalidArgument", "Invalid User-Agent.")
    deadline = time.monotonic() + timeout
    while True:
        parsed = urlsplit(url)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname
                or parsed.username is not None or parsed.password is not None):
            raise RPCError("permissionDenied", "Expected a public http or https URL.")
        addresses = public_addresses(parsed.hostname)
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
        integer(port, "port", 1, 65535)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Web request timed out.")
        connection = http.client.HTTPConnection(parsed.hostname, port, timeout=remaining)
        try:
            # Pin the validated address while keeping the original host for HTTP and TLS.
            for address in addresses:
                try:
                    connection.sock = socket.create_connection((address, port),
                                                               timeout=max(0.001, deadline - time.monotonic()))
                    break
                except OSError:
                    if address == addresses[-1]:
                        raise
            if parsed.scheme == "https":
                connection.sock = ssl.create_default_context().wrap_socket(
                    connection.sock, server_hostname=parsed.hostname)
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
            connection.request("GET", path, headers={"User-Agent": user_agent, "Accept-Encoding": "identity"})
            response = connection.getresponse()
            if 300 <= response.status < 400:
                if redirects == 0:
                    raise RPCError("invalidArgument", "Too many redirects.")
                location = response.getheader("Location")
                if not location:
                    raise RPCError("invalidArgument", "Redirect response has no Location.")
                url = urljoin(url, location)
                redirects -= 1
                continue
            data = response.read(512 * 1024 + 1)
            return {"url": url, "statusCode": response.status, "headers": dict(response.getheaders()),
                    "dataBase64": base64.b64encode(data).decode("ascii")}
        finally:
            connection.close()


def run_web(root, control, request):
    result = run_command(root, control, {
        "id": request["id"], "executable": sys.executable,
        "arguments": [__file__, "--web"], "timeoutSeconds": request.get("timeoutSeconds", 15),
        "maxStdoutBytes": MAX_BYTES, "maxStderrBytes": 4096,
        "standardInputBase64": base64.b64encode(json.dumps(request).encode("utf-8")).decode("ascii")})
    if result["cancelled"] or result["timedOut"] or result["exitCode"] != 0 or result["stdoutTruncated"]:
        raise RPCError("webFailure", result["stderr"] or "Web request cancelled or timed out.")
    return json.loads(result["stdout"])


def dispatch(root, control, request):
    try:
        if not isinstance(request, dict):
            raise RPCError("invalidArgument", "Expected an object.")
        request_id(request.get("id"))
        operation = request.get("operation")
        if operation == "run":
            result = run_command(root, control, request)
        elif operation in ("http", "resolveHost"):
            result = run_web(root, control, request)
        elif operation == "cancel":
            identifier = request_id(request["targetRequestID"])
            (control / (identifier + ".cancel")).touch()
            result = {"cancelled": True}
        elif operation in ("resolve", "read", "write", "list"):
            result = files(root, control, request)
        else:
            raise RPCError("invalidArgument", "Unknown operation.")
        return {"id": request["id"], "result": result}
    except (RPCError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        code = error.code if isinstance(error, RPCError) else "invalidArgument"
        if isinstance(error, subprocess.SubprocessError):
            code = "transportFailure"
        if isinstance(error, OSError):
            if error.errno == errno.ENOENT:
                code = "notFound"
            elif error.errno in (errno.EACCES, errno.EPERM, errno.ELOOP, errno.ENOTDIR):
                code = "permissionDenied"
        return {"id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": code, "message": str(error)}}


if __name__ == "__main__":
    if sys.argv[1:] == ["--web"]:
        try:
            print(json.dumps(web_operation(json.load(sys.stdin))))
        except (RPCError, OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    workspace_root, control_directory, request_path = sys.argv[1:]
    try:
        with open(request_path, encoding="utf-8") as payload:
            request = json.load(payload)
        print(json.dumps(dispatch(workspace_root, Path(control_directory), request)))
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(request_path)
