from __future__ import annotations

import asyncio
import base64
import binascii
import contextlib
import json
import re
import uuid
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Any, Self
from urllib.parse import quote, quote_plus, urlencode, urlsplit, urlunsplit

import aiohttp

WS_PROTOCOL = "v1.kernel.websocket.jupyter.org"
MAX_MESSAGE_BYTES = 16 * 1024 * 1024
MAX_CONTENT_MODEL_BYTES = 16 * 1024 * 1024
COLAB_PROVIDER = "colab"


def _auth_headers(token: str, provider: str) -> dict[str, str]:
    if provider == COLAB_PROVIDER:
        return {
            "X-Colab-Runtime-Proxy-Token": token,
            "X-Colab-Client-Agent": "nvjup",
        }
    return {"Authorization": f"token {token}"} if token else {}


def _auth_params(
    token: str, provider: str, params: dict[str, Any] | None = None
) -> dict[str, Any] | None:
    merged = dict(params or {})
    if provider == COLAB_PROVIDER:
        merged.update({"authuser": "0", "colab-runtime-proxy-token": token})
    return merged or None


def _percent_escape_pattern(value: str) -> str:
    """Match a URL-encoded value while ignoring hex-digit case only."""
    parts: list[str] = []
    index = 0
    while index < len(value):
        if (
            index + 2 < len(value)
            and value[index] == "%"
            and re.fullmatch(r"[0-9A-Fa-f]{2}", value[index + 1 : index + 3])
        ):
            high, low = value[index + 1], value[index + 2]
            parts.append(
                "%"
                + (f"[{high.lower()}{high.upper()}]" if high.isalpha() else high)
                + (f"[{low.lower()}{low.upper()}]" if low.isalpha() else low)
            )
            index += 3
            continue
        parts.append(re.escape(value[index]))
        index += 1
    return "".join(parts)


def _redact_token(message: object, token: str) -> str:
    text = str(message)
    if not token:
        return text
    # aiohttp/yarl errors may echo an arbitrary response body, not just a URL.
    # First redact named query values, then raw and URL/form-encoded copies of
    # the exact token. Percent hex digits are case-insensitive by definition.
    text = re.sub(
        r"([?&]colab-runtime-proxy-token=)[^&#\s'\"\)>]*",
        r"\1<redacted>",
        text,
        flags=re.IGNORECASE,
    )
    encoded = {quote(token, safe=""), quote_plus(token, safe="")}
    for value in sorted(encoded, key=len, reverse=True):
        if value:
            text = re.sub(_percent_escape_pattern(value), "<redacted>", text)
    return text.replace(token, "<redacted>")


async def _reject_colab_redirect(
    _session: aiohttp.ClientSession,
    _context: aiohttp.TraceConfigCtx,
    params: aiohttp.TraceRequestRedirectParams,
) -> None:
    if "X-Colab-Runtime-Proxy-Token" in params.headers:
        raise RuntimeError("Google Colab credentialed WebSocket redirect refused")


def _http_session(timeout: float, provider: str) -> aiohttp.ClientSession:
    traces: list[aiohttp.TraceConfig] = []
    if provider == COLAB_PROVIDER:
        trace = aiohttp.TraceConfig()
        trace.on_request_redirect.append(_reject_colab_redirect)
        traces.append(trace)
    return aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=timeout), trace_configs=traces
    )


def _clean_base_url(value: str) -> str:
    parsed = urlsplit(value.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("remote Jupyter URL must use http:// or https://")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("remote Jupyter URL cannot contain embedded credentials")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""))


def _content_path(value: str, *, allow_root: bool = True) -> str:
    if not isinstance(value, str) or "\x00" in value or "\\" in value:
        raise ValueError("invalid remote content path")
    stripped = value.strip("/")
    if not stripped:
        if allow_root:
            return ""
        raise ValueError("remote content path cannot be the server root")
    parts = stripped.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ValueError(
            "remote content path cannot contain empty, '.' or '..' segments"
        )
    return "/".join(parts)


