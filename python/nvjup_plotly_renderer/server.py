from __future__ import annotations

import ast
import asyncio
import base64
import contextlib
import importlib.resources
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

PROTOCOL = "nvjup/1"
MAX_MESSAGE_BYTES = 12 * 1024 * 1024
MAX_FIGURE_BYTES = 8 * 1024 * 1024
DEFAULT_FRAME_INTERVAL = 1 / 30
FIGURE_EVENT_QUEUE_LIMIT = 64
EVENT_PRIORITY = {
    "move": 1,
    "wheel": 1,
    "key": 2,
    "click": 3,
    "drag": 3,
    "down": 4,
    "up": 5,
}
ALLOWED_KEYS = {
    "ArrowDown",
    "ArrowLeft",
    "ArrowRight",
    "ArrowUp",
    "Backspace",
    "Delete",
    "Enter",
    "Escape",
    "Home",
    "End",
    "PageDown",
    "PageUp",
    "Space",
    "Tab",
    "+",
    "-",
    "=",
}


def _png_dimensions(encoded: str) -> tuple[int, int] | None:
    try:
        header = base64.b64decode(encoded[:64], validate=False)
    except Exception:
        return None
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", header[16:24])


@dataclass
class Figure:
    figure_id: str
    page: Any
    cdp: Any
    backend: str
    payload: dict[str, Any]
    width: int
    height: int
    push_requested: bool
    adaptive: bool
    low_width: int
    low_height: int
    max_fps: int
    push_enabled: bool = False
    screencast_started: bool = False
    quality: str = "high"
    frame_sequence: int = 0
    input_sequence: int = 0
    last_emitted_input_sequence: int = 0
    last_frame_started_at: float = 0.0
    last_frame_at: float = 0.0
    last_emit_at: float = 0.0
    last_input_at: float = 0.0
    restore_generation: int = 0
    mouse_buttons: int = 0
    restore_task: asyncio.Task[Any] | None = None
    event_task: asyncio.Task[Any] | None = None
    pending_push_task: asyncio.Task[Any] | None = None
    event_queue: deque[dict[str, Any]] = field(default_factory=deque)
    event_signal: asyncio.Event = field(default_factory=asyncio.Event)
    operation_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    metrics: dict[str, float] = field(default_factory=dict)


