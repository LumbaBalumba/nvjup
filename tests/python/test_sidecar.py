from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any
from urllib.parse import quote, quote_plus
from urllib.request import Request, urlopen

import pytest
from aiohttp import web

ROOT = Path(__file__).resolve().parents[2]
SIDECAR = ROOT / "python" / "nvjup_sidecar_main.py"
sys.path.insert(0, str(ROOT / "python"))

from nvjup_sidecar.remote import (  # noqa: E402
    WS_PROTOCOL,
    RemoteContentsClient,
    RemoteKernelClient,
    RemoteKernelManager,
    _deserialize_v1,
    _serialize_v1,
)
from nvjup_sidecar.server import Execution, KernelSession, SidecarServer  # noqa: E402


class _RemoteResponse:
    def __init__(
        self,
        payload: bytes = b"{}",
        status: int = 200,
        protocol: str | None = WS_PROTOCOL,
    ) -> None:
        self.status = status
        self._payload = payload
        self.content_length = len(payload)
        self.content = self
        self.protocol = protocol
        self.closed = False
        self.sent_bytes: list[bytes] = []
        self.sent_text: list[str] = []

    async def __aenter__(self) -> _RemoteResponse:
        return self

    async def __aexit__(self, *_args: object) -> None:
        return None

    async def read(self, _size: int = -1) -> bytes:
        return self._payload

    async def text(self) -> str:
        return self._payload.decode("utf-8", "replace")

    async def json(self) -> Any:
        return json.loads(self._payload)

    async def close(self) -> None:
        self.closed = True

    async def send_bytes(self, value: bytes) -> None:
        self.sent_bytes.append(value)

    async def send_str(self, value: str) -> None:
        self.sent_text.append(value)

    async def iter_chunked(self, _size: int) -> Any:
        if self._payload:
            yield self._payload

    def __aiter__(self) -> Any:
        async def empty() -> Any:
            if False:
                yield None

        return empty()


class _RemoteHTTP:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict[str, Any]]] = []
        self.closed = False

    def request(self, method: str, url: str, **kwargs: Any) -> _RemoteResponse:
        self.calls.append((method, url, kwargs))
        return _RemoteResponse()

    def get(self, url: str, **kwargs: Any) -> _RemoteResponse:
        return self.request("GET", url, **kwargs)

    async def ws_connect(self, url: str, **kwargs: Any) -> _RemoteResponse:
        self.calls.append(("WS", url, kwargs))
        protocols = kwargs.get("protocols") or ()
        return _RemoteResponse(
            protocol=WS_PROTOCOL if WS_PROTOCOL in protocols else None
        )

    async def close(self) -> None:
        self.closed = True


def test_colab_transport_applies_proxy_auth_without_jupyter_authorization() -> None:
    async def exercise() -> None:
        http = _RemoteHTTP()
        manager = object.__new__(RemoteKernelManager)
        manager.base_url = "https://runtime.example"
        manager.token = "proxy-secret"
        manager.provider = "colab"
        manager.verify_ssl = True
        manager.origin = None
        manager.http = http
        manager.kernel_id = "kernel/id"
        await manager._request("GET", "/api/kernels")
        _, _, rest = http.calls[-1]
        assert rest["params"] == {
            "authuser": "0",
            "colab-runtime-proxy-token": "proxy-secret",
        }
        assert rest["headers"] == {
            "X-Colab-Runtime-Proxy-Token": "proxy-secret",
            "X-Colab-Client-Agent": "nvjup",
        }
        assert "Authorization" not in rest["headers"]

        contents = object.__new__(RemoteContentsClient)
        contents.base_url = "https://runtime.example"
        contents.token = "proxy-secret"
        contents.provider = "colab"
        contents.verify_ssl = True
        contents.origin = None
        contents.http = http
        await contents._json_request(
            "GET", "/api/contents", "folder", params={"content": 1}
        )
        _, _, content_call = http.calls[-1]
        assert content_call["params"] == {
            "content": 1,
            "authuser": "0",
            "colab-runtime-proxy-token": "proxy-secret",
        }
        assert content_call["headers"]["X-Colab-Client-Agent"] == "nvjup"
        assert "Authorization" not in content_call["headers"]

        contents.max_file_bytes = 1024
        assert await contents.download("folder/data.bin") == b"{}"
        _, _, file_call = http.calls[-1]
        assert file_call["params"] == {
            "authuser": "0",
            "colab-runtime-proxy-token": "proxy-secret",
        }
        assert file_call["headers"]["X-Colab-Runtime-Proxy-Token"] == "proxy-secret"

        client = RemoteKernelClient(manager)
        await client.connect()
        method, url, ws = http.calls[-1]
        assert method == "WS"
        assert "session_id=" + client.session_id in url
        assert "authuser=0" in url
        assert "colab-runtime-proxy-token=proxy-secret" in url
        assert ws["headers"]["X-Colab-Runtime-Proxy-Token"] == "proxy-secret"
        assert "Authorization" not in ws["headers"]
        assert ws["protocols"] == ()
        assert client.v1_protocol is False

        websocket = client.ws
        assert websocket is not None
        await client._send("shell", "kernel_info_request", {})
        assert websocket.sent_bytes == []
        message = json.loads(websocket.sent_text[-1])
        assert message["channel"] == "shell"
        assert message["header"]["msg_type"] == "kernel_info_request"
        await client.close()

    asyncio.run(exercise())


