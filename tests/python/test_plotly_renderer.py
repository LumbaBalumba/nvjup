from __future__ import annotations

import asyncio
import os
import shutil
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

from nvjup_plotly_renderer.server import Figure, PlotlyRenderer  # noqa: E402
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


def queued_figure() -> Figure:
    return Figure(
        figure_id="queue-test",
        page=None,
        cdp=None,
        backend="plotly",
        payload={},
        width=640,
        height=480,
        push_requested=True,
        adaptive=True,
        low_width=320,
        low_height=240,
        max_fps=30,
        push_enabled=True,
    )


@pytest.mark.parametrize("event_type", ["key", "down", "up"])
def test_push_event_queue_is_hard_bounded_for_saturated_events(
    event_type: str,
) -> None:
    figure = queued_figure()
    for sequence in range(512):
        payload: dict[str, object] = {
            "event": event_type,
            "key": "Enter",
            "x": sequence,
            "y": sequence,
        }
        PlotlyRenderer._enqueue_event(figure, payload)
        assert len(figure.event_queue) <= 64
    assert len(figure.event_queue) == 64
    if event_type == "up":
        assert figure.event_queue[-1]["x"] == 511


def test_push_event_queue_preserves_releases_and_rejects_lower_priority() -> None:
    figure = queued_figure()
    for sequence in range(32):
        assert PlotlyRenderer._enqueue_event(
            figure, {"event": "up", "x": sequence, "y": sequence}
        )
        assert PlotlyRenderer._enqueue_event(
            figure, {"event": "down", "x": sequence, "y": sequence}
        )
    assert len(figure.event_queue) == 64

    for event_type in ("key", "down"):
        assert not PlotlyRenderer._enqueue_event(
            figure, {"event": event_type, "key": "Enter", "x": 0, "y": 0}
        )
        assert len(figure.event_queue) == 64
        assert sum(event["event"] == "up" for event in figure.event_queue) == 32

    for sequence in range(100):
        assert PlotlyRenderer._enqueue_event(
            figure, {"event": "up", "x": sequence, "y": sequence}
        )
        assert len(figure.event_queue) == 64
    assert all(event["event"] == "up" for event in figure.event_queue)
    assert figure.event_queue[-1]["x"] == 99


def test_bokeh_parser_rejects_arbitrary_notebook_javascript() -> None:
    renderer = PlotlyRenderer()
    with pytest.raises(ValueError, match="docs_json"):
        renderer._bokeh_payload({"script": "alert(document.cookie)"})
    with pytest.raises(ValueError, match="executable model"):
        renderer._bokeh_payload(
            {
                "docs_json": {
                    "doc": {
                        "roots": [
                            {
                                "type": "object",
                                "name": "CustomJS",
                                "attributes": {"code": "alert(1)"},
                            }
                        ]
                    }
                },
                "render_items": [],
            }
        )
    docs, items = renderer._bokeh_payload(
        {
            "item": {
                "target_id": '"><script>alert(1)</script>',
                "root_id": "root",
                "doc": {"version": "3.8.0", "roots": []},
            }
        }
    )
    assert docs
    assert items[0]["roots"]["root"] == "nvjup-bokeh-0-0"


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
                    "screencast": False,
                    "figure": {
                        "data": [{"type": "scatter", "x": [1, 2, 3], "y": [1, 4, 2]}],
                        "layout": {
                            "title": {"text": "nvjup stage 5"},
                            "width": 240,
                            "height": 160,
                        },
                    },
                }
            )
            assert frame["figure_id"] == "pytest-plot"
            assert frame["width"] == 480
            assert frame["height"] == 320
            assert frame["png"].startswith("iVBOR")
            assert frame["open_latency_ms"] >= 0
            plot_size = await renderer.figures["pytest-plot"].page.evaluate(
                "() => { const box=document.querySelector('#plot .svg-container').getBoundingClientRect(); return [box.width,box.height]; }"
            )
            assert plot_size == [480, 320]

            exported = await renderer.export_external({"figure_id": "pytest-plot"})
            exported_path = Path(exported["path"])
            assert exported["url"] == exported_path.as_uri()
            assert exported_path.stat().st_mode & 0o777 == 0o600
            exported_html = exported_path.read_text(encoding="utf-8")
            assert "Content-Security-Policy" in exported_html
            assert "connect-src 'none'" in exported_html
            assert "const figure=" in exported_html
            assert (
                "delete layout.width;delete layout.height;layout.autosize=true"
                in exported_html
            )
            assert "responsive:true" in exported_html
            await renderer.release_external("pytest-plot")
            assert not exported_path.exists()
            exported = await renderer.export_external({"figure_id": "pytest-plot"})
            exported_path = Path(exported["path"])

            hovered = await renderer.event(
                {"figure_id": "pytest-plot", "event": "move", "x": 240, "y": 160}
            )
            assert hovered["png"].startswith("iVBOR")
            pressed = await renderer.event(
                {"figure_id": "pytest-plot", "event": "down", "x": 240, "y": 160}
            )
            released = await renderer.event(
                {"figure_id": "pytest-plot", "event": "up", "x": 240, "y": 160}
            )
            assert pressed["png"].startswith("iVBOR")
            assert released["png"].startswith("iVBOR")
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
            await renderer.close("pytest-plot")
            assert not exported_path.exists()
        finally:
            await renderer.shutdown()

    asyncio.run(exercise())