class PlotlyRenderer:
    """Sandboxed Plotly/Bokeh framebuffer renderer.

    The historical class name remains public for compatibility. Stage 6 makes
    the implementation backend-neutral and adds damage-driven CDP screencasts.
    """

    def __init__(
        self, frame_callback: Callable[[dict[str, Any]], Any] | None = None
    ) -> None:
        self.playwright: Any = None
        self.browser: Any = None
        self.context: Any = None
        self.figures: dict[str, Figure] = {}
        self.external_files: dict[str, str] = {}
        self.plotly_js: str | None = None
        self.bokeh_js: str | None = None
        self.frame_callback = frame_callback
        self.blocked_requests = 0
        self.frames_emitted = 0

    @staticmethod
    def chromium_path() -> str | None:
        configured = os.environ.get("NVJUP_CHROMIUM")
        if configured and os.path.isfile(configured):
            return configured
        for name in (
            "chromium",
            "chromium-browser",
            "google-chrome-stable",
            "google-chrome",
        ):
            path = shutil.which(name)
            if path:
                return path
        return None

    async def start(self) -> None:
        if self.browser is not None:
            return
        from playwright.async_api import async_playwright

        executable = self.chromium_path()
        if not executable:
            raise RuntimeError("Chromium was not found; set NVJUP_CHROMIUM")
        self.playwright = await async_playwright().start()
        launch_args = [
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-dev-shm-usage",
            "--disable-extensions",
            "--disable-sync",
            "--metrics-recording-only",
            "--no-first-run",
            "--password-store=basic",
        ]
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            launch_args.append("--no-sandbox")
        self.browser = await self.playwright.chromium.launch(
            executable_path=executable,
            headless=True,
            args=launch_args,
        )
        self.context = await self.browser.new_context(
            java_script_enabled=True,
            service_workers="block",
            accept_downloads=False,
            permissions=[],
        )

        async def block_network(route: Any) -> None:
            self.blocked_requests += 1
            await route.abort("blockedbyclient")

        await self.context.route("**/*", block_network)

    def _plotly_source(self) -> str:
        if self.plotly_js is None:
            source = (
                importlib.resources.files("plotly") / "package_data" / "plotly.min.js"
            )
            self.plotly_js = source.read_text(encoding="utf-8")
        return self.plotly_js

    def _bokeh_source(self) -> str:
        if self.bokeh_js is None:
            try:
                root = importlib.resources.files("bokeh") / "server" / "static" / "js"
            except ModuleNotFoundError as exc:
                raise RuntimeError(
                    "Bokeh support requires the local bokeh package"
                ) from exc
            sources = []
            for name in (
                "bokeh.min.js",
                "bokeh-gl.min.js",
                "bokeh-widgets.min.js",
                "bokeh-tables.min.js",
                "bokeh-mathjax.min.js",
            ):
                candidate = root / name
                if candidate.is_file():
                    sources.append(candidate.read_text(encoding="utf-8"))
            if not sources:
                raise RuntimeError("local BokehJS assets were not found")
            self.bokeh_js = "\n".join(sources)
        return self.bokeh_js

    @staticmethod
    def _dimension(value: Any, default: int, minimum: int, maximum: int) -> int:
        try:
            result = int(value)
        except (TypeError, ValueError):
            result = default
        return max(minimum, min(maximum, result))

    @staticmethod
    def _json_assignment(script: str, name: str) -> Any:
        marker = f"const {name} ="
        start = script.find(marker)
        if start < 0:
            raise ValueError(f"Bokeh script does not contain {name}")
        source = script[start + len(marker) :].lstrip()
        if source.startswith(("'", '"')):
            quote = source[0]
            escaped = False
            end = None
            for index, character in enumerate(source[1:], 1):
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    end = index + 1
                    break
            if end is None:
                raise ValueError(f"unterminated Bokeh {name} string")
            decoded = ast.literal_eval(source[:end])
            if not isinstance(decoded, str):
                raise ValueError(f"invalid Bokeh {name} string")
            return json.loads(decoded)
        value, _ = json.JSONDecoder().raw_decode(source)
        return value

    @staticmethod
    def _validate_bokeh_docs(value: Any) -> None:
        if isinstance(value, dict):
            model_name = value.get("name") or value.get("type")
            if isinstance(model_name, str) and model_name.startswith("CustomJS"):
                raise ValueError(f"Bokeh executable model is blocked: {model_name}")
            if "code" in value and isinstance(value["code"], str):
                raise ValueError("Bokeh serialized JavaScript code is blocked")
            for child in value.values():
                PlotlyRenderer._validate_bokeh_docs(child)
        elif isinstance(value, list):
            for child in value:
                PlotlyRenderer._validate_bokeh_docs(child)

    @staticmethod
    def _safe_render_items(docs_json: Any, render_items: Any) -> list[dict[str, Any]]:
        if not isinstance(docs_json, dict) or not isinstance(render_items, list):
            raise ValueError("invalid Bokeh document envelope")
        safe: list[dict[str, Any]] = []
        for item_index, item in enumerate(render_items):
            if not isinstance(item, dict) or not isinstance(item.get("roots"), dict):
                raise ValueError("invalid Bokeh render item")
            doc_id = item.get("docid")
            if not isinstance(doc_id, str) or doc_id not in docs_json:
                raise ValueError("Bokeh render item references an unknown document")
            roots: dict[str, str] = {}
            for root_index, root_id in enumerate(item["roots"]):
                if not isinstance(root_id, str):
                    raise ValueError("invalid Bokeh root id")
                roots[root_id] = f"nvjup-bokeh-{item_index}-{root_index}"
            safe.append({"docid": doc_id, "roots": roots, "root_ids": list(roots)})
        return safe

    def _bokeh_payload(
        self, payload: dict[str, Any]
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        if isinstance(payload.get("docs_json"), dict) and isinstance(
            payload.get("render_items"), list
        ):
            docs_json, render_items = payload["docs_json"], payload["render_items"]
            self._validate_bokeh_docs(docs_json)
            return docs_json, self._safe_render_items(docs_json, render_items)
        item = payload.get("item")
        if isinstance(item, dict) and isinstance(item.get("doc"), dict):
            root_id = str(item.get("root_id") or "nvjup-root")
            target_id = str(item.get("target_id") or "nvjup-plot")
            doc_id = "nvjup-document"
            docs_json = {doc_id: item["doc"]}
            self._validate_bokeh_docs(docs_json)
            render_items = [
                {"docid": doc_id, "roots": {root_id: target_id}, "root_ids": [root_id]}
            ]
            return docs_json, self._safe_render_items(docs_json, render_items)
        script = payload.get("script")
        if isinstance(script, str) and len(script.encode("utf-8")) <= MAX_FIGURE_BYTES:
            docs_json = self._json_assignment(script, "docs_json")
            render_items = self._json_assignment(script, "render_items")
            self._validate_bokeh_docs(docs_json)
            return docs_json, self._safe_render_items(docs_json, render_items)
        raise ValueError(
            "unsupported Bokeh payload: expected safe serialized document data"
        )

    @staticmethod
    def _inline_script(source: str) -> str:
        return re.sub(r"</script", r"<\\/script", source, flags=re.IGNORECASE)

    def _html(
        self, backend: str, payload: dict[str, Any], *, external: bool = False
    ) -> str:
        csp = (
            "default-src 'none'; script-src 'unsafe-inline'; script-src-attr 'none'; style-src 'unsafe-inline'; "
            "img-src data: blob:; font-src data:; connect-src 'none'; media-src 'none'; "
            "object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
        )
        style = (
            "html,body,#plot{margin:0;width:100%;height:100%;overflow:hidden;background:white}"
            ".bk-root{width:100%;height:100%}"
        )
        if backend == "plotly":
            encoded = json.dumps(
                payload, ensure_ascii=False, separators=(",", ":")
            ).replace("<", "\\u003c")
            body = (
                '<div id="plot"></div><script>'
                + self._inline_script(self._plotly_source())
                + "</script><script>"
                + f"const figure={encoded};"
                + "const layout=Object.assign({},figure.layout||{});delete layout.width;delete layout.height;layout.autosize=true;"
                + f"const config=Object.assign({{responsive:{str(external).lower()},scrollZoom:true,displaylogo:false}},figure.config||{{}});"
                + "Plotly.newPlot('plot',figure.data||[],layout,config);"
                + (
                    "window.addEventListener('resize',()=>Plotly.Plots.resize(document.querySelector('#plot')));"
                    if external
                    else ""
                )
                + "</script>"
            )
        elif backend == "bokeh":
            docs_json, render_items = self._bokeh_payload(payload)
            docs = json.dumps(
                docs_json, ensure_ascii=False, separators=(",", ":")
            ).replace("<", "\\u003c")
            items = json.dumps(
                render_items, ensure_ascii=False, separators=(",", ":")
            ).replace("<", "\\u003c")
            targets: set[str] = set()
            for item in render_items:
                roots = item.get("roots") if isinstance(item, dict) else None
                if isinstance(roots, dict):
                    targets.update(str(target) for target in roots.values())
            containers = "".join(
                f'<div id="{target}" style="width:100%;height:100%"></div>'
                for target in sorted(targets)
            )
            if not containers:
                containers = '<div id="plot" style="width:100%;height:100%"></div>'
            body = (
                containers
                + "<script>"
                + self._inline_script(self._bokeh_source())
                + "</script><script>"
                + f"const docs_json={docs};const render_items={items};"
                + "const resize_bokeh=()=>{for(const view of Object.values(Bokeh.index)){if('sizing_mode' in view.model)view.model.sizing_mode='stretch_both';if(view.resize_layout)view.resize_layout();}};"
                + "Promise.resolve(Bokeh.embed.embed_items(docs_json,render_items)).then(resize_bokeh);"
                + (
                    "window.addEventListener('resize',resize_bokeh);"
                    if external
                    else ""
                )
                + "</script>"
            )
        else:
            raise ValueError(f"unsupported interactive backend: {backend}")
        return (
            '<!doctype html><meta charset="utf-8">'
            f'<meta http-equiv="Content-Security-Policy" content="{csp}">'
            f"<style>{style}</style>{body}"
        )

    async def _wait_ready(self, figure: Figure) -> None:
        if figure.backend == "plotly":
            await figure.page.wait_for_function(
                "document.querySelector('#plot')?.classList.contains('js-plotly-plot')"
            )
        else:
            await figure.page.wait_for_function(
                "window.Bokeh && Bokeh.index && Object.keys(Bokeh.index).length > 0"
            )

    def _frame_payload(
        self,
        figure: Figure,
        png: str,
        started: float,
        *,
        quality: str,
        source: str,
        input_sequence: int | None = None,
    ) -> dict[str, Any]:
        dimensions = _png_dimensions(png)
        width, height = dimensions or (figure.width, figure.height)
        now = time.monotonic()
        figure.frame_sequence += 1
        figure.last_frame_at = now
        captured_input_sequence = (
            figure.input_sequence if input_sequence is None else input_sequence
        )
        input_frame = (
            source == "pull"
            or captured_input_sequence > figure.last_emitted_input_sequence
        )
        latency = (now - started) * 1000
        if input_frame:
            figure.last_emitted_input_sequence = max(
                figure.last_emitted_input_sequence, captured_input_sequence
            )
            figure.metrics["frame_latency_ms"] = latency
        else:
            latency = figure.metrics.get("frame_latency_ms", latency)
        return {
            "figure_id": figure.figure_id,
            "png": png,
            "width": width,
            "height": height,
            "source_width": figure.width,
            "source_height": figure.height,
            "frame_latency_ms": round(latency, 2),
            "frame_sequence": figure.frame_sequence,
            "input_sequence": captured_input_sequence,
            "input_frame": input_frame,
            "quality": quality,
            "frame_source": source,
        }

    async def screenshot(self, figure_id: str) -> dict[str, Any]:
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        started = time.monotonic()
        figure.last_frame_started_at = started
        png = await figure.page.screenshot(type="png")
        return self._frame_payload(
            figure,
            base64.b64encode(png).decode("ascii"),
            started,
            quality="high",
            source="pull",
        )

    async def _emit_frame(self, payload: dict[str, Any]) -> None:
        if not self.frame_callback:
            return
        self.frames_emitted += 1
        result = self.frame_callback(payload)
        if asyncio.iscoroutine(result):
            await result

    async def _emit_screencast_after(
        self,
        figure: Figure,
        data: str,
        input_sequence: int,
        started: float,
        delay: float,
    ) -> None:
        try:
            await asyncio.sleep(delay)
            if self.figures.get(figure.figure_id) is not figure:
                return
            figure.pending_push_task = None
            figure.last_emit_at = time.monotonic()
            payload = self._frame_payload(
                figure,
                data,
                started,
                quality=figure.quality,
                source="screencast",
                input_sequence=input_sequence,
            )
            await self._emit_frame(payload)
        except asyncio.CancelledError:
            return

    async def _handle_screencast_frame(
        self, figure: Figure, params: dict[str, Any]
    ) -> None:
        session_id = params.get("sessionId")
        if session_id is not None:
            with contextlib.suppress(Exception):
                await figure.cdp.send(
                    "Page.screencastFrameAck", {"sessionId": session_id}
                )
        if self.figures.get(figure.figure_id) is not figure:
            return
        data = params.get("data")
        if not isinstance(data, str):
            return
        now = time.monotonic()
        delay = max(0.0, (figure.last_emit_at + 1 / figure.max_fps) - now)
        if figure.pending_push_task:
            figure.pending_push_task.cancel()
        figure.pending_push_task = asyncio.create_task(
            self._emit_screencast_after(
                figure,
                data,
                figure.input_sequence,
                figure.last_input_at or now,
                delay,
            )
        )

    async def _start_screencast(self, figure: Figure, quality: str) -> None:
        if not figure.push_requested:
            return
        if figure.pending_push_task:
            figure.pending_push_task.cancel()
            figure.pending_push_task = None
        if figure.screencast_started:
            with contextlib.suppress(Exception):
                await figure.cdp.send("Page.stopScreencast")
            figure.screencast_started = False
        width = figure.low_width if quality == "interactive" else figure.width
        height = figure.low_height if quality == "interactive" else figure.height
        await figure.cdp.send(
            "Page.startScreencast",
            {
                "format": "png",
                "maxWidth": width,
                "maxHeight": height,
                "everyNthFrame": 1,
            },
        )
        figure.quality = quality
        figure.screencast_started = True
        figure.push_enabled = True

    async def _restore_quality(self, figure: Figure, generation: int) -> None:
        await asyncio.sleep(0.15)
        if (
            self.figures.get(figure.figure_id) is not figure
            or generation != figure.restore_generation
        ):
            return
        if figure.push_enabled and figure.quality != "high":
            with contextlib.suppress(Exception):
                await self._start_screencast(figure, "high")

    async def _interactive_quality(self, figure: Figure) -> None:
        if not figure.push_enabled or not figure.adaptive:
            return
        figure.restore_generation += 1
        generation = figure.restore_generation
        if figure.quality != "interactive":
            with contextlib.suppress(Exception):
                await self._start_screencast(figure, "interactive")
        if figure.restore_task:
            figure.restore_task.cancel()
        figure.restore_task = asyncio.create_task(
            self._restore_quality(figure, generation)
        )

    async def open(self, payload: dict[str, Any]) -> dict[str, Any]:
        started = time.monotonic()
        await self.start()
        backend = str(payload.get("backend") or "plotly")
        figure_data = payload.get("figure")
        if not isinstance(figure_data, dict):
            raise ValueError("figure must be a serialized interactive object")
        encoded_size = len(json.dumps(figure_data, ensure_ascii=False).encode("utf-8"))
        if encoded_size > MAX_FIGURE_BYTES:
            raise ValueError(f"interactive payload exceeds {MAX_FIGURE_BYTES} bytes")
        width = self._dimension(payload.get("width"), 900, 240, 1920)
        height = self._dimension(payload.get("height"), 540, 160, 1080)
        low_width = self._dimension(payload.get("interactive_width"), 720, 240, width)
        low_height = self._dimension(
            payload.get("interactive_height"), 432, 160, height
        )
        figure_id = str(payload.get("figure_id") or uuid.uuid4())[:256]
        max_figures = self._dimension(payload.get("max_figures"), 8, 1, 32)
        if figure_id not in self.figures and len(self.figures) >= max_figures:
            raise ValueError(f"interactive figure limit reached: {max_figures}")
        await self.close(figure_id)
        page = await self.context.new_page()
        cdp = await self.context.new_cdp_session(page)
        figure = Figure(
            figure_id=figure_id,
            page=page,
            cdp=cdp,
            backend=backend,
            payload=figure_data,
            width=width,
            height=height,
            push_requested=payload.get("screencast", True) is not False,
            adaptive=payload.get("adaptive_resolution", True) is not False,
            low_width=low_width,
            low_height=low_height,
            max_fps=self._dimension(payload.get("max_fps"), 60, 1, 60),
        )

        def on_frame(params: dict[str, Any]) -> None:
            asyncio.create_task(self._handle_screencast_frame(figure, params))

        cdp.on("Page.screencastFrame", on_frame)
        try:
            await page.set_viewport_size({"width": width, "height": height})
            await page.set_content(
                self._html(backend, figure_data), wait_until="domcontentloaded"
            )
            await asyncio.wait_for(self._wait_ready(figure), timeout=10)
            self.figures[figure_id] = figure
            frame = await self.screenshot(figure_id)
            if figure.push_requested:
                try:
                    await self._start_screencast(figure, "high")
                except Exception as exc:
                    figure.push_enabled = False
                    figure.metrics["screencast_error"] = 1
                    frame["screencast_error"] = str(exc)
            frame["push_frames"] = figure.push_enabled
            frame["backend"] = backend
            frame["open_latency_ms"] = round((time.monotonic() - started) * 1000, 2)
            return frame
        except Exception:
            self.figures.pop(figure_id, None)
            with contextlib.suppress(Exception):
                await cdp.detach()
            await page.close()
            raise

    async def export_external(self, payload: dict[str, Any]) -> dict[str, Any]:
        figure_id = str(payload.get("figure_id", ""))
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        for previous in self.external_files.values():
            with contextlib.suppress(OSError):
                os.remove(previous)
        self.external_files.clear()
        html = self._html(figure.backend, figure.payload, external=True)
        descriptor, path = tempfile.mkstemp(prefix="nvjup-awrit-", suffix=".html")
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                output.write(html)
        except Exception:
            with contextlib.suppress(OSError):
                os.close(descriptor)
            with contextlib.suppress(OSError):
                os.remove(path)
            raise
        self.external_files[figure_id] = path
        return {
            "figure_id": figure_id,
            "path": path,
            "url": "file://" + path,
            "backend": figure.backend,
        }

    async def release_external(self, figure_id: str = "") -> None:
        if figure_id:
            path = self.external_files.pop(figure_id, None)
            paths = [path] if path else []
        else:
            paths = list(self.external_files.values())
            self.external_files.clear()
        for path in paths:
            with contextlib.suppress(OSError):
                os.remove(path)

    @staticmethod
    def _validate_event(payload: dict[str, Any]) -> str:
        event_type = str(payload.get("event", "move"))
        if event_type == "key":
            key = str(payload.get("key", ""))
            if key not in ALLOWED_KEYS:
                raise ValueError(f"unsupported key: {key}")
        elif event_type not in {"click", "down", "up", "drag", "wheel", "move"}:
            raise ValueError(f"unsupported pointer event: {event_type}")
        return event_type

    async def _apply_event(self, figure: Figure, payload: dict[str, Any]) -> None:
        started = time.monotonic()
        figure.last_input_at = float(payload.get("_received_at", started))
        figure.input_sequence += 1
        event_type = self._validate_event(payload)
        if event_type == "key":
            await figure.page.keyboard.press(str(payload["key"]))
        else:
            x = max(0.0, min(float(payload.get("x", 0)), figure.width - 1))
            y = max(0.0, min(float(payload.get("y", 0)), figure.height - 1))
            button = str(payload.get("button", "left"))
            moved = {
                "type": "mouseMoved",
                "x": x,
                "y": y,
                "button": button if figure.mouse_buttons else "none",
                "buttons": figure.mouse_buttons,
            }
            if event_type == "wheel":
                await figure.cdp.send(
                    "Input.dispatchMouseEvent",
                    {
                        "type": "mouseWheel",
                        "x": x,
                        "y": y,
                        "deltaX": float(payload.get("delta_x", 0)),
                        "deltaY": float(payload.get("delta_y", 0)),
                        "buttons": figure.mouse_buttons,
                    },
                )
            else:
                await figure.cdp.send("Input.dispatchMouseEvent", moved)
                if event_type == "click":
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mousePressed",
                            "x": x,
                            "y": y,
                            "button": button,
                            "buttons": 1,
                            "clickCount": 1,
                        },
                    )
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mouseReleased",
                            "x": x,
                            "y": y,
                            "button": button,
                            "buttons": 0,
                            "clickCount": 1,
                        },
                    )
                elif event_type == "down":
                    figure.mouse_buttons = 1
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mousePressed",
                            "x": x,
                            "y": y,
                            "button": button,
                            "buttons": 1,
                            "clickCount": 1,
                        },
                    )
                elif event_type == "up":
                    figure.mouse_buttons = 0
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mouseReleased",
                            "x": x,
                            "y": y,
                            "button": button,
                            "buttons": 0,
                            "clickCount": 1,
                        },
                    )
                elif event_type == "drag":
                    to_x = max(
                        0.0, min(float(payload.get("to_x", x)), figure.width - 1)
                    )
                    to_y = max(
                        0.0, min(float(payload.get("to_y", y)), figure.height - 1)
                    )
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mousePressed",
                            "x": x,
                            "y": y,
                            "button": button,
                            "buttons": 1,
                            "clickCount": 1,
                        },
                    )
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mouseMoved",
                            "x": to_x,
                            "y": to_y,
                            "button": button,
                            "buttons": 1,
                        },
                    )
                    await figure.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mouseReleased",
                            "x": to_x,
                            "y": to_y,
                            "button": button,
                            "buttons": 0,
                            "clickCount": 1,
                        },
                    )
        figure.metrics["input_latency_ms"] = (time.monotonic() - started) * 1000

    @staticmethod
    def _enqueue_event(figure: Figure, payload: dict[str, Any]) -> bool:
        event_type = str(payload.get("event", "move"))
        if (
            event_type == "move"
            and figure.event_queue
            and figure.event_queue[-1].get("event") == "move"
        ):
            figure.event_queue[-1] = payload
        elif (
            event_type == "wheel"
            and figure.event_queue
            and figure.event_queue[-1].get("event") == "wheel"
        ):
            previous = figure.event_queue[-1]
            previous["delta_x"] = float(previous.get("delta_x", 0)) + float(
                payload.get("delta_x", 0)
            )
            previous["delta_y"] = float(previous.get("delta_y", 0)) + float(
                payload.get("delta_y", 0)
            )
            previous["x"] = payload.get("x", previous.get("x", 0))
            previous["y"] = payload.get("y", previous.get("y", 0))
        else:
            if len(figure.event_queue) >= FIGURE_EVENT_QUEUE_LIMIT:
                incoming_priority = EVENT_PRIORITY[event_type]
                candidates = [
                    (
                        EVENT_PRIORITY.get(str(queued.get("event")), 2),
                        index,
                    )
                    for index, queued in enumerate(figure.event_queue)
                    if queued.get("event") != "up"
                    and EVENT_PRIORITY.get(str(queued.get("event")), 2)
                    < incoming_priority
                ]
                eviction_index = min(candidates)[1] if candidates else None
                if eviction_index is not None:
                    del figure.event_queue[eviction_index]
                elif event_type == "up" and all(
                    queued.get("event") == "up" for queued in figure.event_queue
                ):
                    # Keep the newest release when the queue consists solely of
                    # releases; retaining every duplicate has no additional value.
                    figure.event_queue.popleft()
                else:
                    return False
            figure.event_queue.append(payload)
        figure.event_signal.set()
        return True

    async def _input_loop(self, figure: Figure) -> None:
        try:
            while self.figures.get(figure.figure_id) is figure:
                if not figure.event_queue:
                    figure.event_signal.clear()
                    await figure.event_signal.wait()
                    continue
                payload = figure.event_queue.popleft()
                async with figure.operation_lock:
                    await self._interactive_quality(figure)
                    await self._apply_event(figure, payload)
        except asyncio.CancelledError:
            raise
        except Exception:
            figure.metrics["input_errors"] = figure.metrics.get("input_errors", 0) + 1

    async def event(self, payload: dict[str, Any]) -> dict[str, Any]:
        received = time.monotonic()
        figure_id = str(payload.get("figure_id", ""))
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        self._validate_event(payload)
        if figure.push_enabled:
            queued = dict(payload)
            queued["_received_at"] = received
            accepted = self._enqueue_event(figure, queued)
            if figure.event_queue and (
                not figure.event_task or figure.event_task.done()
            ):
                figure.event_task = asyncio.create_task(self._input_loop(figure))
            return {
                "figure_id": figure_id,
                "accepted": accepted,
                "push_frames": True,
                "queue_depth": len(figure.event_queue),
                "enqueue_latency_ms": round((time.monotonic() - received) * 1000, 2),
            }
        await self._apply_event(figure, payload)
        target = figure.last_frame_started_at + DEFAULT_FRAME_INTERVAL
        delay = target - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        frame = await self.screenshot(figure_id)
        frame["input_latency_ms"] = round(figure.metrics["input_latency_ms"], 2)
        return frame

    async def resize(self, payload: dict[str, Any]) -> dict[str, Any]:
        figure_id = str(payload.get("figure_id", ""))
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        async with figure.operation_lock:
            figure.width = self._dimension(
                payload.get("width"), figure.width, 240, 1920
            )
            figure.height = self._dimension(
                payload.get("height"), figure.height, 160, 1080
            )
            figure.low_width = min(
                figure.width,
                self._dimension(
                    payload.get("interactive_width"), 720, 240, figure.width
                ),
            )
            figure.low_height = min(
                figure.height,
                self._dimension(
                    payload.get("interactive_height"), 432, 160, figure.height
                ),
            )
            if figure.screencast_started:
                with contextlib.suppress(Exception):
                    await figure.cdp.send("Page.stopScreencast")
                figure.screencast_started = False
            await figure.page.set_viewport_size(
                {"width": figure.width, "height": figure.height}
            )
            if figure.backend == "plotly":
                await figure.page.evaluate(
                    "Plotly.Plots.resize(document.querySelector('#plot'))"
                )
            else:
                await figure.page.evaluate(
                    "for (const view of Object.values(Bokeh.index)) { if (view.resize_layout) view.resize_layout(); }"
                )
            frame = await self.screenshot(figure_id)
            if figure.push_requested:
                with contextlib.suppress(Exception):
                    await self._start_screencast(figure, "high")
            frame["push_frames"] = figure.push_enabled
            return frame

    async def health(self) -> dict[str, Any]:
        return {
            "backend": "playwright-chromium",
            "chromium": self.chromium_path(),
            "network": "blocked",
            "blocked_requests": self.blocked_requests,
            "frames_emitted": self.frames_emitted,
            "external_exports": list(self.external_files),
            "figures": [
                {
                    "figure_id": figure.figure_id,
                    "backend": figure.backend,
                    "push_frames": figure.push_enabled,
                    "quality": figure.quality,
                    "width": figure.width,
                    "height": figure.height,
                    "max_fps": figure.max_fps,
                    "queue_depth": len(figure.event_queue),
                    "metrics": {
                        key: round(value, 2) for key, value in figure.metrics.items()
                    },
                }
                for figure in self.figures.values()
            ],
        }

    async def close(self, figure_id: str) -> None:
        external_path = self.external_files.pop(figure_id, None)
        if external_path:
            with contextlib.suppress(OSError):
                os.remove(external_path)
        figure = self.figures.pop(figure_id, None)
        if not figure:
            return
        if figure.restore_task:
            figure.restore_task.cancel()
        if figure.event_task:
            figure.event_task.cancel()
        if figure.pending_push_task:
            figure.pending_push_task.cancel()
        figure.event_queue.clear()
        if figure.screencast_started:
            with contextlib.suppress(Exception):
                await figure.cdp.send("Page.stopScreencast")
        with contextlib.suppress(Exception):
            await figure.cdp.detach()
        await figure.page.close()

    async def shutdown(self) -> None:
        for figure_id in list(self.figures):
            await self.close(figure_id)
        for path in self.external_files.values():
            with contextlib.suppress(OSError):
                os.remove(path)
        self.external_files.clear()
        if self.context:
            await self.context.close()
        if self.browser:
            await self.browser.close()
        if self.playwright:
            await self.playwright.stop()
        self.context = self.browser = self.playwright = None