def test_colab_transport_errors_redact_proxy_tokens() -> None:
    token = "proxy/+ secret?&=%"

    def mixed_escape_case(value: str) -> str:
        upper = False

        def replace(match: re.Match[str]) -> str:
            nonlocal upper
            upper = not upper
            escape = match.group(0)
            return escape.upper() if upper else escape.lower()

        return re.sub(r"%[0-9A-Fa-f]{2}", replace, value)

    encoded = mixed_escape_case(quote(token, safe=""))
    form_encoded = mixed_escape_case(quote_plus(token, safe=""))

    class FailingHTTP(_RemoteHTTP):
        def request(self, method: str, url: str, **kwargs: Any) -> _RemoteResponse:
            self.calls.append((method, url, kwargs))
            detail = (
                f"arbitrary backend echo {encoded}; form echo {form_encoded} rejected"
            ).encode()
            return _RemoteResponse(detail, status=403)

    def assert_redacted(error: pytest.ExceptionInfo[RuntimeError]) -> None:
        message = str(error.value)
        assert token not in message
        assert quote(token, safe="") not in message
        assert quote_plus(token, safe="") not in message
        assert encoded not in message
        assert form_encoded not in message
        assert "<redacted>" in message

    async def exercise() -> None:
        http = FailingHTTP()
        manager = object.__new__(RemoteKernelManager)
        manager.base_url = "https://runtime.example"
        manager.token = token
        manager.provider = "colab"
        manager.verify_ssl = True
        manager.http = http
        with pytest.raises(RuntimeError) as caught:
            await manager._request("GET", "/api")
        assert_redacted(caught)

        contents = object.__new__(RemoteContentsClient)
        contents.base_url = "https://runtime.example"
        contents.token = token
        contents.provider = "colab"
        contents.verify_ssl = True
        contents.origin = None
        contents.http = http
        with pytest.raises(RuntimeError) as caught:
            await contents._json_request("GET", "/api/contents", "file")
        assert_redacted(caught)

    asyncio.run(exercise())


def test_colab_websocket_errors_redact_encoded_reserved_character_tokens() -> None:
    token = "proxy/+ secret?&=%"

    class FailingWebSocketHTTP(_RemoteHTTP):
        async def ws_connect(self, url: str, **kwargs: Any) -> _RemoteResponse:
            self.calls.append(("WS", url, kwargs))
            raise RuntimeError(f"WebSocket handshake failed for {url}")

    async def exercise() -> None:
        manager = object.__new__(RemoteKernelManager)
        manager.base_url = "https://runtime.example"
        manager.token = token
        manager.provider = "colab"
        manager.verify_ssl = True
        manager.origin = None
        manager.http = FailingWebSocketHTTP()
        manager.kernel_id = "kernel/id"
        client = RemoteKernelClient(manager)
        with pytest.raises(RuntimeError) as caught:
            await client.connect()
        message = str(caught.value)
        assert "colab-runtime-proxy-token=<redacted>" in message
        assert token not in message
        assert quote(token, safe="") not in message
        assert quote_plus(token, safe="") not in message

    asyncio.run(exercise())


def test_colab_websocket_redirect_does_not_forward_proxy_credentials() -> None:
    async def exercise() -> None:
        target_hits: list[dict[str, Any]] = []

        async def target(request: web.Request) -> web.StreamResponse:
            target_hits.append(
                {"headers": dict(request.headers), "query": dict(request.query)}
            )
            websocket = web.WebSocketResponse(protocols=(WS_PROTOCOL,))
            await websocket.prepare(request)
            await websocket.close()
            return websocket

        target_app = web.Application()
        target_app.router.add_get("/{path:.*}", target)
        target_runner = web.AppRunner(target_app)
        await target_runner.setup()
        target_site = web.TCPSite(target_runner, "127.0.0.1", 0)
        await target_site.start()
        target_socket = target_site._server.sockets[0]
        target_url = f"http://127.0.0.1:{target_socket.getsockname()[1]}/sink"

        async def redirect(_request: web.Request) -> web.StreamResponse:
            raise web.HTTPFound(target_url)

        source_app = web.Application()
        source_app.router.add_get("/{path:.*}", redirect)
        source_runner = web.AppRunner(source_app)
        await source_runner.setup()
        source_site = web.TCPSite(source_runner, "127.0.0.1", 0)
        await source_site.start()
        source_socket = source_site._server.sockets[0]
        source_url = f"http://127.0.0.1:{source_socket.getsockname()[1]}"

        try:
            colab_manager = RemoteKernelManager(
                source_url, "proxy-secret", True, None, 5, 0, "colab"
            )
            colab_manager.kernel_id = "kernel"
            with pytest.raises(RuntimeError, match="redirect refused"):
                await RemoteKernelClient(colab_manager).connect()
            await colab_manager.http.close()
            assert target_hits == []

            jupyter_manager = RemoteKernelManager(
                source_url, "jupyter-secret", True, None, 5, 0, "jupyter"
            )
            jupyter_manager.kernel_id = "kernel"
            jupyter_client = RemoteKernelClient(jupyter_manager)
            await jupyter_client.connect()
            await jupyter_client.close()
            await jupyter_manager.http.close()
            assert len(target_hits) == 1
            assert "X-Colab-Runtime-Proxy-Token" not in target_hits[0]["headers"]
            assert "colab-runtime-proxy-token" not in target_hits[0]["query"]
        finally:
            await source_runner.cleanup()
            await target_runner.cleanup()

    asyncio.run(exercise())