def _deserialize_v1(data: bytes) -> dict[str, Any]:
    if len(data) < 24:
        raise ValueError("invalid remote kernel frame")
    count = int.from_bytes(data[:8], "little")
    if count < 6 or count > 1024 or len(data) < 8 * (count + 1):
        raise ValueError("invalid remote kernel frame offsets")
    offsets = [
        int.from_bytes(data[8 * (index + 1) : 8 * (index + 2)], "little")
        for index in range(count)
    ]
    if offsets != sorted(offsets) or offsets[0] < 8 * (count + 1):
        raise ValueError("invalid remote kernel frame ordering")
    offsets.append(len(data))
    parts = [data[offsets[index] : offsets[index + 1]] for index in range(count - 1)]
    if len(parts) < 5:
        raise ValueError("incomplete remote kernel frame")
    message = {
        "channel": parts[0].decode("utf-8"),
        "header": json.loads(parts[1]),
        "parent_header": json.loads(parts[2]),
        "metadata": json.loads(parts[3]),
        "content": json.loads(parts[4]),
        "buffers": parts[5:],
    }
    message["msg_type"] = message["header"].get("msg_type")
    return message


def _serialize_v1(message: dict[str, Any], channel: str) -> bytes:
    parts = [
        channel.encode("utf-8"),
        json.dumps(message["header"], ensure_ascii=False).encode("utf-8"),
        json.dumps(message.get("parent_header", {}), ensure_ascii=False).encode(
            "utf-8"
        ),
        json.dumps(message.get("metadata", {}), ensure_ascii=False).encode("utf-8"),
        json.dumps(message.get("content", {}), ensure_ascii=False).encode("utf-8"),
        *message.get("buffers", []),
    ]
    count = len(parts) + 1
    offsets = [8 * (count + 1)]
    for part in parts:
        offsets.append(offsets[-1] + len(part))
    return b"".join(
        [
            count.to_bytes(8, "little"),
            *(offset.to_bytes(8, "little") for offset in offsets),
            *parts,
        ]
    )


