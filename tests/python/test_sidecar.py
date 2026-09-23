from __future__ import annotations

import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

import pytest

ROOT = Path(__file__).resolve().parents[2]
SIDECAR = ROOT / "python" / "nvjup_sidecar_main.py"


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


def test_sidecar_kernel_lifecycle_and_execution_routing(
    sidecar: SidecarProcess,
) -> None:
    notebook_id = "notebook-integration"

    hello = sidecar.response(sidecar.send("sidecar.hello"))
    assert hello["payload"]["protocols"] == ["nvjup/1"]
    kernels = sidecar.response(sidecar.send("kernel.list"))
    assert any(item["name"] == "python3" for item in kernels["payload"]["kernels"])

    started = sidecar.response(
        sidecar.send(
            "kernel.start",
            {"kernel_name": "python3", "cwd": str(ROOT), "timeout": 30},
            notebook_id=notebook_id,
        ),
        timeout=40,
    )
    assert started["payload"]["state"] == "idle"

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