def test_ordinary_jupyter_transport_auth_is_unchanged() -> None:
    async def exercise() -> None:
        http = _RemoteHTTP()
        manager = object.__new__(RemoteKernelManager)
        manager.base_url = "https://jupyter.example"
        manager.token = "jupyter-secret"
        manager.provider = "jupyter"
        manager.verify_ssl = True
        manager.http = http
        assert manager.headers() == {"Authorization": "token jupyter-secret"}
        await manager._request("GET", "/api")
        _, _, call = http.calls[-1]
        assert call["headers"] == {"Authorization": "token jupyter-secret"}
        assert call["params"] is None

        contents = object.__new__(RemoteContentsClient)
        contents.token = "jupyter-secret"
        contents.provider = "jupyter"
        contents.origin = None
        assert contents.headers() == {"Authorization": "token jupyter-secret"}
        assert contents.params({"content": 1}) == {"content": 1}

    asyncio.run(exercise())


def test_colab_configures_plotly_to_emit_structured_mime() -> None:
    async def exercise() -> None:
        client = object.__new__(RemoteKernelClient)
        calls: list[tuple[str, dict[str, Any]]] = []

        def execute(code: str, **kwargs: Any) -> str:
            calls.append((code, kwargs))
            return "configure-request"

        async def get_shell_msg(_timeout: float | None = None) -> dict[str, Any]:
            return {
                "parent_header": {"msg_id": "configure-request"},
                "content": {"status": "ok"},
            }

        client.execute = execute  # type: ignore[method-assign]
        client.get_shell_msg = get_shell_msg  # type: ignore[method-assign]
        await client.configure_colab_defaults()
        assert len(calls) == 1
        code, kwargs = calls[0]
        assert "PLOTLY_RENDERER" in code
        assert "plotly_mimetype" in code
        assert kwargs == {
            "silent": True,
            "store_history": False,
            "allow_stdin": False,
        }

    asyncio.run(exercise())


def test_remote_entry_names_are_basenames_consistent_with_paths() -> None:
    valid = RemoteContentsClient._entry(
        {"name": "data.bin", "path": "tree/data.bin"},
        expected_path="tree/data.bin",
    )
    assert valid["name"] == "data.bin"
    for model in (
        {"name": "..", "path": "tree/.."},
        {"name": "../escape", "path": "tree/../escape"},
        {"name": "escape/file", "path": "tree/escape/file"},
        {"name": "file", "path": "other/file"},
    ):
        with pytest.raises(ValueError):
            RemoteContentsClient._entry(model, expected_path="tree/file")

    async def malicious_listing() -> None:
        client = object.__new__(RemoteContentsClient)
        client.max_entries = 10

        async def response(*_args: object, **_kwargs: object) -> dict[str, Any]:
            return {
                "content": [{"name": "escape", "path": "other/escape", "type": "file"}]
            }

        client._json_request = response  # type: ignore[method-assign]
        with pytest.raises(ValueError, match="escapes"):
            await client.list("tree")

    asyncio.run(malicious_listing())


async def _direct_download_preserves_dangling_symlink_and_create_race(
    tmp_path: Path,
) -> None:
    server = SidecarServer()

    class Client:
        max_file_bytes = 1024
        create_race: Path | None = None

        async def download(self, _path: str, max_bytes: int | None = None) -> bytes:
            assert max_bytes == 1024
            if self.create_race:
                self.create_race.write_bytes(b"competitor")
            return b"download"

    client = Client()

    async def contents(_request: dict[str, Any]) -> Client:
        return client

    server._contents_client = contents  # type: ignore[method-assign]
    missing = tmp_path / "missing"
    dangling = tmp_path / "dangling"
    dangling.symlink_to(missing)
    request = {
        "payload": {"path": "remote", "local_path": str(dangling)},
    }
    with pytest.raises(ValueError):
        await server._handle_remote_files_download_to(request)
    assert dangling.is_symlink()

    target = tmp_path / "raced"
    client.create_race = target
    request["payload"]["local_path"] = str(target)
    with pytest.raises(FileExistsError):
        await server._handle_remote_files_download_to(request)
    assert target.read_bytes() == b"competitor"


def test_direct_download_preserves_dangling_symlink_and_create_race(
    tmp_path: Path,
) -> None:
    asyncio.run(_direct_download_preserves_dangling_symlink_and_create_race(tmp_path))


async def _direct_transfers_enforce_actual_byte_limit(tmp_path: Path) -> None:
    server = SidecarServer()

    class Client:
        max_file_bytes = 1024

        async def download(self, _path: str, max_bytes: int | None = None) -> bytes:
            if max_bytes is not None and 5 > max_bytes:
                raise ValueError("file exceeds limit")
            return b"12345"

        async def upload(self, _path: str, content: bytes) -> dict[str, Any]:
            return {"name": "target", "path": "target", "received": content}

    client = Client()

    async def contents(_request: dict[str, Any]) -> Client:
        return client

    server._contents_client = contents  # type: ignore[method-assign]
    target = tmp_path / "target"
    with pytest.raises(ValueError):
        await server._handle_remote_files_download_to(
            {"payload": {"path": "remote", "local_path": str(target), "max_bytes": 4}}
        )
    assert not target.exists()

    source = tmp_path / "source"
    source.write_bytes(b"12345")
    with pytest.raises(ValueError):
        await server._handle_remote_files_upload_from(
            {"payload": {"path": "remote", "local_path": str(source), "max_bytes": 4}}
        )


