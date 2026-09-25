from __future__ import annotations

import ast
import asyncio
import base64
import binascii
import contextlib
import inspect
import json
import math
import os
import stat
import sys
import traceback
import uuid
from dataclasses import dataclass, field
from typing import Any

from jupyter_client import AsyncKernelManager
from jupyter_client.kernelspec import KernelSpec, KernelSpecManager

from nvjup_sidecar.remote import RemoteContentsClient, RemoteKernelManager

PROTOCOL = "nvjup/1"
VERSION = "0.5.0"
MAX_MESSAGE_BYTES = max(
    1,
    min(
        int(os.environ.get("NVJUP_MAX_MESSAGE_BYTES", 128 * 1024 * 1024)),
        512 * 1024 * 1024,
    ),
)


@dataclass
class Execution:
    execution_id: str
    cell_id: str
    revision: int
    code: str
    allow_stdin: bool = True
    stop_on_error: bool = True
    cancelled: bool = False
    terminal: bool = False
    stream_index: int = 0
    saw_error: bool = False


@dataclass
class KernelSession:
    server: "SidecarServer"
    notebook_id: str
    kernel_name: str
    manager: Any
    client: Any
    python_path: str | None = None
    python_source: str = "kernelspec"
    transport: str = "local"
    generation: int = 1
    state: str = "starting"
    queue: asyncio.Queue[Execution] = field(default_factory=asyncio.Queue)
    executions: dict[str, Execution] = field(default_factory=dict)
    stdin_waiters: dict[str, asyncio.Future[str]] = field(default_factory=dict)
    widget_comm_ids: set[str] = field(default_factory=set)
    active: Execution | None = None
    worker_task: asyncio.Task[None] | None = None
    monitor_task: asyncio.Task[None] | None = None
    closing: bool = False

    async def shell_reply(
        self, message_id: str, timeout: float = 5.0
    ) -> dict[str, Any]:
        if self.active or self.state != "idle":
            raise RuntimeError(f"kernel is not idle ({self.state})")
        loop = asyncio.get_running_loop()
        deadline = loop.time() + max(0.1, min(timeout, 30.0))
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise TimeoutError("kernel request timed out")
            message = await asyncio.wait_for(
                self.client.get_shell_msg(timeout=remaining), timeout=remaining + 0.1
            )
            parent_id = message.get("parent_header", {}).get("msg_id")
            if parent_id == message_id:
                return message

    def start_tasks(self) -> None:
        self.worker_task = asyncio.create_task(self._worker())
        self.monitor_task = asyncio.create_task(self._monitor())

    def emit_state(self, state: str, **payload: Any) -> None:
        self.state = state
        self.server.event(
            "kernel.state",
            notebook_id=self.notebook_id,
            payload={
                "state": state,
                "generation": self.generation,
                "python_path": self.python_path,
                "python_source": self.python_source,
                "transport": self.transport,
                **payload,
            },
        )

    def execution_event(
        self, kind: str, execution: Execution, payload: dict[str, Any]
    ) -> None:
        self.server.event(
            kind,
            notebook_id=self.notebook_id,
            cell_id=execution.cell_id,
            revision=execution.revision,
            payload={"execution_id": execution.execution_id, **payload},
        )

    async def enqueue(self, execution: Execution) -> None:
        self.executions[execution.execution_id] = execution
        await self.queue.put(execution)
        self.execution_event("execution.state", execution, {"state": "queued"})

    async def cancel(self, execution_id: str) -> bool:
        execution = self.executions.get(execution_id)
        if execution is None or execution.terminal:
            return False
        execution.cancelled = True
        waiter = self.stdin_waiters.pop(execution_id, None)
        if waiter and not waiter.done():
            waiter.set_result("")
        if self.active is execution:
            await self.manager.interrupt_kernel()
        else:
            execution.terminal = True
            self.execution_event("execution.state", execution, {"state": "cancelled"})
        return True

    async def reply_stdin(self, execution_id: str, value: str) -> bool:
        waiter = self.stdin_waiters.pop(execution_id, None)
        if waiter is None or waiter.done():
            return False
        waiter.set_result(value)
        return True

    async def restart(self) -> None:
        self.emit_state("restarting")
        await self._cancel_work("kernel restarted")
        await self.manager.restart_kernel(now=True)
        await self.client.wait_for_ready(timeout=30)
        self.generation += 1
        self.queue = asyncio.Queue()
        self.widget_comm_ids.clear()
        self.closing = False
        self.worker_task = asyncio.create_task(self._worker())
        if self.monitor_task is None or self.monitor_task.done():
            self.monitor_task = asyncio.create_task(self._monitor())
        self.emit_state("idle")

    async def shutdown(self, now: bool = False) -> None:
        if self.closing:
            return
        self.closing = True
        self.emit_state("shutting_down")
        await self._cancel_work("kernel shut down")
        if self.monitor_task:
            self.monitor_task.cancel()
        with contextlib.suppress(Exception):
            self.client.stop_channels()
        with contextlib.suppress(Exception):
            await self.manager.shutdown_kernel(now=now)
        self.state = "stopped"
        self.server.event(
            "kernel.state",
            notebook_id=self.notebook_id,
            payload={"state": "stopped", "generation": self.generation},
        )

    async def _cancel_work(self, reason: str) -> None:
        for execution in self.executions.values():
            if not execution.terminal:
                execution.cancelled = True
                execution.terminal = True
                self.execution_event(
                    "execution.state",
                    execution,
                    {"state": "cancelled", "reason": reason},
                )
        for waiter in self.stdin_waiters.values():
            if not waiter.done():
                waiter.set_result("")
        self.stdin_waiters.clear()
        if self.worker_task:
            self.worker_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.worker_task
        self.active = None

    def _mark_dead(self, reason: str, failed: Execution | None = None) -> None:
        if self.state == "dead":
            return
        self.state = "dead"
        self.server.event(
            "kernel.dead",
            notebook_id=self.notebook_id,
            payload={"generation": self.generation, "reason": reason},
        )
        for execution in self.executions.values():
            if execution.terminal:
                continue
            execution.terminal = True
            state = "failed" if execution is failed else "cancelled"
            self.execution_event(
                "execution.state", execution, {"state": state, "reason": reason}
            )
        for waiter in self.stdin_waiters.values():
            if not waiter.done():
                waiter.set_result("")
        self.stdin_waiters.clear()

    async def _monitor(self) -> None:
        try:
            while not self.closing:
                await asyncio.sleep(1)
                if self.state in {
                    "starting",
                    "restarting",
                    "shutting_down",
                    "stopped",
                    "dead",
                }:
                    continue
                if not await self.manager.is_alive():
                    self._mark_dead("kernel process exited", self.active)
                    if self.worker_task:
                        self.worker_task.cancel()
                    return
        except asyncio.CancelledError:
            return
        except Exception as exc:  # pragma: no cover - defensive monitor path
            self.server.log("error", f"kernel monitor failed: {exc}")

    async def _worker(self) -> None:
        try:
            while not self.closing:
                execution = await self.queue.get()
                if execution.cancelled or execution.terminal:
                    self.queue.task_done()
                    continue
                self.active = execution
                self.emit_state("busy", execution_id=execution.execution_id)
                await self._execute(execution)
                self.active = None
                self.queue.task_done()
                if not self.closing and self.state != "dead":
                    self.emit_state("idle")
        except asyncio.CancelledError:
            return

    async def _execute(self, execution: Execution) -> None:
        self.execution_event("execution.state", execution, {"state": "sent"})

        def output_hook(message: dict[str, Any]) -> None:
            self._route_output(execution, message)

        async def stdin_hook(message: dict[str, Any]) -> None:
            content = message.get("content", {})
            loop = asyncio.get_running_loop()
            waiter: asyncio.Future[str] = loop.create_future()
            self.stdin_waiters[execution.execution_id] = waiter
            self.execution_event(
                "execution.stdin_request",
                execution,
                {
                    "prompt": str(content.get("prompt", "")),
                    "password": bool(content.get("password", False)),
                },
            )
            self.execution_event(
                "execution.state", execution, {"state": "waiting_input"}
            )
            value = await waiter
            self.client.input(value)
            self.execution_event("execution.state", execution, {"state": "running"})

        try:
            reply = await self.client.execute_interactive(
                execution.code,
                allow_stdin=execution.allow_stdin,
                stop_on_error=execution.stop_on_error,
                output_hook=output_hook,
                stdin_hook=stdin_hook,
                timeout=None,
            )
            content = reply.get("content", {})
            if execution.cancelled:
                state = "cancelled"
            elif execution.saw_error or content.get("status") == "error":
                state = "failed"
            else:
                state = "completed"
            execution.terminal = True
            self.execution_event(
                "execution.state",
                execution,
                {
                    "state": state,
                    "execution_count": content.get("execution_count"),
                },
            )
        except asyncio.CancelledError:
            if not execution.terminal:
                execution.terminal = True
                self.execution_event(
                    "execution.state", execution, {"state": "cancelled"}
                )
            raise
        except Exception as exc:
            if not await self.manager.is_alive():
                self._mark_dead(str(exc), execution)
            else:
                execution.terminal = True
                self.execution_event(
                    "execution.error",
                    execution,
                    {
                        "ename": type(exc).__name__,
                        "evalue": str(exc),
                        "traceback": [],
                        "transport": True,
                    },
                )
                self.execution_event("execution.state", execution, {"state": "failed"})
        finally:
            self.stdin_waiters.pop(execution.execution_id, None)

    @staticmethod
    def _widget_state(value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            return {}
        allowed = {
            "_data_url",
            "_figure_label",
            "_model_module",
            "_model_name",
            "_options_labels",
            "_size",
            "bar_style",
            "button_style",
            "children",
            "description",
            "disabled",
            "icon",
            "index",
            "max",
            "min",
            "orientation",
            "placeholder",
            "readout_format",
            "step",
            "tooltip",
            "value",
        }
        result: dict[str, Any] = {}
        for key in allowed:
            if key not in value:
                continue
            item = value[key]
            if isinstance(item, str):
                result[key] = (
                    item[: 10 * 1024 * 1024] if key == "_data_url" else item[:4096]
                )
            elif isinstance(item, (int, float, bool)) or item is None:
                result[key] = item
            elif key == "children" and isinstance(item, list):
                result[key] = [str(child)[:256] for child in item[:64]]
            elif key == "_options_labels" and isinstance(item, (list, tuple)):
                result[key] = [str(option)[:256] for option in item[:256]]
            elif key == "_size" and isinstance(item, (list, tuple)):
                result[key] = [
                    min(32768.0, max(1.0, float(size)))
                    for size in item[:2]
                    if isinstance(size, (int, float))
                    and not isinstance(size, bool)
                    and math.isfinite(float(size))
                ]
        return result

    def _route_output(self, execution: Execution, message: dict[str, Any]) -> None:
        message_type = message.get("msg_type") or message.get("header", {}).get(
            "msg_type"
        )
        content = message.get("content", {})
        if message_type == "status" and content.get("execution_state") == "busy":
            self.execution_event("execution.state", execution, {"state": "running"})
            return
        if message_type == "execute_input":
            self.execution_event(
                "execution.state",
                execution,
                {"state": "running", "execution_count": content.get("execution_count")},
            )
            return
        if message_type == "comm_open":
            model_id = str(content.get("comm_id", ""))
            target_name = str(content.get("target_name", ""))
            if model_id and target_name == "jupyter.widget":
                self.widget_comm_ids.add(model_id)
                data = content.get("data", {})
                self.execution_event(
                    "execution.widget",
                    execution,
                    {
                        "action": "open",
                        "model_id": model_id,
                        "state": self._widget_state(data.get("state", {})),
                    },
                )
            return
        if message_type == "comm_msg":
            model_id = str(content.get("comm_id", ""))
            if model_id in self.widget_comm_ids:
                data = content.get("data", {})
                self.execution_event(
                    "execution.widget",
                    execution,
                    {
                        "action": "update",
                        "model_id": model_id,
                        "method": str(data.get("method", ""))[:64],
                        "state": self._widget_state(data.get("state", {})),
                    },
                )
            return
        if message_type == "comm_close":
            model_id = str(content.get("comm_id", ""))
            if model_id in self.widget_comm_ids:
                self.widget_comm_ids.discard(model_id)
                self.execution_event(
                    "execution.widget",
                    execution,
                    {"action": "close", "model_id": model_id, "state": {}},
                )
            return
        if message_type == "stream":
            execution.stream_index += 1
            self.execution_event(
                "execution.stream",
                execution,
                {
                    "index": execution.stream_index,
                    "name": content.get("name", "stdout"),
                    "text": content.get("text", ""),
                },
            )
            return
        if message_type in {"display_data", "execute_result"}:
            execution.stream_index += 1
            self.execution_event(
                "execution.display",
                execution,
                {
                    "index": execution.stream_index,
                    "output_type": message_type,
                    "data": content.get("data", {}),
                    "metadata": content.get("metadata", {}),
                    "transient": content.get("transient", {}),
                    "execution_count": content.get("execution_count"),
                },
            )
            return
        if message_type == "update_display_data":
            execution.stream_index += 1
            self.execution_event(
                "execution.display_update",
                execution,
                {
                    "index": execution.stream_index,
                    "data": content.get("data", {}),
                    "metadata": content.get("metadata", {}),
                    "transient": content.get("transient", {}),
                },
            )
            return
        if message_type == "clear_output":
            self.execution_event(
                "execution.clear_output",
                execution,
                {"wait": bool(content.get("wait", False))},
            )
            return
        if message_type == "error":
            execution.saw_error = True
            self.execution_event(
                "execution.error",
                execution,
                {
                    "ename": content.get("ename", "Error"),
                    "evalue": content.get("evalue", ""),
                    "traceback": content.get("traceback", []),
                },
            )


class SidecarServer:
    def __init__(self) -> None:
        self.sequence = 0
        self.running = True
        self.sessions: dict[str, KernelSession] = {}
        self.contents_client: RemoteContentsClient | None = None
        self.contents_identity: tuple[Any, ...] | None = None

    def send(self, message: dict[str, Any]) -> None:
        self.sequence += 1
        message = {"protocol": PROTOCOL, "seq": self.sequence, **message}
        sys.stdout.write(json.dumps(message, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()

    def event(
        self,
        event_type: str,
        *,
        payload: dict[str, Any],
        notebook_id: str | None = None,
        cell_id: str | None = None,
        revision: int | None = None,
    ) -> None:
        message: dict[str, Any] = {
            "kind": "event",
            "type": event_type,
            "payload": payload,
        }
        if notebook_id:
            message["notebook_id"] = notebook_id
        if cell_id:
            message["cell_id"] = cell_id
        if revision is not None:
            message["revision"] = revision
        self.send(message)

    def log(self, level: str, message: str) -> None:
        self.event("log", payload={"level": level, "message": message})

    def response(
        self,
        request: dict[str, Any],
        payload: dict[str, Any] | None = None,
        error: dict[str, Any] | None = None,
    ) -> None:
        message: dict[str, Any] = {
            "kind": "response",
            "type": request.get("type", "sidecar.invalid"),
            "id": request.get("id", "missing-id"),
            "payload": payload or {},
        }
        for field_name in ("notebook_id", "cell_id", "revision"):
            if field_name in request:
                message[field_name] = request[field_name]
        if error:
            message["error"] = error
        self.send(message)

    @staticmethod
    def _read_stdin_line() -> tuple[bytes, bool]:
        line = sys.stdin.buffer.readline(MAX_MESSAGE_BYTES + 2)
        if not line:
            return b"", False
        oversized = len(line) > MAX_MESSAGE_BYTES or not line.endswith(b"\n")
        if oversized and not line.endswith(b"\n"):
            while True:
                remainder = sys.stdin.buffer.readline(MAX_MESSAGE_BYTES + 2)
                if not remainder or remainder.endswith(b"\n"):
                    break
        return line, oversized

    async def run(self) -> None:
        while self.running:
            line, oversized = await asyncio.to_thread(self._read_stdin_line)
            if not line:
                break
            if oversized:
                self.log(
                    "error",
                    f"invalid request: message exceeds {MAX_MESSAGE_BYTES} bytes",
                )
                continue
            try:
                message = json.loads(line)
                self._validate_request(message)
            except Exception as exc:
                self.send(
                    {
                        "kind": "event",
                        "type": "log",
                        "payload": {
                            "level": "error",
                            "message": f"invalid request: {exc}",
                        },
                    }
                )
                continue
            await self._dispatch(message)
        await self.close()

    @staticmethod
    def _validate_request(message: dict[str, Any]) -> None:
        if message.get("protocol") != PROTOCOL:
            raise ValueError("unsupported protocol")
        if message.get("kind") != "request":
            raise ValueError("expected request")
        if not isinstance(message.get("id"), str) or not message["id"]:
            raise ValueError("request id is required")
        if not isinstance(message.get("type"), str):
            raise ValueError("request type is required")
        if not isinstance(message.get("payload"), dict):
            raise ValueError("request payload must be an object")

    async def _dispatch(self, request: dict[str, Any]) -> None:
        try:
            handler_name = "_handle_" + request["type"].replace(".", "_")
            handler = getattr(self, handler_name, None)
            if handler is None:
                self.response(
                    request,
                    error={
                        "code": "unsupported_message",
                        "message": f"unsupported request type {request['type']}",
                        "retryable": False,
                    },
                )
                return
            payload = handler(request)
            if inspect.isawaitable(payload):
                payload = await payload
            if payload is not None:
                self.response(request, payload)
        except Exception as exc:
            details: dict[str, Any] = {}
            if os.environ.get("NVJUP_DEBUG"):
                details["traceback"] = traceback.format_exc()
            self.response(
                request,
                error={
                    "code": self._error_code(request["type"]),
                    "message": str(exc) or type(exc).__name__,
                    "retryable": request["type"] in {"kernel.start", "kernel.restart"},
                    "details": details,
                },
            )

    @staticmethod
    def _error_code(request_type: str) -> str:
        return request_type.replace(".", "_") + "_failed"

    def _session(self, request: dict[str, Any]) -> KernelSession:
        notebook_id = request.get("notebook_id")
        if not notebook_id or notebook_id not in self.sessions:
            raise ValueError("notebook has no live kernel")
        return self.sessions[notebook_id]

    def _handle_sidecar_hello(self, request: dict[str, Any]) -> dict[str, Any]:
        return {
            "version": VERSION,
            "protocols": [PROTOCOL],
            "capabilities": {
                "transports": ["local", "jupyter_server"],
                "requests": [
                    "kernel.list",
                    "kernel.start",
                    "kernel.interrupt",
                    "kernel.restart",
                    "kernel.shutdown",
                    "execution.enqueue",
                    "execution.cancel",
                    "execution.stdin_reply",
                    "completion.request",
                    "inspect.request",
                    "variables.list",
                    "remote.server.probe",
                    "remote.files.list",
                    "remote.files.stat",
                    "remote.files.mkdir",
                    "remote.files.touch",
                    "remote.files.rename",
                    "remote.files.delete",
                    "remote.files.download",
                    "remote.files.upload",
                    "remote.files.download_to",
                    "remote.files.upload_from",
                    "remote.files.copy",
                ],
                "events": [
                    "kernel.state",
                    "kernel.dead",
                    "execution.state",
                    "execution.stream",
                    "execution.display",
                    "execution.display_update",
                    "execution.clear_output",
                    "execution.error",
                    "execution.stdin_request",
                    "execution.widget",
                ],
            },
        }

    def _handle_sidecar_ping(self, request: dict[str, Any]) -> dict[str, Any]:
        return {"pong": True}

    async def _handle_sidecar_shutdown(self, request: dict[str, Any]) -> dict[str, Any]:
        self.running = False
        await self.close()
        return {"stopped": True}

    def _handle_kernel_list(self, request: dict[str, Any]) -> dict[str, Any]:
        specs = KernelSpecManager().get_all_specs()
        return {
            "kernels": [
                {
                    "name": name,
                    "display_name": value.get("spec", {}).get("display_name", name),
                    "language": value.get("spec", {}).get("language", ""),
                    "resource_dir": value.get("resource_dir", ""),
                }
                for name, value in sorted(specs.items())
            ]
        }

    @staticmethod
    async def _validate_kernel_python(python_path: str) -> str:
        resolved = os.path.abspath(os.path.expanduser(python_path))
        # Do not realpath a virtualenv's Python symlink: CPython uses the
        # executable location to discover pyvenv.cfg and site-packages.
        if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
            raise ValueError(f"kernel Python is not executable: {python_path}")
        process = await asyncio.create_subprocess_exec(
            resolved,
            "-c",
            "import ipykernel,sys; print(sys.executable)",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=10)
        if process.returncode != 0:
            detail = stderr.decode("utf-8", "replace").strip().splitlines()
            suffix = f": {detail[-1]}" if detail else ""
            raise ValueError(f"ipykernel is unavailable in {resolved}{suffix}")
        reported = stdout.decode("utf-8", "replace").strip().splitlines()
        return os.path.abspath(reported[-1]) if reported else resolved

    async def _handle_kernel_start(self, request: dict[str, Any]) -> dict[str, Any]:
        notebook_id = request.get("notebook_id")
        if not notebook_id:
            raise ValueError("notebook_id is required")
        existing = self.sessions.get(notebook_id)
        if existing and existing.state not in {"stopped", "dead"}:
            return {
                "state": existing.state,
                "kernel_name": existing.kernel_name,
                "generation": existing.generation,
                "python_path": existing.python_path,
                "python_source": existing.python_source,
                "transport": existing.transport,
            }
        if existing:
            with contextlib.suppress(Exception):
                await existing.shutdown(now=True)
            self.sessions.pop(notebook_id, None)
        kernel_name = str(request["payload"].get("kernel_name") or "python3")
        python_path = request["payload"].get("python_path")
        python_source = str(request["payload"].get("python_source") or "kernelspec")
        remote = request["payload"].get("remote")
        transport = (
            "remote" if isinstance(remote, dict) and remote.get("url") else "local"
        )
        self.event(
            "kernel.state",
            notebook_id=notebook_id,
            payload={"state": "starting", "generation": 1, "transport": transport},
        )
        if transport == "remote":
            assert isinstance(remote, dict)
            python_path = None
            python_source = "remote"
            manager = await RemoteKernelManager.create(
                base_url=str(remote["url"]),
                token=str(remote.get("token") or ""),
                verify_ssl=bool(remote.get("verify_ssl", True)),
                origin=str(remote["origin"]) if remote.get("origin") else None,
                timeout=float(request["payload"].get("timeout", 30)),
                reconnect_attempts=int(remote.get("reconnect_attempts", 2)),
                kernel_name=kernel_name,
                provider=str(remote.get("provider") or "jupyter"),
            )
            client = manager.client()
        else:
            manager = AsyncKernelManager(kernel_name=kernel_name)
            if python_path:
                python_path = await self._validate_kernel_python(str(python_path))
                manager._kernel_spec = KernelSpec(
                    argv=[
                        python_path,
                        "-m",
                        "ipykernel_launcher",
                        "-f",
                        "{connection_file}",
                    ],
                    display_name=f"Python ({python_path})",
                    language="python",
                    name="nvjup-project-python",
                )
            await manager.start_kernel(cwd=request["payload"].get("cwd"))
            client = manager.client()
            client.start_channels()
        try:
            await client.wait_for_ready(
                timeout=float(request["payload"].get("timeout", 30))
            )
        except Exception:
            client.stop_channels()
            await manager.shutdown_kernel(now=True)
            raise
        session = KernelSession(
            self,
            notebook_id,
            kernel_name,
            manager,
            client,
            python_path=python_path,
            python_source=python_source,
            transport=transport,
            state="idle",
        )
        self.sessions[notebook_id] = session
        session.start_tasks()
        session.emit_state("idle")
        return {
            "state": "idle",
            "kernel_name": kernel_name,
            "generation": 1,
            "python_path": python_path,
            "python_source": python_source,
            "transport": transport,
        }

    async def _handle_kernel_interrupt(self, request: dict[str, Any]) -> dict[str, Any]:
        session = self._session(request)
        session.emit_state("interrupting")
        if session.active:
            waiter = session.stdin_waiters.pop(session.active.execution_id, None)
            if waiter and not waiter.done():
                waiter.set_result("")
        await session.manager.interrupt_kernel()
        return {"state": "interrupting", "generation": session.generation}

    async def _handle_kernel_restart(self, request: dict[str, Any]) -> dict[str, Any]:
        session = self._session(request)
        await session.restart()
        return {
            "state": "idle",
            "generation": session.generation,
            "python_path": session.python_path,
            "python_source": session.python_source,
            "transport": session.transport,
        }

    async def _handle_kernel_shutdown(self, request: dict[str, Any]) -> dict[str, Any]:
        session = self._session(request)
        await session.shutdown(now=bool(request["payload"].get("now", False)))
        self.sessions.pop(session.notebook_id, None)
        return {"state": "stopped"}

    async def _handle_execution_enqueue(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        session = self._session(request)
        if session.state in {"dead", "stopped", "shutting_down", "restarting"}:
            raise ValueError(f"kernel cannot execute while {session.state}")
        payload = request["payload"]
        execution_id = str(payload.get("execution_id") or uuid.uuid4())
        if execution_id in session.executions:
            raise ValueError("duplicate execution_id")
        execution = Execution(
            execution_id=execution_id,
            cell_id=str(request.get("cell_id") or payload.get("cell_id") or ""),
            revision=int(request.get("revision", payload.get("revision", 0))),
            code=str(payload.get("code", "")),
            allow_stdin=bool(payload.get("allow_stdin", True)),
            stop_on_error=bool(payload.get("stop_on_error", True)),
        )
        if not execution.cell_id:
            raise ValueError("cell_id is required")
        await session.enqueue(execution)
        return {"execution_id": execution_id, "state": "queued"}

    async def _handle_execution_cancel(self, request: dict[str, Any]) -> dict[str, Any]:
        session = self._session(request)
        execution_id = str(request["payload"].get("execution_id", ""))
        return {
            "execution_id": execution_id,
            "cancelled": await session.cancel(execution_id),
        }

    async def _handle_execution_stdin_reply(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        session = self._session(request)
        execution_id = str(request["payload"].get("execution_id", ""))
        accepted = await session.reply_stdin(
            execution_id, str(request["payload"].get("value", ""))
        )
        return {"execution_id": execution_id, "accepted": accepted}

    async def _handle_completion_request(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        session = self._session(request)
        code = str(request["payload"].get("code", ""))
        if len(code.encode("utf-8")) > 1_000_000:
            raise ValueError("completion code exceeds 1 MB")
        cursor = int(request["payload"].get("cursor_pos", len(code)))
        cursor = max(0, min(cursor, len(code)))
        message_id = session.client.complete(code=code, cursor_pos=cursor)
        reply = await session.shell_reply(
            message_id, float(request["payload"].get("timeout", 5.0))
        )
        content = reply.get("content", {})
        matches = content.get("matches", [])
        return {
            "status": str(content.get("status", "ok")),
            "matches": [str(match)[:4096] for match in matches[:512]],
            "cursor_start": int(content.get("cursor_start", cursor)),
            "cursor_end": int(content.get("cursor_end", cursor)),
            "metadata": {},
        }

    async def _handle_inspect_request(self, request: dict[str, Any]) -> dict[str, Any]:
        session = self._session(request)
        code = str(request["payload"].get("code", ""))
        if len(code.encode("utf-8")) > 1_000_000:
            raise ValueError("inspection code exceeds 1 MB")
        cursor = int(request["payload"].get("cursor_pos", len(code)))
        cursor = max(0, min(cursor, len(code)))
        detail_level = max(0, min(int(request["payload"].get("detail_level", 0)), 1))
        message_id = session.client.inspect(
            code=code, cursor_pos=cursor, detail_level=detail_level
        )
        reply = await session.shell_reply(
            message_id, float(request["payload"].get("timeout", 5.0))
        )
        content = reply.get("content", {})
        raw_data = content.get("data", {})
        data: dict[str, str] = {}
        remaining = 1024 * 1024
        if isinstance(raw_data, dict):
            for mime, value in list(raw_data.items())[:16]:
                if remaining <= 0:
                    break
                if isinstance(value, list):
                    value = "".join(str(part) for part in value)
                elif not isinstance(value, str):
                    value = str(value)
                encoded = value.encode("utf-8")[:remaining]
                bounded = encoded.decode("utf-8", "ignore")
                data[str(mime)[:256]] = bounded
                remaining -= len(bounded.encode("utf-8"))
        return {
            "status": str(content.get("status", "ok")),
            "found": bool(content.get("found", False)),
            "data": data,
            "metadata": {},
        }

    async def _handle_variables_list(self, request: dict[str, Any]) -> dict[str, Any]:
        session = self._session(request)
        limit = max(1, min(int(request["payload"].get("limit", 200)), 500))
        expression = (
            "__import__('json').dumps(["
            "{'name':n,'type':type(v).__name__,'value':"
            "(repr(v)[:240] if type(v) in (str,int,float,bool,type(None),complex) "
            "else '<'+type(v).__name__+'>')} "
            "for n,v in list(globals().items()) if not n.startswith('_')][:"
            + str(limit)
            + "],ensure_ascii=False)"
        )
        message_id = session.client.execute(
            "",
            silent=True,
            store_history=False,
            allow_stdin=False,
            user_expressions={"nvjup_variables": expression},
        )
        reply = await session.shell_reply(
            message_id, float(request["payload"].get("timeout", 5.0))
        )
        content = reply.get("content", {})
        result = content.get("user_expressions", {}).get("nvjup_variables", {})
        if result.get("status") != "ok":
            raise RuntimeError(
                str(result.get("evalue") or "variable inspection failed")
            )
        encoded = result.get("data", {}).get("text/plain", "''")
        try:
            variables = json.loads(ast.literal_eval(str(encoded)))
        except (SyntaxError, ValueError, TypeError, json.JSONDecodeError) as exc:
            raise RuntimeError("kernel returned invalid variable data") from exc
        if not isinstance(variables, list):
            raise RuntimeError("kernel returned invalid variable list")
        return {"variables": variables[:limit], "generation": session.generation}

    async def _contents_client(self, request: dict[str, Any]) -> RemoteContentsClient:
        payload = request["payload"]
        remote = payload.get("remote")
        if not isinstance(remote, dict) or not remote.get("url"):
            raise ValueError("remote Jupyter Server configuration is required")
        identity = (
            str(remote["url"]),
            str(remote.get("token") or ""),
            bool(remote.get("verify_ssl", True)),
            str(remote["origin"]) if remote.get("origin") else None,
            float(remote.get("file_timeout_seconds", 60)),
            int(remote.get("max_file_bytes", 64 * 1024 * 1024)),
            int(remote.get("max_entries", 10_000)),
            str(remote.get("provider") or "jupyter"),
        )
        if self.contents_client and self.contents_identity != identity:
            await self.contents_client.close()
            self.contents_client = None
        if self.contents_client is None:
            self.contents_client = RemoteContentsClient(
                base_url=identity[0],
                token=identity[1],
                verify_ssl=identity[2],
                origin=identity[3],
                timeout=identity[4],
                max_file_bytes=identity[5],
                max_entries=identity[6],
                provider=identity[7],
            )
            self.contents_identity = identity
        return self.contents_client

    async def _handle_remote_server_probe(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        return await client.server_info()

    async def _handle_remote_files_list(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        return await client.list(str(request["payload"].get("path", "")))

    async def _handle_remote_files_stat(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        return await client.stat(str(request["payload"].get("path", "")))

    async def _handle_remote_files_mkdir(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        return await client.mkdir(str(request["payload"].get("path", "")))

    async def _handle_remote_files_touch(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        return await client.touch(str(request["payload"].get("path", "")))

    async def _handle_remote_files_rename(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        return await client.rename(
            str(request["payload"].get("path", "")),
            str(request["payload"].get("new_path", "")),
        )

    async def _handle_remote_files_delete(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        await client.delete(str(request["payload"].get("path", "")))
        return {"deleted": True}

    async def _handle_remote_files_download(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        content = await client.download(str(request["payload"].get("path", "")))
        return {
            "content": base64.b64encode(content).decode("ascii"),
            "encoding": "base64",
            "size": len(content),
        }

    async def _handle_remote_files_download_to(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        target = str(request["payload"].get("local_path", ""))
        if not target or os.path.lexists(target):
            raise ValueError("download target must be a new local path")
        requested_limit = request["payload"].get("max_bytes")
        limit = client.max_file_bytes
        if requested_limit is not None:
            if (
                not isinstance(requested_limit, int)
                or isinstance(requested_limit, bool)
                or requested_limit < 0
            ):
                raise ValueError("download byte limit must be a non-negative integer")
            limit = min(limit, requested_limit)
        content = await client.download(
            str(request["payload"].get("path", "")), max_bytes=limit
        )
        created = False

        def write_new() -> None:
            nonlocal created
            with open(target, "xb") as stream:
                created = True
                stream.write(content)

        try:
            await asyncio.to_thread(write_new)
        except BaseException:
            if created:
                with contextlib.suppress(OSError):
                    os.unlink(target)
            raise
        return {"size": len(content), "local_path": target}

    async def _handle_remote_files_upload_from(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        source = str(request["payload"].get("local_path", ""))
        requested_limit = request["payload"].get("max_bytes")
        limit = client.max_file_bytes
        if requested_limit is not None:
            if (
                not isinstance(requested_limit, int)
                or isinstance(requested_limit, bool)
                or requested_limit < 0
            ):
                raise ValueError("upload byte limit must be a non-negative integer")
            limit = min(limit, requested_limit)

        def read_source() -> bytes:
            with open(source, "rb") as stream:
                source_stat = os.fstat(stream.fileno())
                if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_size > limit:
                    raise ValueError(
                        "local upload source is not a bounded regular file"
                    )
                content = stream.read(limit + 1)
                if len(content) > limit:
                    raise ValueError(f"file exceeds {limit} bytes")
                return content

        content = await asyncio.to_thread(read_source)
        result = await client.upload(str(request["payload"].get("path", "")), content)
        result["size"] = len(content)
        return result

    async def _handle_remote_files_copy(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        client = await self._contents_client(request)
        content = await client.download(str(request["payload"].get("path", "")))
        return await client.upload(str(request["payload"].get("new_path", "")), content)

    async def _handle_remote_files_upload(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        encoded = request["payload"].get("content")
        if not isinstance(encoded, str):
            raise ValueError("base64 file content is required")
        remote = request["payload"].get("remote")
        max_bytes = (
            int(remote.get("max_file_bytes", 64 * 1024 * 1024))
            if isinstance(remote, dict)
            else 0
        )
        max_bytes = max(1, min(max_bytes, 512 * 1024 * 1024))
        if len(encoded) > ((max_bytes + 2) // 3) * 4:
            raise ValueError(f"file exceeds {max_bytes} bytes")
        try:
            content = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise ValueError("invalid base64 file content") from exc
        client = await self._contents_client(request)
        return await client.upload(str(request["payload"].get("path", "")), content)

    async def close(self) -> None:
        sessions = list(self.sessions.values())
        self.sessions.clear()
        for session in sessions:
            with contextlib.suppress(Exception):
                await session.shutdown(now=True)
        if self.contents_client:
            with contextlib.suppress(Exception):
                await self.contents_client.close()
            self.contents_client = None
            self.contents_identity = None


async def async_main() -> None:
    server = SidecarServer()
    await server.run()


def main() -> None:
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
