from __future__ import annotations

import asyncio
import os
import shutil
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

from nvjup_plotly_renderer.server import PlotlyRenderer  # noqa: E402
from nvjup_sidecar.server import PROTOCOL  # noqa: E402


def chromium() -> str | None:
    configured = os.environ.get("NVJUP_CHROMIUM")
    if configured and os.path.isfile(configured):
        return configured
    return (
        shutil.which("chromium")
        or shutil.which("chromium-browser")
        or shutil.which("google-chrome-stable")
        or shutil.which("google-chrome")
    )


def test_renderer_reports_only_local_chromium() -> None:
    assert PROTOCOL == "nvjup/1"
    assert PlotlyRenderer.chromium_path() == chromium()


def test_plotly_screenshot_and_pointer_round_trip() -> None:
    if not chromium():
        pytest.skip("Chromium is unavailable")

    async def exercise() -> None:
        renderer = PlotlyRenderer()
        try:
            frame = await renderer.open(
                {
                    "figure_id": "pytest-plot",
                    "width": 480,
                    "height": 320,
                    "figure": {
                        "data": [{"type": "scatter", "x": [1, 2, 3], "y": [1, 4, 2]}],
                        "layout": {"title": {"text": "nvjup stage 5"}},
                    },
                }
            )
            assert frame["figure_id"] == "pytest-plot"
            assert frame["width"] == 480
            assert frame["height"] == 320
            assert frame["png"].startswith("iVBOR")
            assert frame["open_latency_ms"] >= 0

            hovered = await renderer.event(
                {"figure_id": "pytest-plot", "event": "move", "x": 240, "y": 160}
            )
            assert hovered["png"].startswith("iVBOR")
            zoomed = await renderer.event(
                {
                    "figure_id": "pytest-plot",
                    "event": "wheel",
                    "x": 240,
                    "y": 160,
                    "delta_y": -120,
                }
            )
            assert zoomed["png"].startswith("iVBOR")
            panned = await renderer.event(
                {
                    "figure_id": "pytest-plot",
                    "event": "drag",
                    "x": 260,
                    "y": 160,
                    "to_x": 200,
                    "to_y": 160,
                }
            )
            assert panned["png"].startswith("iVBOR")
        finally:
            await renderer.shutdown()

    asyncio.run(exercise())