def test_direct_transfers_enforce_actual_byte_limit(tmp_path: Path) -> None:
    asyncio.run(_direct_transfers_enforce_actual_byte_limit(tmp_path))


def test_sidecar_stdin_reader_bounds_oversized_lines(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import nvjup_sidecar.server as server_module

    class Input:
        buffer = io.BytesIO(b"x" * 20 + b'\n{"ok": true}\n')

    monkeypatch.setattr(server_module, "MAX_MESSAGE_BYTES", 16)
    monkeypatch.setattr(server_module.sys, "stdin", Input())
    _, oversized = SidecarServer._read_stdin_line()
    assert oversized
    line, oversized = SidecarServer._read_stdin_line()
    assert not oversized
    assert line == b'{"ok": true}\n'


class SidecarProcess:
    def __init__(self) -> None:
        self.process = subprocess.Popen(
            [sys.executable, str(SIDECAR)],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdin and self.process.stdout and self.process.stderr
        self.messages: queue.Queue[dict[str, Any]] = queue.Queue()
        self.stderr: list[str] = []
        self.sequence = 0
        self.request_sequence = 0
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.error_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.reader.start()
        self.error_reader.start()

    def _read_stdout(self) -> None:
        assert self.process.stdout
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def _read_stderr(self) -> None:
        assert self.process.stderr
        self.stderr.extend(self.process.stderr)

    def send(
        self,
        message_type: str,
        payload: dict[str, Any] | None = None,
        *,
        notebook_id: str | None = None,
        cell_id: str | None = None,
        revision: int | None = None,
    ) -> str:
        assert self.process.stdin
        self.sequence += 1
        self.request_sequence += 1
        request_id = f"test-{self.request_sequence}"
        message: dict[str, Any] = {
            "protocol": "nvjup/1",
            "kind": "request",
            "type": message_type,
            "id": request_id,
            "seq": self.sequence,
            "payload": payload or {},
        }
        if notebook_id:
            message["notebook_id"] = notebook_id
        if cell_id:
            message["cell_id"] = cell_id
        if revision is not None:
            message["revision"] = revision
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        return request_id

    def wait_for(
        self, predicate: Callable[[dict[str, Any]], bool], timeout: float = 30
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        deferred: list[dict[str, Any]] = []
        try:
            while time.monotonic() < deadline:
                try:
                    message = self.messages.get(
                        timeout=min(0.1, deadline - time.monotonic())
                    )
                except queue.Empty:
                    continue
                if predicate(message):
                    return message
                deferred.append(message)
        finally:
            for message in deferred:
                self.messages.put(message)
        raise AssertionError(
            f"timed out waiting for sidecar message; stderr={''.join(self.stderr)!r}"
        )

    def response(self, request_id: str, timeout: float = 30) -> dict[str, Any]:
        message = self.wait_for(
            lambda item: item.get("kind") == "response"
            and item.get("id") == request_id,
            timeout,
        )
        assert "error" not in message, message.get("error")
        return message

    def event(
        self,
        event_type: str,
        execution_id: str | None = None,
        *,
        state: str | None = None,
        timeout: float = 30,
    ) -> dict[str, Any]:
        def matches(message: dict[str, Any]) -> bool:
            payload = message.get("payload", {})
            return (
                message.get("kind") == "event"
                and message.get("type") == event_type
                and (
                    execution_id is None or payload.get("execution_id") == execution_id
                )
                and (state is None or payload.get("state") == state)
            )

        return self.wait_for(matches, timeout)

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                request_id = self.send("sidecar.shutdown")
                self.response(request_id, 10)
            except (AssertionError, BrokenPipeError):
                self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)


@pytest.fixture
def sidecar() -> SidecarProcess:
    process = SidecarProcess()
    try:
        yield process
    finally:
        process.close()


def enqueue(
    sidecar: SidecarProcess,
    notebook_id: str,
    execution_id: str,
    code: str,
    *,
    cell_id: str = "cell-1",
    revision: int = 1,
) -> None:
    request_id = sidecar.send(
        "execution.enqueue",
        {"execution_id": execution_id, "code": code, "allow_stdin": True},
        notebook_id=notebook_id,
        cell_id=cell_id,
        revision=revision,
    )
    response = sidecar.response(request_id)
    assert response["payload"] == {"execution_id": execution_id, "state": "queued"}


def test_widget_comm_messages_are_bounded_and_routed() -> None:
    events: list[dict[str, Any]] = []

    class Server:
        def event(self, event_type: str, **message: Any) -> None:
            events.append({"type": event_type, **message})

    session = object.__new__(KernelSession)
    session.server = Server()
    session.notebook_id = "notebook-widget"
    session.widget_comm_ids = set()
    execution = Execution("execution-widget", "cell-widget", 3, "pass")
    model_id = "model-progress"

    session._route_output(
        execution,
        {
            "msg_type": "comm_open",
            "content": {
                "comm_id": model_id,
                "target_name": "jupyter.widget",
                "data": {
                    "state": {
                        "_model_name": "FloatProgressModel",
                        "_model_module": "@jupyter-widgets/controls",
                        "_size": [640, 480],
                        "value": 0.0,
                        "min": 0.0,
                        "max": 4.0,
                        "_options_labels": ["one", "two"],
                        "ignored": "not forwarded",
                    }
                },
            },
        },
    )
    session._route_output(
        execution,
        {
            "msg_type": "comm_msg",
            "content": {
                "comm_id": model_id,
                "data": {"method": "update", "state": {"value": 2.0}},
            },
        },
    )

    assert [event["type"] for event in events] == [
        "execution.widget",
        "execution.widget",
    ]
    assert events[0]["payload"]["state"]["_model_name"] == "FloatProgressModel"
    assert events[0]["payload"]["state"]["_model_module"] == "@jupyter-widgets/controls"
    assert events[0]["payload"]["state"]["_size"] == [640.0, 480.0]
    assert events[0]["payload"]["state"]["_options_labels"] == ["one", "two"]
    assert "ignored" not in events[0]["payload"]["state"]
    assert events[1]["payload"]["state"] == {"value": 2.0}
    assert events[1]["cell_id"] == "cell-widget"
    assert events[1]["revision"] == 3


def test_remote_kernel_v1_framing_and_jupyter_server_transport(
    sidecar: SidecarProcess, tmp_path: Path
) -> None:
    message = {
        "header": {"msg_type": "execute_request"},
        "parent_header": {},
        "metadata": {},
        "content": {"code": "40 + 2"},
        "buffers": [b"frame"],
    }
    decoded = _deserialize_v1(_serialize_v1(message, "shell"))
    assert decoded["channel"] == "shell"
    assert decoded["content"] == {"code": "40 + 2"}
    assert decoded["buffers"] == [b"frame"]

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    token = "nvjup-remote-test-token"
    env = {
        **os.environ,
        "JUPYTER_CONFIG_DIR": str(tmp_path / "config"),
        "JUPYTER_DATA_DIR": str(tmp_path / "data"),
        "JUPYTER_RUNTIME_DIR": str(tmp_path / "runtime"),
    }
    server = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "jupyter_server",
            "--no-browser",
            "--ServerApp.ip=127.0.0.1",
            f"--ServerApp.port={port}",
            "--ServerApp.port_retries=0",
            "--ServerApp.allow_root=True",
            f"--IdentityProvider.token={token}",
        ],
        cwd=tmp_path,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    base_url = f"http://127.0.0.1:{port}"
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if server.poll() is not None:
                stderr = server.stderr.read() if server.stderr else ""
                raise AssertionError(f"Jupyter Server exited early: {stderr}")
            try:
                request = Request(
                    base_url + "/api/status",
                    headers={"Authorization": f"token {token}"},
                )
                with urlopen(request, timeout=0.5) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.1)
        else:
            raise AssertionError("timed out starting Jupyter Server")

        notebook_id = "notebook-remote"
        remote = {
            "url": base_url,
            "token": token,
            "verify_ssl": True,
            "max_file_bytes": 1024 * 1024,
            "max_entries": 100,
        }
        probe = sidecar.response(
            sidecar.send(
                "remote.server.probe",
                {"remote": remote},
                notebook_id=notebook_id,
            )
        )
        assert probe["payload"]["url"] == base_url
        assert any(item["name"] == "python3" for item in probe["payload"]["kernels"])
        assert token not in json.dumps(probe)
        made = sidecar.response(
            sidecar.send(
                "remote.files.mkdir",
                {"remote": remote, "path": "transfer"},
                notebook_id=notebook_id,
            )
        )
        assert made["payload"]["type"] == "directory"
        binary = b"nvjup\x00remote\xfffile"
        uploaded = sidecar.response(
            sidecar.send(
                "remote.files.upload",
                {
                    "remote": remote,
                    "path": "transfer/data.bin",
                    "content": base64.b64encode(binary).decode("ascii"),
                },
                notebook_id=notebook_id,
            )
        )
        assert uploaded["payload"]["path"] == "transfer/data.bin"
        listing = sidecar.response(
            sidecar.send(
                "remote.files.list",
                {"remote": remote, "path": "transfer"},
                notebook_id=notebook_id,
            )
        )
        assert [entry["name"] for entry in listing["payload"]["entries"]] == [
            "data.bin"
        ]
        downloaded = sidecar.response(
            sidecar.send(
                "remote.files.download",
                {"remote": remote, "path": "transfer/data.bin"},
                notebook_id=notebook_id,
            )
        )
        assert base64.b64decode(downloaded["payload"]["content"]) == binary
        direct_target = tmp_path / "direct-download.bin"
        direct = sidecar.response(
            sidecar.send(
                "remote.files.download_to",
                {
                    "remote": remote,
                    "path": "transfer/data.bin",
                    "local_path": str(direct_target),
                },
                notebook_id=notebook_id,
            )
        )
        assert direct["payload"]["size"] == len(binary)
        assert direct_target.read_bytes() == binary
        upload_source = tmp_path / "direct-upload.bin"
        upload_source.write_bytes(b"direct\x00upload")
        sidecar.response(
            sidecar.send(
                "remote.files.upload_from",
                {
                    "remote": remote,
                    "path": "transfer/direct.bin",
                    "local_path": str(upload_source),
                },
                notebook_id=notebook_id,
            )
        )
        sidecar.response(
            sidecar.send(
                "remote.files.copy",
                {
                    "remote": remote,
                    "path": "transfer/direct.bin",
                    "new_path": "transfer/direct-copy.bin",
                },
                notebook_id=notebook_id,
            )
        )
        copied = sidecar.response(
            sidecar.send(
                "remote.files.download",
                {"remote": remote, "path": "transfer/direct-copy.bin"},
                notebook_id=notebook_id,
            )
        )
        assert base64.b64decode(copied["payload"]["content"]) == b"direct\x00upload"
        notebook_bytes = b'{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}\n'
        sidecar.response(
            sidecar.send(
                "remote.files.upload",
                {
                    "remote": remote,
                    "path": "transfer/notes \u03b4.ipynb",
                    "content": base64.b64encode(notebook_bytes).decode("ascii"),
                },
                notebook_id=notebook_id,
            )
        )
        notebook_download = sidecar.response(
            sidecar.send(
                "remote.files.download",
                {"remote": remote, "path": "transfer/notes \u03b4.ipynb"},
                notebook_id=notebook_id,
            )
        )
        assert (
            base64.b64decode(notebook_download["payload"]["content"]) == notebook_bytes
        )
        renamed = sidecar.response(
            sidecar.send(
                "remote.files.rename",
                {
                    "remote": remote,
                    "path": "transfer/data.bin",
                    "new_path": "transfer/renamed.bin",
                },
                notebook_id=notebook_id,
            )
        )
        assert renamed["payload"]["path"] == "transfer/renamed.bin"
        sidecar.response(
            sidecar.send(
                "remote.files.touch",
                {"remote": remote, "path": "transfer/empty.txt"},
                notebook_id=notebook_id,
            )
        )
        sidecar.response(
            sidecar.send(
                "remote.files.delete",
                {"remote": remote, "path": "transfer/renamed.bin"},
                notebook_id=notebook_id,
            )
        )
        sidecar.response(
            sidecar.send(
                "remote.files.delete",
                {"remote": remote, "path": "transfer/empty.txt"},
                notebook_id=notebook_id,
            )
        )
        sidecar.response(
            sidecar.send(
                "remote.files.delete",
                {"remote": remote, "path": "transfer/notes \u03b4.ipynb"},
                notebook_id=notebook_id,
            )
        )
        for path in ("transfer/direct.bin", "transfer/direct-copy.bin"):
            sidecar.response(
                sidecar.send(
                    "remote.files.delete",
                    {"remote": remote, "path": path},
                    notebook_id=notebook_id,
                )
            )
        sidecar.response(
            sidecar.send(
                "remote.files.delete",
                {"remote": remote, "path": "transfer"},
                notebook_id=notebook_id,
            )
        )
        traversal_id = sidecar.send(
            "remote.files.list",
            {"remote": remote, "path": "../escape"},
            notebook_id=notebook_id,
        )
        traversal = sidecar.wait_for(
            lambda item: item.get("kind") == "response"
            and item.get("id") == traversal_id
        )
        assert traversal["error"]["code"] == "remote_files_list_failed"
        assert token not in json.dumps(traversal)
        embedded_id = sidecar.send(
            "remote.server.probe",
            {"remote": {**remote, "url": f"http://user:password@127.0.0.1:{port}"}},
            notebook_id=notebook_id,
        )
        embedded = sidecar.wait_for(
            lambda item: item.get("kind") == "response"
            and item.get("id") == embedded_id
        )
        assert embedded["error"]["code"] == "remote_server_probe_failed"
        assert "password" not in json.dumps(embedded)

        started = sidecar.response(
            sidecar.send(
                "kernel.start",
                {
                    "kernel_name": "python3",
                    "remote": remote,
                    "timeout": 30,
                },
                notebook_id=notebook_id,
            ),
            timeout=40,
        )
        assert started["payload"]["transport"] == "remote"
        assert started["payload"]["python_source"] == "remote"
        assert token not in json.dumps(started)

        execution_id = "execution-remote"
        enqueue(
            sidecar,
            notebook_id,
            execution_id,
            "remote_value = 42\nprint('remote ready', flush=True)",
        )
        assert (
            "remote ready"
            in sidecar.event("execution.stream", execution_id, timeout=30)["payload"][
                "text"
            ]
        )
        sidecar.event("execution.state", execution_id, state="completed", timeout=30)
        stdin_id = "execution-remote-stdin"
        enqueue(sidecar, notebook_id, stdin_id, "name = input('Remote: '); print(name)")
        assert (
            sidecar.event("execution.stdin_request", stdin_id, timeout=30)["payload"][
                "prompt"
            ]
            == "Remote: "
        )
        stdin_reply = sidecar.response(
            sidecar.send(
                "execution.stdin_reply",
                {"execution_id": stdin_id, "value": "nvjup"},
                notebook_id=notebook_id,
            )
        )
        assert stdin_reply["payload"]["accepted"] is True
        assert (
            "nvjup"
            in sidecar.event("execution.stream", stdin_id, timeout=30)["payload"][
                "text"
            ]
        )
        sidecar.event("execution.state", stdin_id, state="completed", timeout=30)
        completion = sidecar.response(
            sidecar.send(
                "completion.request",
                {"code": "remote_v", "cursor_pos": 8},
                notebook_id=notebook_id,
            )
        )
        assert "remote_value" in completion["payload"]["matches"]
        restarted = sidecar.response(
            sidecar.send("kernel.restart", notebook_id=notebook_id), timeout=40
        )
        assert restarted["payload"]["transport"] == "remote"
        assert restarted["payload"]["generation"] == 2
        restarted_id = "execution-remote-restarted"
        enqueue(sidecar, notebook_id, restarted_id, "print('remote restarted')")
        assert (
            "remote restarted"
            in sidecar.event("execution.stream", restarted_id, timeout=30)["payload"][
                "text"
            ]
        )
        sidecar.event("execution.state", restarted_id, state="completed", timeout=30)
        shutdown = sidecar.response(
            sidecar.send("kernel.shutdown", notebook_id=notebook_id), timeout=30
        )
        assert shutdown["payload"]["state"] == "stopped"
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)


