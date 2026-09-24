from __future__ import annotations

import asyncio
import contextlib
import json
import uuid
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

import aiohttp

WS_PROTOCOL = "v1.kernel.websocket.jupyter.org"
MAX_MESSAGE_BYTES = 16 * 1024 * 1024


def _clean_base_url(value: str) -> str:
    parsed = urlsplit(value.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("remote Jupyter URL must use http:// or https://")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""))


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
        self.closed = False

    async def connect(self) -> None:
        ws_scheme = "wss" if self.manager.base_url.startswith("https://") else "ws"
        http = urlsplit(self.manager.base_url)
        url = urlunsplit(
            (
                ws_scheme,
                http.netloc,
                f"{http.path}/api/kernels/{quote(self.manager.kernel_id, safe='')}/channels",
                f"session_id={self.session_id}",
                "",
            )
        )
        headers = self.manager.headers()
        if self.manager.origin:
            headers["Origin"] = self.manager.origin
        self.ws = await self.manager.http.ws_connect(
            url,
            headers=headers,
            protocols=(WS_PROTOCOL,),
            heartbeat=30,
            max_msg_size=MAX_MESSAGE_BYTES,
            ssl=self.manager.verify_ssl,
        )
        if self.ws.protocol != WS_PROTOCOL:
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
            await self.ws.close()
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
        await self.ws.send_bytes(_serialize_v1(message, channel))
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
            await self.ws.send_bytes(
                _serialize_v1(
                    {
                        "header": header,
                        "parent_header": {},
                        "metadata": {},
                        "content": content,
                        "buffers": [],
                    },
                    channel,
                )
            )

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
        message_id = self._schedule("shell", "kernel_info_request", {})
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError("remote kernel did not become ready")
            message = await self.get_shell_msg(remaining)
            if message.get("parent_header", {}).get("msg_id") == message_id:
                return

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


class RemoteKernelManager:
    def __init__(
        self,
        base_url: str,
        token: str,
        verify_ssl: bool,
        origin: str | None,
        timeout: float,
        reconnect_attempts: int,
    ) -> None:
        self.base_url = _clean_base_url(base_url)
        self.token = token
        self.verify_ssl = verify_ssl
        self.origin = origin
        self.timeout = max(1.0, min(timeout, 120.0))
        self.reconnect_attempts = max(0, min(reconnect_attempts, 5))
        self.reconnect_count = 0
        self.http = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=self.timeout)
        )
        self.kernel_id = ""
        self.client_instance: RemoteKernelClient | None = None

    def headers(self) -> dict[str, str]:
        return {"Authorization": f"token {self.token}"} if self.token else {}

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        async with self.http.request(
            method,
            self.base_url + path,
            headers=self.headers(),
            ssl=self.verify_ssl,
            **kwargs,
        ) as response:
            if response.status >= 400:
                detail = (await response.text())[:1024].replace("\n", " ")
                raise RuntimeError(
                    f"Jupyter Server returned HTTP {response.status}: {detail}"
                )
            if response.status == 204:
                return None
            return await response.json()

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
    ) -> RemoteKernelManager:
        manager = cls(base_url, token, verify_ssl, origin, timeout, reconnect_attempts)
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