class RemoteKernelClient:
    def __init__(self, manager: RemoteKernelManager) -> None:
        self.manager = manager
        self.session_id = uuid.uuid4().hex
        self.ws: aiohttp.ClientWebSocketResponse | None = None
        self.receiver_task: asyncio.Task[None] | None = None
        self.queues = {
            channel: asyncio.Queue(maxsize=2048)
            for channel in ("shell", "iopub", "stdin", "control")
        }
        self.last_input_request: dict[str, Any] | None = None
        self.v1_protocol = manager.provider != COLAB_PROVIDER
        self.closed = False

    async def connect(self) -> None:
        ws_scheme = "wss" if self.manager.base_url.startswith("https://") else "ws"
        http = urlsplit(self.manager.base_url)
        query = _auth_params(
            self.manager.token,
            self.manager.provider,
            {"session_id": self.session_id},
        )
        url = urlunsplit(
            (
                ws_scheme,
                http.netloc,
                f"{http.path}/api/kernels/{quote(self.manager.kernel_id, safe='')}/channels",
                urlencode(query or {}),
                "",
            )
        )
        headers = self.manager.headers()
        if self.manager.origin:
            headers["Origin"] = self.manager.origin
        try:
            self.ws = await self.manager.http.ws_connect(
                url,
                headers=headers,
                # Colab's managed Jupyter proxy uses the legacy/default JSON
                # channel framing and does not negotiate Jupyter WebSocket v1.
                protocols=(
                    () if self.manager.provider == COLAB_PROVIDER else (WS_PROTOCOL,)
                ),
                heartbeat=30,
                max_msg_size=MAX_MESSAGE_BYTES,
                ssl=self.manager.verify_ssl,
            )
        except Exception as exc:
            if self.manager.provider == COLAB_PROVIDER:
                raise RuntimeError(_redact_token(exc, self.manager.token)) from None
            raise
        self.v1_protocol = self.ws.protocol == WS_PROTOCOL
        if self.manager.provider != COLAB_PROVIDER and not self.v1_protocol:
            await self.ws.close()
            self.ws = None
            raise RuntimeError(
                "Jupyter Server did not negotiate the v1 kernel WebSocket protocol"
            )
        self.closed = False
        self.receiver_task = asyncio.create_task(self._receive())

    async def reconnect(self) -> None:
        await self.close()
        self.queues = {
            channel: asyncio.Queue(maxsize=2048)
            for channel in ("shell", "iopub", "stdin", "control")
        }
        await self.connect()

    async def close(self) -> None:
        self.closed = True
        if self.receiver_task:
            self.receiver_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self.receiver_task
            self.receiver_task = None
        if self.ws and not self.ws.closed:
            try:
                await self.ws.close()
            except Exception as exc:
                if self.manager.provider == COLAB_PROVIDER:
                    raise RuntimeError(_redact_token(exc, self.manager.token)) from None
                raise
        self.ws = None

    async def _receive(self) -> None:
        assert self.ws is not None
        try:
            async for frame in self.ws:
                if frame.type == aiohttp.WSMsgType.BINARY:
                    message = _deserialize_v1(frame.data)
                elif frame.type == aiohttp.WSMsgType.TEXT:
                    message = json.loads(frame.data)
                    message["msg_type"] = message.get("msg_type") or message.get(
                        "header", {}
                    ).get("msg_type")
                elif frame.type in {aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED}:
                    break
                elif frame.type == aiohttp.WSMsgType.ERROR:
                    raise RuntimeError("remote kernel WebSocket failed")
                else:
                    continue
                channel = message.get("channel")
                queue = self.queues.get(channel)
                if queue is not None:
                    await queue.put(message)
        except Exception as exc:
            if self.manager.provider == COLAB_PROVIDER:
                raise RuntimeError(_redact_token(exc, self.manager.token)) from None
            raise
        finally:
            self.closed = True
            for queue in self.queues.values():
                if not queue.full():
                    queue.put_nowait({"_remote_closed": True})

    @staticmethod
    def _header(message_type: str, session_id: str) -> dict[str, Any]:
        return {
            "msg_id": uuid.uuid4().hex,
            "username": "nvjup",
            "session": session_id,
            "date": datetime.now(UTC).isoformat(),
            "msg_type": message_type,
            "version": "5.3",
        }

    async def _send_wire(self, message: dict[str, Any], channel: str) -> None:
        if not self.ws:
            raise RuntimeError("remote kernel WebSocket is closed")
        if self.v1_protocol:
            await self.ws.send_bytes(_serialize_v1(message, channel))
            return
        default_message = {**message, "channel": channel}
        await self.ws.send_str(json.dumps(default_message, ensure_ascii=False))

    async def _send(
        self,
        channel: str,
        message_type: str,
        content: dict[str, Any],
        parent_header: dict[str, Any] | None = None,
    ) -> str:
        if self.closed or not self.ws or self.ws.closed:
            raise RuntimeError("remote kernel WebSocket is closed")
        header = self._header(message_type, self.session_id)
        message = {
            "header": header,
            "parent_header": parent_header or {},
            "metadata": {},
            "content": content,
            "buffers": [],
        }
        try:
            await self._send_wire(message, channel)
        except Exception as exc:
            if self.manager.provider == COLAB_PROVIDER:
                raise RuntimeError(_redact_token(exc, self.manager.token)) from None
            raise
        return str(header["msg_id"])

    def _schedule(
        self, channel: str, message_type: str, content: dict[str, Any]
    ) -> str:
        message_id = uuid.uuid4().hex

        async def send() -> None:
            if self.closed or not self.ws or self.ws.closed:
                raise RuntimeError("remote kernel WebSocket is closed")
            header = self._header(message_type, self.session_id)
            header["msg_id"] = message_id
            try:
                await self._send_wire(
                    {
                        "header": header,
                        "parent_header": {},
                        "metadata": {},
                        "content": content,
                        "buffers": [],
                    },
                    channel,
                )
            except Exception as exc:
                if self.manager.provider == COLAB_PROVIDER:
                    raise RuntimeError(_redact_token(exc, self.manager.token)) from None
                raise

        task = asyncio.create_task(send())
        task.add_done_callback(self._send_done)
        return message_id

    @staticmethod
    def _send_done(task: asyncio.Task[None]) -> None:
        if not task.cancelled():
            task.exception()

    def start_channels(self) -> None:
        return None

    def stop_channels(self) -> None:
        if self.receiver_task:
            self.receiver_task.cancel()

    def complete(self, *, code: str, cursor_pos: int) -> str:
        return self._schedule(
            "shell", "complete_request", {"code": code, "cursor_pos": cursor_pos}
        )

    def inspect(self, *, code: str, cursor_pos: int, detail_level: int) -> str:
        return self._schedule(
            "shell",
            "inspect_request",
            {"code": code, "cursor_pos": cursor_pos, "detail_level": detail_level},
        )

    def execute(
        self,
        code: str,
        *,
        silent: bool = False,
        store_history: bool = True,
        allow_stdin: bool = True,
        user_expressions: dict[str, str] | None = None,
        stop_on_error: bool = True,
    ) -> str:
        return self._schedule(
            "shell",
            "execute_request",
            {
                "code": code,
                "silent": silent,
                "store_history": store_history,
                "user_expressions": user_expressions or {},
                "allow_stdin": allow_stdin,
                "stop_on_error": stop_on_error,
            },
        )

    async def get_shell_msg(self, timeout: float | None = None) -> dict[str, Any]:
        while not self.queues["iopub"].empty():
            self.queues["iopub"].get_nowait()
        getter = self.queues["shell"].get()
        message = (
            await asyncio.wait_for(getter, timeout=timeout) if timeout else await getter
        )
        if message.get("_remote_closed"):
            raise ConnectionError("remote kernel WebSocket closed")
        return message

    async def wait_for_ready(self, timeout: float = 30) -> None:
        deadline = asyncio.get_running_loop().time() + timeout
        last_error: Exception | None = None
        for attempt in range(3):
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                break
            if attempt > 0:
                await self.reconnect()
            message_id = self._schedule("shell", "kernel_info_request", {})
            attempt_deadline = min(
                deadline, asyncio.get_running_loop().time() + max(2.0, timeout / 3)
            )
            try:
                while True:
                    wait = attempt_deadline - asyncio.get_running_loop().time()
                    if wait <= 0:
                        raise TimeoutError("remote kernel readiness attempt timed out")
                    message = await self.get_shell_msg(wait)
                    if message.get("parent_header", {}).get("msg_id") == message_id:
                        return
            except (ConnectionError, TimeoutError) as exc:
                last_error = exc
        raise TimeoutError("remote kernel did not become ready") from last_error

    async def execute_interactive(
        self,
        code: str,
        *,
        allow_stdin: bool,
        stop_on_error: bool,
        output_hook: Callable[[dict[str, Any]], None],
        stdin_hook: Callable[[dict[str, Any]], Awaitable[None]],
        timeout: float | None = None,
    ) -> dict[str, Any]:
        message_id = self.execute(
            code,
            allow_stdin=allow_stdin,
            stop_on_error=stop_on_error,
        )
        reply: dict[str, Any] | None = None
        idle = False
        while reply is None or not idle:
            tasks = {
                asyncio.create_task(self.queues[channel].get()): channel
                for channel in ("shell", "iopub", "stdin")
            }
            done, pending = await asyncio.wait(
                tasks, timeout=timeout, return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
            if not done:
                raise TimeoutError("remote execution timed out")
            for task in done:
                message = task.result()
                if message.get("_remote_closed"):
                    raise ConnectionError("remote kernel WebSocket closed")
                parent_id = message.get("parent_header", {}).get("msg_id")
                if parent_id != message_id:
                    continue
                channel = tasks[task]
                if channel == "shell":
                    reply = message
                elif channel == "stdin":
                    self.last_input_request = message
                    await stdin_hook(message)
                else:
                    output_hook(message)
                    if (
                        message.get("msg_type") == "status"
                        and message.get("content", {}).get("execution_state") == "idle"
                    ):
                        idle = True
        return reply

    def input(self, value: str) -> None:
        parent = (
            self.last_input_request.get("header", {}) if self.last_input_request else {}
        )
        asyncio.create_task(
            self._send("stdin", "input_reply", {"value": value}, parent)
        )
        self.last_input_request = None


class RemoteContentsClient:
    def __init__(
        self,
        *,
        base_url: str,
        token: str,
        verify_ssl: bool,
        origin: str | None,
        timeout: float,
        max_file_bytes: int,
        max_entries: int,
        provider: str = "jupyter",
    ) -> None:
        self.base_url = _clean_base_url(base_url)
        self.token = token
        self.provider = provider if provider == COLAB_PROVIDER else "jupyter"
        if self.provider == COLAB_PROVIDER and not token:
            raise ValueError("Google Colab runtime proxy token is required")
        self.verify_ssl = verify_ssl
        self.origin = origin
        self.timeout = max(1.0, min(timeout, 300.0))
        self.max_file_bytes = max(1, min(max_file_bytes, 512 * 1024 * 1024))
        self.max_entries = max(1, min(max_entries, 100_000))
        self.http = _http_session(self.timeout, self.provider)

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    async def close(self) -> None:
        if not self.http.closed:
            await self.http.close()

    def headers(self) -> dict[str, str]:
        headers = _auth_headers(self.token, self.provider)
        if self.origin:
            headers["Origin"] = self.origin
        return headers

    def params(self, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
        return _auth_params(self.token, self.provider, params)

    def _url(self, prefix: str, path: str) -> str:
        encoded = quote(_content_path(path), safe="/")
        return f"{self.base_url}{prefix}{('/' + encoded) if encoded else ''}"

    async def _json_request(
        self,
        method: str,
        prefix: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        allow_root: bool = True,
    ) -> Any:
        normalized = _content_path(path, allow_root=allow_root)
        try:
            async with self.http.request(
                method,
                self._url(prefix, normalized),
                headers=self.headers(),
                ssl=self.verify_ssl,
                params=self.params(params),
                json=body,
                allow_redirects=False,
            ) as response:
                raw = await response.content.read(MAX_CONTENT_MODEL_BYTES + 1)
                if len(raw) > MAX_CONTENT_MODEL_BYTES:
                    raise ValueError("remote content response exceeds 16 MB")
                if response.status >= 300:
                    detail = raw.decode("utf-8", "replace")[:1024].replace("\n", " ")
                    raise RuntimeError(
                        f"Jupyter Server returned HTTP {response.status}: {detail}"
                    )
                if response.status == 204 or not raw:
                    return None
                return json.loads(raw)
        except Exception as exc:
            if self.provider == COLAB_PROVIDER:
                raise RuntimeError(_redact_token(exc, self.token)) from None
            raise

    @staticmethod
    def _entry(
        model: dict[str, Any], *, expected_path: str | None = None
    ) -> dict[str, Any]:
        raw_name = model.get("name", "")
        if not isinstance(raw_name, str):
            raise ValueError("remote entry name must be a string")
        if (
            not raw_name
            or len(raw_name) > 4096
            or raw_name in {".", ".."}
            or "/" in raw_name
            or "\\" in raw_name
            or "\x00" in raw_name
        ):
            raise ValueError("remote entry name must be a single basename")
        path = _content_path(str(model.get("path", "")), allow_root=False)
        if path.rsplit("/", 1)[-1] != raw_name:
            raise ValueError("remote entry name is inconsistent with its path")
        if expected_path is not None and path != _content_path(
            expected_path, allow_root=False
        ):
            raise ValueError("remote entry path is inconsistent with the request")
        return {
            "name": raw_name,
            "path": path,
            "type": str(model.get("type", "file"))[:64],
            "writable": bool(model.get("writable", False)),
            "size": model.get("size") if isinstance(model.get("size"), int) else None,
            "created": str(model.get("created", ""))[:128],
            "last_modified": str(model.get("last_modified", ""))[:128],
            "mimetype": str(model.get("mimetype") or "")[:256],
        }

    async def server_info(self) -> dict[str, Any]:
        info = await self._json_request("GET", "/api", "")
        response = await self._json_request("GET", "/api/kernelspecs", "")
        raw_specs = (
            response.get("kernelspecs", {}) if isinstance(response, dict) else {}
        )
        if not isinstance(raw_specs, dict):
            raise TypeError("Jupyter Server returned invalid kernelspec data")
        if len(raw_specs) > 1000:
            raise ValueError("remote server returned too many kernelspecs")
        kernels = []
        for name, model in raw_specs.items():
            if not isinstance(name, str) or not isinstance(model, dict):
                continue
            spec = model.get("spec", {})
            if not isinstance(spec, dict):
                spec = {}
            kernels.append(
                {
                    "name": name[:256],
                    "display_name": str(spec.get("display_name") or name)[:512],
                    "language": str(spec.get("language") or "")[:128],
                }
            )
        kernels.sort(key=lambda item: (item["display_name"].casefold(), item["name"]))
        return {
            "url": self.base_url,
            "version": (
                str(info.get("version") or "")[:128] if isinstance(info, dict) else ""
            ),
            "kernels": kernels,
        }

    async def list(self, path: str) -> dict[str, Any]:
        normalized = _content_path(path)
        model = await self._json_request(
            "GET",
            "/api/contents",
            normalized,
            params={"content": 1, "type": "directory"},
        )
        content = model.get("content", []) if isinstance(model, dict) else []
        if not isinstance(content, list):
            raise TypeError("Jupyter Server returned an invalid directory model")
        if len(content) > self.max_entries:
            raise ValueError(f"remote directory exceeds {self.max_entries} entries")
        entries = []
        for item in content:
            if not isinstance(item, dict):
                raise TypeError("Jupyter Server returned an invalid directory entry")
            entry = self._entry(item)
            parent = entry["path"].rsplit("/", 1)[0] if "/" in entry["path"] else ""
            if parent != normalized:
                raise ValueError("remote entry path escapes the listed directory")
            entries.append(entry)
        entries.sort(
            key=lambda item: (
                item["type"] != "directory",
                item["name"].casefold(),
                item["name"],
            )
        )
        return {"path": normalized, "entries": entries}

    async def stat(self, path: str) -> dict[str, Any]:
        normalized = _content_path(path)
        model = await self._json_request(
            "GET", "/api/contents", normalized, params={"content": 0}
        )
        if not isinstance(model, dict):
            raise TypeError("Jupyter Server returned an invalid content model")
        return self._entry(model, expected_path=normalized)

    async def mkdir(self, path: str) -> dict[str, Any]:
        normalized = _content_path(path, allow_root=False)
        model = await self._json_request(
            "PUT",
            "/api/contents",
            normalized,
            body={"type": "directory", "format": "json", "content": None},
            allow_root=False,
        )
        return self._entry(model, expected_path=normalized)

    async def touch(self, path: str) -> dict[str, Any]:
        return await self.upload(path, b"")

    async def upload(self, path: str, content: bytes) -> dict[str, Any]:
        normalized = _content_path(path, allow_root=False)
        if len(content) > self.max_file_bytes:
            raise ValueError(f"file exceeds {self.max_file_bytes} bytes")
        model = await self._json_request(
            "PUT",
            "/api/contents",
            normalized,
            body={
                "type": "file",
                "format": "base64",
                "content": base64.b64encode(content).decode("ascii"),
            },
            allow_root=False,
        )
        return self._entry(model, expected_path=normalized)

    async def download(self, path: str, max_bytes: int | None = None) -> bytes:
        normalized = _content_path(path, allow_root=False)
        limit = (
            self.max_file_bytes
            if max_bytes is None
            else min(self.max_file_bytes, max_bytes)
        )
        if limit < 0:
            raise ValueError("download byte limit cannot be negative")
        try:
            async with self.http.get(
                self._url("/files", normalized),
                headers=self.headers(),
                params=self.params(),
                ssl=self.verify_ssl,
                allow_redirects=False,
            ) as response:
                if response.status < 300:
                    declared = response.content_length
                    if declared is not None and declared > limit:
                        raise ValueError(f"file exceeds {limit} bytes")
                    chunks: list[bytes] = []
                    size = 0
                    async for chunk in response.content.iter_chunked(64 * 1024):
                        size += len(chunk)
                        if size > limit:
                            raise ValueError(f"file exceeds {limit} bytes")
                        chunks.append(chunk)
                    return b"".join(chunks)
                if response.status not in {400, 404}:
                    detail = (await response.text())[:1024].replace("\n", " ")
                    raise RuntimeError(
                        f"Jupyter Server returned HTTP {response.status}: {detail}"
                    )
        except Exception as exc:
            if self.provider == COLAB_PROVIDER:
                raise RuntimeError(_redact_token(exc, self.token)) from None
            raise
        model = await self._json_request(
            "GET", "/api/contents", normalized, params={"content": 1}, allow_root=False
        )
        if not isinstance(model, dict):
            raise TypeError("Jupyter Server returned an invalid file model")
        content = model.get("content")
        file_format = model.get("format")
        if file_format == "base64" and isinstance(content, str):
            try:
                result = base64.b64decode(content, validate=True)
            except (ValueError, binascii.Error) as exc:
                raise RuntimeError(
                    "Jupyter Server returned invalid base64 file content"
                ) from exc
        elif file_format == "text" and isinstance(content, str):
            result = content.encode("utf-8")
        elif file_format == "json":
            result = (json.dumps(content, ensure_ascii=False, indent=1) + "\n").encode(
                "utf-8"
            )
        else:
            raise RuntimeError("Jupyter Server returned an unsupported file format")
        if len(result) > limit:
            raise ValueError(f"file exceeds {limit} bytes")
        return result

    async def rename(self, path: str, new_path: str) -> dict[str, Any]:
        normalized = _content_path(path, allow_root=False)
        target = _content_path(new_path, allow_root=False)
        model = await self._json_request(
            "PATCH",
            "/api/contents",
            normalized,
            body={"path": target},
            allow_root=False,
        )
        return self._entry(model, expected_path=target)

    async def delete(self, path: str) -> None:
        normalized = _content_path(path, allow_root=False)
        await self._json_request(
            "DELETE", "/api/contents", normalized, allow_root=False
        )


class RemoteKernelManager:
    def __init__(
        self,
        base_url: str,
        token: str,
        verify_ssl: bool,
        origin: str | None,
        timeout: float,
        reconnect_attempts: int,
        provider: str = "jupyter",
    ) -> None:
        self.base_url = _clean_base_url(base_url)
        self.token = token
        self.provider = provider if provider == COLAB_PROVIDER else "jupyter"
        if self.provider == COLAB_PROVIDER and not token:
            raise ValueError("Google Colab runtime proxy token is required")
        self.verify_ssl = verify_ssl
        self.origin = origin
        self.timeout = max(1.0, min(timeout, 120.0))
        self.reconnect_attempts = max(0, min(reconnect_attempts, 5))
        self.reconnect_count = 0
        self.http = _http_session(self.timeout, self.provider)
        self.kernel_id = ""
        self.client_instance: RemoteKernelClient | None = None

    def headers(self) -> dict[str, str]:
        return _auth_headers(self.token, self.provider)

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        try:
            async with self.http.request(
                method,
                self.base_url + path,
                headers=self.headers(),
                params=_auth_params(
                    self.token, self.provider, kwargs.pop("params", None)
                ),
                ssl=self.verify_ssl,
                allow_redirects=False,
                **kwargs,
            ) as response:
                if response.status >= 300:
                    detail = (await response.text())[:1024].replace("\n", " ")
                    raise RuntimeError(
                        f"Jupyter Server returned HTTP {response.status}: {detail}"
                    )
                if response.status == 204:
                    return None
                return await response.json()
        except Exception as exc:
            if self.provider == COLAB_PROVIDER:
                raise RuntimeError(_redact_token(exc, self.token)) from None
            raise

    @classmethod
    async def create(
        cls,
        *,
        base_url: str,
        token: str,
        verify_ssl: bool,
        origin: str | None,
        timeout: float,
        reconnect_attempts: int,
        kernel_name: str,
        provider: str = "jupyter",
    ) -> RemoteKernelManager:
        manager = cls(
            base_url,
            token,
            verify_ssl,
            origin,
            timeout,
            reconnect_attempts,
            provider,
        )
        try:
            model = await manager._request(
                "POST", "/api/kernels", json={"name": kernel_name}
            )
            manager.kernel_id = str(model["id"])
            manager.client_instance = RemoteKernelClient(manager)
            await manager.client_instance.connect()
            return manager
        except Exception:
            if manager.kernel_id:
                with contextlib.suppress(Exception):
                    await manager._request(
                        "DELETE", f"/api/kernels/{quote(manager.kernel_id, safe='')}"
                    )
            await manager.http.close()
            raise

    def client(self) -> RemoteKernelClient:
        if not self.client_instance:
            raise RuntimeError("remote kernel client is unavailable")
        return self.client_instance

    async def interrupt_kernel(self) -> None:
        await self._request(
            "POST", f"/api/kernels/{quote(self.kernel_id, safe='')}/interrupt"
        )

    async def restart_kernel(self, now: bool = True) -> None:
        await self._request(
            "POST", f"/api/kernels/{quote(self.kernel_id, safe='')}/restart"
        )
        assert self.client_instance is not None
        await self.client_instance.reconnect()
        self.reconnect_count = 0

    async def shutdown_kernel(self, now: bool = False) -> None:
        if self.client_instance:
            await self.client_instance.close()
        if self.kernel_id:
            try:
                await self._request(
                    "DELETE", f"/api/kernels/{quote(self.kernel_id, safe='')}"
                )
            finally:
                self.kernel_id = ""
        await self.http.close()

    async def is_alive(self) -> bool:
        if not self.kernel_id or self.http.closed:
            return False
        try:
            await self._request("GET", f"/api/kernels/{quote(self.kernel_id, safe='')}")
            if self.client_instance and self.client_instance.closed:
                if self.reconnect_count >= self.reconnect_attempts:
                    return False
                self.reconnect_count += 1
                await self.client_instance.reconnect()
            return True
        except Exception:  # noqa: BLE001 - any transport failure means not alive
            return False