def test_sidecar_kernel_lifecycle_and_execution_routing(
    sidecar: SidecarProcess,
) -> None:
    notebook_id = "notebook-integration"

    hello = sidecar.response(sidecar.send("sidecar.hello"))
    assert hello["payload"]["protocols"] == ["nvjup/1"]
    assert hello["payload"]["capabilities"]["transports"] == [
        "local",
        "jupyter_server",
    ]
    assert "completion.request" in hello["payload"]["capabilities"]["requests"]
    assert "inspect.request" in hello["payload"]["capabilities"]["requests"]
    assert "variables.list" in hello["payload"]["capabilities"]["requests"]
    assert "execution.widget" in hello["payload"]["capabilities"]["events"]
    kernels = sidecar.response(sidecar.send("kernel.list"))
    assert any(item["name"] == "python3" for item in kernels["payload"]["kernels"])

    started = sidecar.response(
        sidecar.send(
            "kernel.start",
            {
                "kernel_name": "python3",
                "python_path": sys.executable,
                "python_source": "test",
                "cwd": str(ROOT),
                "timeout": 30,
            },
            notebook_id=notebook_id,
        ),
        timeout=40,
    )
    assert started["payload"]["state"] == "idle"
    assert started["payload"]["python_path"] == str(Path(sys.executable).absolute())
    assert started["payload"]["python_source"] == "test"

    interpreter_id = "execution-interpreter"
    enqueue(sidecar, notebook_id, interpreter_id, "import sys; sys.executable")
    interpreter = sidecar.event("execution.display", interpreter_id)
    reported_python = interpreter["payload"]["data"]["text/plain"].strip("'\"")
    assert Path(reported_python).resolve() == Path(sys.executable).resolve()
    sidecar.event("execution.state", interpreter_id, state="completed")

    rich_id = "execution-rich"
    enqueue(
        sidecar,
        notebook_id,
        rich_id,
        """from IPython.display import display, update_display, clear_output
print('before', flush=True)
display({'text/plain': 'first'}, raw=True, display_id='slot')
update_display({'text/plain': 'updated'}, raw=True, display_id='slot')
clear_output(wait=True)
print('after', flush=True)
21 * 2
""",
    )
    assert sidecar.event("execution.stream", rich_id)["payload"]["text"] == "before\n"
    assert (
        sidecar.event("execution.display", rich_id)["payload"]["data"]["text/plain"]
        == "first"
    )
    assert (
        sidecar.event("execution.display_update", rich_id)["payload"]["data"][
            "text/plain"
        ]
        == "updated"
    )
    assert sidecar.event("execution.clear_output", rich_id)["payload"]["wait"] is True
    assert sidecar.event("execution.stream", rich_id)["payload"]["text"] == "after\n"
    assert (
        sidecar.event("execution.display", rich_id)["payload"]["data"]["text/plain"]
        == "42"
    )
    assert sidecar.event("execution.state", rich_id, state="completed")["revision"] == 1

    tooling_id = "execution-stage7-tooling"
    enqueue(sidecar, notebook_id, tooling_id, "stage7_value = 42")
    sidecar.event("execution.state", tooling_id, state="completed")
    completion = sidecar.response(
        sidecar.send(
            "completion.request",
            {"code": "stage7_v", "cursor_pos": 8},
            notebook_id=notebook_id,
        )
    )["payload"]
    assert "stage7_value" in completion["matches"]
    assert completion["cursor_start"] == 0
    inspected = sidecar.response(
        sidecar.send(
            "inspect.request",
            {"code": "stage7_value", "cursor_pos": 12},
            notebook_id=notebook_id,
        )
    )["payload"]
    assert inspected["found"] is True
    variables = sidecar.response(
        sidecar.send("variables.list", {"limit": 50}, notebook_id=notebook_id)
    )["payload"]["variables"]
    stage7_variable = next(item for item in variables if item["name"] == "stage7_value")
    assert stage7_variable == {"name": "stage7_value", "type": "int", "value": "42"}

    widget_id = "execution-widget-live"
    enqueue(
        sidecar,
        notebook_id,
        widget_id,
        "from tqdm.auto import tqdm\nimport time\nfor _ in tqdm(range(3)):\n time.sleep(0.12)",
    )
    opened = sidecar.wait_for(
        lambda message: message.get("type") == "execution.widget"
        and message.get("payload", {}).get("execution_id") == widget_id
        and message.get("payload", {}).get("state", {}).get("_model_name")
        == "FloatProgressModel"
    )
    progress_model = opened["payload"]["model_id"]
    display = sidecar.event("execution.display", widget_id)
    assert "application/vnd.jupyter.widget-view+json" in display["payload"]["data"]
    updated = sidecar.wait_for(
        lambda message: message.get("type") == "execution.widget"
        and message.get("payload", {}).get("execution_id") == widget_id
        and message.get("payload", {}).get("model_id") == progress_model
        and message.get("payload", {}).get("state", {}).get("value", 0) >= 1
    )
    assert updated["payload"]["action"] == "update"
    sidecar.event("execution.state", widget_id, state="completed")

    ipympl_id = "execution-ipympl"
    enqueue(
        sidecar,
        notebook_id,
        ipympl_id,
        "%matplotlib widget\nimport matplotlib.pyplot as plt\nfig, ax = plt.subplots()\nax.plot([0, 1], [0, 1])\nfig.canvas",
    )
    canvas_open = sidecar.wait_for(
        lambda message: message.get("type") == "execution.widget"
        and message.get("payload", {}).get("execution_id") == ipympl_id
        and message.get("payload", {}).get("state", {}).get("_model_name")
        == "MPLCanvasModel",
        timeout=30,
    )
    canvas_model = canvas_open["payload"]["model_id"]
    canvas_frame = sidecar.wait_for(
        lambda message: message.get("type") == "execution.widget"
        and message.get("payload", {}).get("execution_id") == ipympl_id
        and message.get("payload", {}).get("model_id") == canvas_model
        and str(
            message.get("payload", {}).get("state", {}).get("_data_url", "")
        ).startswith("data:image/png;base64,"),
        timeout=30,
    )
    assert len(canvas_frame["payload"]["state"]["_data_url"]) > 100
    ipympl_display = sidecar.event("execution.display", ipympl_id)
    assert (
        "application/vnd.jupyter.widget-view+json" in ipympl_display["payload"]["data"]
    )
    sidecar.event("execution.state", ipympl_id, state="completed")

    stdin_id = "execution-stdin"
    enqueue(
        sidecar,
        notebook_id,
        stdin_id,
        "value = input('Name: '); print('hello ' + value)",
    )
    stdin_request = sidecar.event("execution.stdin_request", stdin_id)
    assert stdin_request["payload"]["prompt"] == "Name: "
    reply = sidecar.send(
        "execution.stdin_reply",
        {"execution_id": stdin_id, "value": "nvjup"},
        notebook_id=notebook_id,
    )
    assert sidecar.response(reply)["payload"]["accepted"] is True
    assert (
        "hello nvjup" in sidecar.event("execution.stream", stdin_id)["payload"]["text"]
    )
    sidecar.event("execution.state", stdin_id, state="completed")

    error_id = "execution-error"
    enqueue(sidecar, notebook_id, error_id, "raise ValueError('expected failure')")
    error = sidecar.event("execution.error", error_id)
    assert error["payload"]["ename"] == "ValueError"
    assert "expected failure" in error["payload"]["evalue"]
    sidecar.event("execution.state", error_id, state="failed")

    enqueue(sidecar, notebook_id, "execution-queue-1", "print('queue one')")
    enqueue(sidecar, notebook_id, "execution-queue-2", "print('queue two')")
    sidecar.event("execution.state", "execution-queue-1", state="completed")
    sidecar.event("execution.state", "execution-queue-2", state="completed")

    enqueue(sidecar, notebook_id, "execution-holder", "import time; time.sleep(0.2)")
    sidecar.event("execution.state", "execution-holder", state="running")
    enqueue(sidecar, notebook_id, "execution-cancelled", "print('must not run')")
    cancel = sidecar.response(
        sidecar.send(
            "execution.cancel",
            {"execution_id": "execution-cancelled"},
            notebook_id=notebook_id,
        )
    )
    assert cancel["payload"]["cancelled"] is True
    sidecar.event("execution.state", "execution-cancelled", state="cancelled")
    sidecar.event("execution.state", "execution-holder", state="completed")

    interrupt_id = "execution-interrupt"
    enqueue(sidecar, notebook_id, interrupt_id, "import time; time.sleep(30)")
    sidecar.event("execution.state", interrupt_id, state="running")
    interrupted = sidecar.response(
        sidecar.send("kernel.interrupt", notebook_id=notebook_id)
    )
    assert interrupted["payload"]["state"] == "interrupting"
    sidecar.event("execution.state", interrupt_id, state="failed", timeout=15)

    restarted = sidecar.response(
        sidecar.send("kernel.restart", notebook_id=notebook_id), timeout=40
    )
    assert restarted["payload"]["state"] == "idle"
    assert restarted["payload"]["generation"] == 2

    death_id = "execution-death"
    enqueue(
        sidecar, notebook_id, death_id, "import os, time; time.sleep(0.1); os._exit(23)"
    )
    enqueue(sidecar, notebook_id, "execution-after-death", "print('must be cancelled')")
    dead = sidecar.event("kernel.dead", timeout=15)
    assert dead["payload"]["generation"] == 2
    sidecar.event("execution.state", death_id, state="failed")
    sidecar.event("execution.state", "execution-after-death", state="cancelled")