class Server:
    def __init__(self) -> None:
        self.sequence = 0
        self.renderer = PlotlyRenderer(self.emit_frame)
        self.running = True

    def send(self, message: dict[str, Any]) -> None:
        self.sequence += 1
        sys.stdout.write(
            json.dumps({"protocol": PROTOCOL, "seq": self.sequence, **message}) + "\n"
        )
        sys.stdout.flush()

    def emit_frame(self, payload: dict[str, Any]) -> None:
        self.send({"kind": "event", "type": "renderer.frame", "payload": payload})

    async def request(self, message: dict[str, Any]) -> None:
        request_id = str(message.get("id", ""))
        request_type = str(message.get("type") or "")
        payload = message.get("payload") or {}
        try:
            if request_type == "renderer.hello":
                result = await self.renderer.health()
            elif request_type in {"renderer.open", "plotly.open"}:
                if request_type == "plotly.open":
                    payload = {**payload, "backend": "plotly"}
                result = await self.renderer.open(payload)
            elif request_type == "renderer.export_external":
                result = await self.renderer.export_external(payload)
            elif request_type == "renderer.release_external":
                await self.renderer.release_external(str(payload.get("figure_id", "")))
                result = {"released": True}
            elif request_type in {"renderer.event", "plotly.event"}:
                result = await self.renderer.event(payload)
            elif request_type in {"renderer.resize", "plotly.resize"}:
                result = await self.renderer.resize(payload)
            elif request_type in {"renderer.close", "plotly.close"}:
                await self.renderer.close(str(payload.get("figure_id", "")))
                result = {"closed": True}
            elif request_type == "renderer.status":
                result = await self.renderer.health()
            elif request_type == "renderer.shutdown":
                await self.renderer.shutdown()
                self.running = False
                result = {"stopped": True}
            else:
                raise ValueError(f"unknown request type: {request_type}")
            self.send(
                {
                    "kind": "response",
                    "type": request_type,
                    "id": request_id,
                    "payload": result,
                }
            )
        except Exception as exc:
            self.send(
                {
                    "kind": "response",
                    "type": request_type or "renderer.error",
                    "id": request_id,
                    "payload": {},
                    "error": {
                        "code": "renderer_failed",
                        "message": str(exc),
                        "retryable": True,
                        "details": {"exception": type(exc).__name__},
                    },
                }
            )

    async def run(self) -> None:
        while self.running:
            line = await asyncio.to_thread(sys.stdin.buffer.readline)
            if not line:
                break
            if len(line) > MAX_MESSAGE_BYTES:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("protocol") == PROTOCOL and message.get("kind") == "request":
                await self.request(message)
        with contextlib.suppress(Exception):
            await self.renderer.shutdown()


def main() -> None:
    asyncio.run(Server().run())


if __name__ == "__main__":
    main()