def test_push_frames_bokeh_resize_keyboard_and_multiple_figures() -> None:
    if not chromium():
        pytest.skip("Chromium is unavailable")

    async def exercise() -> None:
        from bokeh.embed import components
        from bokeh.plotting import figure as bokeh_figure

        pushed: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        renderer = PlotlyRenderer(pushed.put_nowait)
        try:
            plotly = await renderer.open(
                {
                    "figure_id": "push-plot",
                    "width": 600,
                    "height": 360,
                    "interactive_width": 450,
                    "interactive_height": 270,
                    "figure": {
                        "data": [{"type": "scatter", "x": [1, 2], "y": [2, 1]}],
                        "layout": {
                            "images": [
                                {
                                    "source": "https://example.invalid/blocked.png",
                                    "xref": "paper",
                                    "yref": "paper",
                                }
                            ]
                        },
                    },
                }
            )
            assert plotly["push_frames"] is True
            while not pushed.empty():
                pushed.get_nowait()
            accepted = await renderer.event(
                {"figure_id": "push-plot", "event": "move", "x": 300, "y": 180}
            )
            assert accepted["accepted"] is True
            pushed_frame = await asyncio.wait_for(pushed.get(), timeout=2)
            assert str(pushed_frame["png"]).startswith("iVBOR")
            assert pushed_frame["source_width"] == 600
            assert pushed_frame["quality"] in {"interactive", "high"}

            keyed = await renderer.event(
                {"figure_id": "push-plot", "event": "key", "key": "ArrowRight"}
            )
            assert keyed["accepted"] is True
            resized = await renderer.resize(
                {"figure_id": "push-plot", "width": 720, "height": 432}
            )
            assert resized["width"] == 720
            assert resized["height"] == 432

            bokeh_plot = bokeh_figure(width=480, height=320)
            bokeh_plot.line([1, 2, 3], [3, 1, 4])
            bokeh_script, _ = components(bokeh_plot)
            bokeh = await renderer.open(
                {
                    "figure_id": "bokeh-plot",
                    "backend": "bokeh",
                    "width": 720,
                    "height": 432,
                    "screencast": False,
                    "figure": {"script": bokeh_script},
                }
            )
            assert bokeh["backend"] == "bokeh"
            assert bokeh["png"].startswith("iVBOR")
            bokeh_size = await renderer.figures["bokeh-plot"].page.evaluate(
                "() => { const box=Object.values(Bokeh.index)[0].el.getBoundingClientRect(); return [Math.round(box.width),Math.round(box.height)]; }"
            )
            assert bokeh_size == [720, 432]
            network_result = await renderer.figures["push-plot"].page.evaluate(
                "async () => { try { await fetch('https://example.invalid/probe'); return 'allowed'; } catch (_) { return 'blocked'; } }"
            )
            assert network_result == "blocked"
            health = await renderer.health()
            assert len(health["figures"]) == 2
            assert health["network"] == "blocked"
        finally:
            await renderer.shutdown()

    asyncio.run(exercise())
