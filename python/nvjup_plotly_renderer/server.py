from __future__ import annotations

import asyncio
import base64
import contextlib
import importlib.resources
import json
import os
import shutil
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Any

PROTOCOL = "nvjup/1"
MAX_MESSAGE_BYTES = 12 * 1024 * 1024


@dataclass
class Figure:
    page: Any
    width: int
    height: int
    last_frame_at: float = 0.0


class PlotlyRenderer:
    def __init__(self) -> None:
        self.playwright: Any = None
        self.browser: Any = None
        self.context: Any = None
        self.figures: dict[str, Figure] = {}
        self.plotly_js: str | None = None

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
        launch_args = ["--disable-dev-shm-usage"]
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
        )

        async def block_network(route: Any) -> None:
            await route.abort("blockedbyclient")

        await self.context.route("**/*", block_network)

    def _plotly_source(self) -> str:
        if self.plotly_js is None:
            source = (
                importlib.resources.files("plotly") / "package_data" / "plotly.min.js"
            )
            self.plotly_js = source.read_text(encoding="utf-8")
        return self.plotly_js

    @staticmethod
    def _dimension(value: Any, default: int, minimum: int, maximum: int) -> int:
        try:
            result = int(value)
        except (TypeError, ValueError):
            result = default
        return max(minimum, min(maximum, result))

    async def open(self, payload: dict[str, Any]) -> dict[str, Any]:
        started = time.monotonic()
        await self.start()
        figure_data = payload.get("figure")
        if not isinstance(figure_data, dict):
            raise ValueError("figure must be a Plotly MIME object")
        width = self._dimension(payload.get("width"), 900, 240, 1920)
        height = self._dimension(payload.get("height"), 540, 160, 1080)
        figure_id = str(payload.get("figure_id") or uuid.uuid4())[:256]
        previous = self.figures.pop(figure_id, None)
        if previous:
            await previous.page.close()
        page = await self.context.new_page()
        try:
            await page.set_viewport_size({"width": width, "height": height})
            encoded = json.dumps(
                figure_data, ensure_ascii=False, separators=(",", ":")
            ).replace("<", "\\u003c")
            html = f"""<!doctype html>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">
<style>html,body,#plot{{margin:0;width:100%;height:100%;overflow:hidden;background:white}}</style>
<div id="plot"></div>
<script>{self._plotly_source()}</script>
<script>
const figure = {encoded};
const config = Object.assign({{responsive:false,scrollZoom:true,displaylogo:false}}, figure.config || {{}});
Plotly.newPlot('plot', figure.data || [], figure.layout || {{}}, config);
</script>"""
            await page.set_content(html, wait_until="domcontentloaded")
            await page.wait_for_function(
                "document.querySelector('#plot').classList.contains('js-plotly-plot')"
            )
        except Exception:
            await page.close()
            raise
        self.figures[figure_id] = Figure(page=page, width=width, height=height)
        frame = await self.screenshot(figure_id)
        frame["open_latency_ms"] = round((time.monotonic() - started) * 1000, 2)
        return frame

    async def screenshot(self, figure_id: str) -> dict[str, Any]:
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        started = time.monotonic()
        png = await figure.page.locator("#plot").screenshot(type="png")
        figure.last_frame_at = time.monotonic()
        return {
            "figure_id": figure_id,
            "png": base64.b64encode(png).decode("ascii"),
            "width": figure.width,
            "height": figure.height,
            "frame_latency_ms": round((time.monotonic() - started) * 1000, 2),
        }

    async def event(self, payload: dict[str, Any]) -> dict[str, Any]:
        figure_id = str(payload.get("figure_id", ""))
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        event_type = str(payload.get("event", "move"))
        x = max(0.0, min(float(payload.get("x", 0)), figure.width - 1))
        y = max(0.0, min(float(payload.get("y", 0)), figure.height - 1))
        await figure.page.mouse.move(x, y)
        if event_type == "click":
            await figure.page.mouse.click(
                x, y, button=str(payload.get("button", "left"))
            )
        elif event_type == "down":
            await figure.page.mouse.down(button=str(payload.get("button", "left")))
        elif event_type == "up":
            await figure.page.mouse.up(button=str(payload.get("button", "left")))
        elif event_type == "drag":
            to_x = max(0.0, min(float(payload.get("to_x", x)), figure.width - 1))
            to_y = max(0.0, min(float(payload.get("to_y", y)), figure.height - 1))
            await figure.page.mouse.down(button=str(payload.get("button", "left")))
            await figure.page.mouse.move(to_x, to_y, steps=8)
            await figure.page.mouse.up(button=str(payload.get("button", "left")))
        elif event_type == "wheel":
            await figure.page.mouse.wheel(
                float(payload.get("delta_x", 0)), float(payload.get("delta_y", 0))
            )
        elif event_type != "move":
            raise ValueError(f"unsupported pointer event: {event_type}")
        elapsed = time.monotonic() - figure.last_frame_at
        if elapsed < 1 / 30:
            await asyncio.sleep(1 / 30 - elapsed)
        return await self.screenshot(figure_id)

    async def resize(self, payload: dict[str, Any]) -> dict[str, Any]:
        figure_id = str(payload.get("figure_id", ""))
        figure = self.figures.get(figure_id)
        if not figure:
            raise KeyError(f"unknown figure: {figure_id}")
        figure.width = self._dimension(payload.get("width"), figure.width, 240, 1920)
        figure.height = self._dimension(payload.get("height"), figure.height, 160, 1080)
        await figure.page.set_viewport_size(
            {"width": figure.width, "height": figure.height}
        )
        await figure.page.evaluate(
            "Plotly.Plots.resize(document.querySelector('#plot'))"
        )
        return await self.screenshot(figure_id)

    async def close(self, figure_id: str) -> None:
        figure = self.figures.pop(figure_id, None)
        if figure:
            await figure.page.close()

    async def shutdown(self) -> None:
        for figure_id in list(self.figures):
            await self.close(figure_id)
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
        self.renderer = PlotlyRenderer()
        self.running = True

    def send(self, message: dict[str, Any]) -> None:
        self.sequence += 1
        sys.stdout.write(
            json.dumps({"protocol": PROTOCOL, "seq": self.sequence, **message}) + "\n"
        )
        sys.stdout.flush()

    async def request(self, message: dict[str, Any]) -> None:
        request_id = str(message.get("id", ""))
        request_type = message.get("type")
        payload = message.get("payload") or {}
        try:
            if request_type == "renderer.hello":
                result = {
                    "backend": "playwright-chromium",
                    "chromium": self.renderer.chromium_path(),
                    "network": "blocked",
                }
            elif request_type == "plotly.open":
                result = await self.renderer.open(payload)
            elif request_type == "plotly.event":
                result = await self.renderer.event(payload)
            elif request_type == "plotly.resize":
                result = await self.renderer.resize(payload)
            elif request_type == "plotly.close":
                await self.renderer.close(str(payload.get("figure_id", "")))
                result = {"closed": True}
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
                    "type": str(request_type or "renderer.error"),
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
