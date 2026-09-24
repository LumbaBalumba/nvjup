from __future__ import annotations

import base64
import json
import os
import queue
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

import pytest

ROOT = Path(__file__).resolve().parents[2]
SIDECAR = ROOT / "python" / "nvjup_sidecar_main.py"
sys.path.insert(0, str(ROOT / "python"))

from nvjup_sidecar.remote import _deserialize_v1, _serialize_v1  # noqa: E402
from nvjup_sidecar.server import Execution, KernelSession  # noqa: E402


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
