#!/usr/bin/env python3
"""Generate deterministic Stage 0 notebook and protocol fixtures."""

from __future__ import annotations

import base64
import json
import struct
import zlib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
NOTEBOOKS = ROOT / "tests" / "fixtures" / "notebooks"
MESSAGES = ROOT / "tests" / "fixtures" / "messages"


def png(width: int, height: int, rgba: tuple[int, int, int, int]) -> str:
    """Return a base64 RGBA PNG without external dependencies."""

    def chunk(name: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + name
            + data
            + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)
        )

    row = b"\x00" + bytes(rgba) * width
    raw = row * height
    image = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, level=9))
        + chunk(b"IEND", b"")
    )
    return base64.b64encode(image).decode("ascii")


def notebook(
    cells: list[dict[str, Any]], metadata: dict[str, Any] | None = None
) -> dict[str, Any]:
    base_metadata: dict[str, Any] = {
        "kernelspec": {
            "display_name": "Python 3",
            "language": "python",
            "name": "python3",
        },
        "language_info": {
            "name": "python",
            "version": "3.12",
            "mimetype": "text/x-python",
            "codemirror_mode": {"name": "ipython", "version": 3},
            "pygments_lexer": "ipython3",
            "nbconvert_exporter": "python",
            "file_extension": ".py",
        },
    }
    if metadata:
        base_metadata.update(metadata)
    return {
        "cells": cells,
        "metadata": base_metadata,
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def code(
    cell_id: str,
    source: str,
    *,
    execution_count: int | None = None,
    outputs: list[dict[str, Any]] | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "cell_type": "code",
        "execution_count": execution_count,
        "id": cell_id,
        "metadata": metadata or {},
        "outputs": outputs or [],
        "source": source,
    }


def markdown(
    cell_id: str,
    source: str,
    *,
    attachments: dict[str, Any] | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    cell: dict[str, Any] = {
        "cell_type": "markdown",
        "id": cell_id,
        "metadata": metadata or {},
        "source": source,
    }
    if attachments is not None:
        cell["attachments"] = attachments
    return cell


def raw(
    cell_id: str, source: str, metadata: dict[str, Any] | None = None
) -> dict[str, Any]:
    return {
        "cell_type": "raw",
        "id": cell_id,
        "metadata": metadata or {},
        "source": source,
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )


def rpc(
    seq: int,
    kind: str,
    message_type: str,
    payload: dict[str, Any],
    *,
    message_id: str | None = None,
    notebook_id: str = "notebook-fixture",
    cell_id: str | None = "cell-fixture",
    revision: int | None = 1,
) -> dict[str, Any]:
    message: dict[str, Any] = {
        "protocol": "nvjup/1",
        "kind": kind,
        "type": message_type,
        "seq": seq,
        "notebook_id": notebook_id,
        "payload": payload,
    }
    if message_id is not None:
        message["id"] = message_id
    if cell_id is not None:
        message["cell_id"] = cell_id
    if revision is not None:
        message["revision"] = revision
    return message


def write_jsonl(path: Path, messages: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(
        json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n"
        for message in messages
    )
    path.write_text(text, encoding="utf-8")


def generate_notebooks() -> dict[str, list[str]]:
    blue_png = png(4, 3, (76, 114, 176, 255))
    red_png = png(2, 2, (220, 50, 47, 255))

    fixtures: dict[str, tuple[dict[str, Any], list[str]]] = {
        "00_minimal.ipynb": (
            notebook([code("minimal-code", "answer = 42\nanswer\n")]),
            ["code_cells"],
        ),
        "01_markdown_code.ipynb": (
            notebook(
                [
                    markdown(
                        "intro-markdown",
                        "# Анализ данных 📊\n\nMarkdown with **bold**, $x^2$, and an attachment.\n\n![pixel](attachment:pixel.png)\n",
                        attachments={"pixel.png": {"image/png": red_png}},
                    ),
                    code(
                        "imports-code",
                        "import numpy as np\nvalues = np.array([1, 2, 3])\n",
                    ),
                    code(
                        "result-code",
                        "values.mean()\n",
                        execution_count=1,
                        outputs=[
                            {
                                "data": {"text/plain": "2.0"},
                                "execution_count": 1,
                                "metadata": {},
                                "output_type": "execute_result",
                            }
                        ],
                    ),
                    raw("raw-cell", "This raw cell must be preserved verbatim.\n"),
                ]
            ),
            ["markdown", "code_cells", "attachments", "unicode", "raw_cells"],
        ),
        "02_stream_error.ipynb": (
            notebook(
                [
                    code(
                        "stream-cell",
                        "print('first')\nprint('second')\n",
                        execution_count=2,
                        outputs=[
                            {
                                "name": "stdout",
                                "output_type": "stream",
                                "text": "first\nsecond\n",
                            },
                            {
                                "name": "stderr",
                                "output_type": "stream",
                                "text": "warning\n",
                            },
                        ],
                    ),
                    code(
                        "error-cell",
                        "raise ValueError('boom')\n",
                        execution_count=3,
                        outputs=[
                            {
                                "ename": "ValueError",
                                "evalue": "boom",
                                "output_type": "error",
                                "traceback": [
                                    "\u001b[31m---------------------------------------------------------------------------\u001b[39m",
                                    "\u001b[31mValueError\u001b[39m: boom",
                                ],
                            }
                        ],
                    ),
                ]
            ),
            ["streams", "errors", "ansi"],
        ),
        "03_rich_outputs.ipynb": (
            notebook(
                [
                    code(
                        "rich-output",
                        "display_rich_outputs()\n",
                        execution_count=4,
                        outputs=[
                            {
                                "data": {
                                    "text/plain": "<matplotlib.figure.Figure>",
                                    "image/png": blue_png,
                                },
                                "metadata": {
                                    "image/png": {"width": 320, "height": 240}
                                },
                                "output_type": "display_data",
                            },
                            {
                                "data": {
                                    "text/plain": "vector graphic",
                                    "image/svg+xml": '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="20"><rect width="80" height="20" fill="#2aa198"/></svg>',
                                },
                                "metadata": {},
                                "output_type": "display_data",
                            },
                            {
                                "data": {
                                    "text/plain": "a  b\\n1  2",
                                    "text/html": "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>",
                                    "text/latex": "\\\\begin{array}{cc}a&b\\\\1&2\\\\end{array}",
                                },
                                "metadata": {},
                                "output_type": "display_data",
                            },
                        ],
                    )
                ]
            ),
            ["matplotlib", "png", "svg", "html", "latex", "mime_priority"],
        ),
        "04_persisted_display.ipynb": (
            notebook(
                [
                    code(
                        "display-cell",
                        "from IPython.display import display\nhandle = display('final', display_id=True)\n",
                        execution_count=5,
                        outputs=[
                            {
                                "data": {"text/plain": "'final'"},
                                "metadata": {
                                    "nvjup_fixture": {
                                        "represents": "final display_id state"
                                    }
                                },
                                "output_type": "display_data",
                            }
                        ],
                    )
                ]
            ),
            ["persisted_display", "display_updates"],
        ),
        "05_plotly.ipynb": (
            notebook(
                [
                    code(
                        "plotly-cell",
                        "plotly_figure\n",
                        execution_count=6,
                        outputs=[
                            {
                                "data": {
                                    "text/plain": "Figure({data: [Scatter(x=[1, 2, 3], y=[1, 4, 9])]})",
                                    "application/vnd.plotly.v1+json": {
                                        "data": [
                                            {
                                                "type": "scatter",
                                                "mode": "lines+markers",
                                                "x": [1, 2, 3],
                                                "y": [1, 4, 9],
                                                "name": "quadratic",
                                            }
                                        ],
                                        "layout": {
                                            "title": {"text": "Plotly fixture"},
                                            "width": 640,
                                            "height": 360,
                                        },
                                        "config": {
                                            "displayModeBar": True,
                                            "responsive": True,
                                        },
                                    },
                                },
                                "metadata": {},
                                "output_type": "display_data",
                            }
                        ],
                    )
                ]
            ),
            ["plotly", "interactive_mime", "text_fallback"],
        ),
        "06_bokeh.ipynb": (
            notebook(
                [
                    code(
                        "bokeh-cell",
                        "bokeh_document\n",
                        execution_count=7,
                        outputs=[
                            {
                                "data": {
                                    "text/plain": "Bokeh Application",
                                    "application/vnd.bokehjs_exec.v0+json": {
                                        "doc": {
                                            "version": "3.0.0",
                                            "title": "Bokeh fixture",
                                            "roots": [],
                                        },
                                        "render_items": [],
                                    },
                                },
                                "metadata": {},
                                "output_type": "display_data",
                            }
                        ],
                    )
                ]
            ),
            ["bokeh", "interactive_mime", "text_fallback"],
        ),
        "07_unknown_metadata.ipynb": (
            notebook(
                [
                    markdown(
                        "unknown-markdown",
                        "Preserve extension metadata.\n",
                        metadata={
                            "vendor.example/cell": {
                                "enabled": True,
                                "nested": [1, {"x": "y"}],
                            }
                        },
                    ),
                    code(
                        "unknown-code",
                        "custom_result\n",
                        execution_count=8,
                        metadata={"tags": ["keep-me"], "vendor.example/code": "opaque"},
                        outputs=[
                            {
                                "data": {
                                    "text/plain": "custom result",
                                    "application/vnd.example.widget+json": {
                                        "model": "opaque",
                                        "state": {"value": 7},
                                    },
                                },
                                "metadata": {"vendor.example/output": {"keep": True}},
                                "output_type": "display_data",
                            }
                        ],
                    ),
                ],
                metadata={
                    "vendor.example/notebook": {"version": 9, "opaque": ["a", "b"]}
                },
            ),
            ["unknown_metadata", "unknown_mime", "lossless_round_trip"],
        ),
        "08_large_output.ipynb": (
            notebook(
                [
                    code(
                        "large-output",
                        "for i in range(1000):\n    print(f'line {i:04d}')\n",
                        execution_count=9,
                        outputs=[
                            {
                                "name": "stdout",
                                "output_type": "stream",
                                "text": "".join(
                                    f"line {index:04d} — данные\n"
                                    for index in range(1000)
                                ),
                            }
                        ],
                    )
                ]
            ),
            ["large_output", "unicode", "stream_truncation"],
        ),
        "09_lsp_mapping.ipynb": (
            notebook(
                [
                    markdown(
                        "lsp-heading",
                        "# LSP mapping\n\nMarkdown between code cells must not shift diagnostics incorrectly.\n",
                    ),
                    code(
                        "lsp-definitions",
                        "from dataclasses import dataclass\n\n@dataclass\nclass Точка:\n    x: float\n    y: float\n\ndef length(point: Точка) -> float:\n    return (point.x ** 2 + point.y ** 2) ** 0.5\n",
                    ),
                    code(
                        "lsp-magics",
                        "%matplotlib inline\n!echo ignored-by-lsp\npoint = Точка(3, 4)\n",
                    ),
                    markdown("lsp-middle", "## Result\n"),
                    code("lsp-reference", "length(point)\n"),
                ]
            ),
            ["lsp_mapping", "cross_cell_symbols", "ipython_magics", "unicode"],
        ),
    }

    coverage: dict[str, list[str]] = {}
    for name, (value, features) in fixtures.items():
        write_json(NOTEBOOKS / name, value)
        coverage[f"notebooks/{name}"] = features
    return coverage


def generate_messages() -> dict[str, list[str]]:
    plotly_bundle = {
        "text/plain": "Plotly fixture",
        "application/vnd.plotly.v1+json": {
            "data": [{"type": "scatter", "x": [1, 2], "y": [1, 4]}],
            "layout": {"title": {"text": "updated"}},
        },
    }
    transcripts: dict[str, tuple[list[dict[str, Any]], list[str]]] = {
        "display-update.jsonl": (
            [
                rpc(
                    1,
                    "request",
                    "execution.enqueue",
                    {"execution_id": "exec-display", "code": "display_handle()"},
                    message_id="request-display",
                ),
                rpc(
                    2,
                    "response",
                    "execution.enqueue",
                    {"accepted": True, "execution_id": "exec-display"},
                    message_id="request-display",
                ),
                rpc(
                    3,
                    "event",
                    "execution.state",
                    {"execution_id": "exec-display", "state": "running"},
                ),
                rpc(
                    4,
                    "event",
                    "execution.display",
                    {
                        "execution_id": "exec-display",
                        "display_id": "display-1",
                        "data": {"text/plain": "initial"},
                        "metadata": {},
                    },
                ),
                rpc(
                    5,
                    "event",
                    "execution.display_update",
                    {
                        "execution_id": "exec-display",
                        "display_id": "display-1",
                        "data": plotly_bundle,
                        "metadata": {},
                    },
                ),
                rpc(
                    6,
                    "event",
                    "execution.state",
                    {
                        "execution_id": "exec-display",
                        "state": "completed",
                        "execution_count": 10,
                    },
                ),
            ],
            ["display_updates", "display_id", "plotly"],
        ),
        "clear-output.jsonl": (
            [
                rpc(
                    1,
                    "request",
                    "execution.enqueue",
                    {"execution_id": "exec-clear", "code": "clear_output(wait=True)"},
                    message_id="request-clear",
                ),
                rpc(
                    2,
                    "response",
                    "execution.enqueue",
                    {"accepted": True, "execution_id": "exec-clear"},
                    message_id="request-clear",
                ),
                rpc(
                    3,
                    "event",
                    "execution.display",
                    {
                        "execution_id": "exec-clear",
                        "data": {"text/plain": "before"},
                        "metadata": {},
                    },
                ),
                rpc(
                    4,
                    "event",
                    "execution.clear_output",
                    {"execution_id": "exec-clear", "wait": True},
                ),
                rpc(
                    5,
                    "event",
                    "execution.stream",
                    {
                        "execution_id": "exec-clear",
                        "name": "stdout",
                        "text": "after\n",
                        "index": 1,
                    },
                ),
                rpc(
                    6,
                    "event",
                    "execution.state",
                    {
                        "execution_id": "exec-clear",
                        "state": "completed",
                        "execution_count": 11,
                    },
                ),
            ],
            ["clear_output", "streams"],
        ),
        "stdin.jsonl": (
            [
                rpc(
                    1,
                    "request",
                    "execution.enqueue",
                    {"execution_id": "exec-stdin", "code": "name = input('Name: ')"},
                    message_id="request-stdin",
                ),
                rpc(
                    2,
                    "response",
                    "execution.enqueue",
                    {"accepted": True, "execution_id": "exec-stdin"},
                    message_id="request-stdin",
                ),
                rpc(
                    3,
                    "event",
                    "execution.state",
                    {"execution_id": "exec-stdin", "state": "waiting_input"},
                ),
                rpc(
                    4,
                    "event",
                    "execution.stdin_request",
                    {
                        "execution_id": "exec-stdin",
                        "prompt": "Name: ",
                        "password": False,
                        "input_id": "input-1",
                    },
                ),
                rpc(
                    5,
                    "request",
                    "execution.stdin_reply",
                    {
                        "execution_id": "exec-stdin",
                        "input_id": "input-1",
                        "value": "Ada",
                    },
                    message_id="request-input",
                ),
                rpc(
                    6,
                    "response",
                    "execution.stdin_reply",
                    {"accepted": True},
                    message_id="request-input",
                ),
                rpc(
                    7,
                    "event",
                    "execution.state",
                    {"execution_id": "exec-stdin", "state": "running"},
                ),
                rpc(
                    8,
                    "event",
                    "execution.state",
                    {
                        "execution_id": "exec-stdin",
                        "state": "completed",
                        "execution_count": 12,
                    },
                ),
            ],
            ["stdin", "input_request"],
        ),
    }

    coverage: dict[str, list[str]] = {}
    for name, (messages, features) in transcripts.items():
        write_jsonl(MESSAGES / name, messages)
        coverage[f"messages/{name}"] = features
    return coverage


def main() -> None:
    notebook_coverage = generate_notebooks()
    message_coverage = generate_messages()
    manifest = {
        "version": 1,
        "generated_by": "scripts/generate-fixtures.py",
        "files": {**notebook_coverage, **message_coverage},
        "required_features": [
            "markdown",
            "code_cells",
            "streams",
            "errors",
            "stdin",
            "matplotlib",
            "display_updates",
            "clear_output",
            "attachments",
            "unknown_metadata",
            "plotly",
            "bokeh",
            "large_output",
            "unicode",
            "lsp_mapping",
        ],
    }
    write_json(ROOT / "tests" / "fixtures" / "manifest.json", manifest)


if __name__ == "__main__":
    main()
