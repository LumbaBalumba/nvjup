from __future__ import annotations

import argparse
import asyncio
import statistics
import time
from typing import Any

from .server import PlotlyRenderer


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * fraction)]


def summary(values: list[float]) -> str:
    if not values:
        return "no samples"
    return (
        f"median={statistics.median(values):.2f} ms "
        f"p90={percentile(values, 0.9):.2f} ms "
        f"min={min(values):.2f} ms max={max(values):.2f} ms"
    )


async def benchmark(width: int, height: int, samples: int) -> None:
    frames: asyncio.Queue[tuple[float, dict[str, Any]]] = asyncio.Queue()

    def on_frame(payload: dict[str, Any]) -> None:
        frames.put_nowait((time.perf_counter(), payload))

    renderer = PlotlyRenderer(on_frame)
    surface = [
        [((x - 20) ** 2 + (y - 20) ** 2) % 37 for x in range(40)] for y in range(40)
    ]
    try:
        opened = await renderer.open(
            {
                "figure_id": "nvjup-benchmark",
                "backend": "plotly",
                "figure": {"data": [{"type": "surface", "z": surface}]},
                "width": width,
                "height": height,
                "interactive_width": min(width, 720),
                "interactive_height": min(height, 432),
                "screencast": True,
                "adaptive_resolution": True,
            }
        )
        await asyncio.sleep(0.2)
        while not frames.empty():
            frames.get_nowait()

        enqueue: list[float] = []
        await renderer.event(
            {
                "figure_id": "nvjup-benchmark",
                "event": "down",
                "x": width / 2,
                "y": height / 2,
            }
        )
        for index in range(samples):
            await asyncio.sleep(1 / 60)
            started = time.perf_counter()
            await renderer.event(
                {
                    "figure_id": "nvjup-benchmark",
                    "event": "move",
                    "x": width / 2 + (index % 12) * 6,
                    "y": height / 2 + (index % 10) * 5,
                }
            )
            enqueue.append((time.perf_counter() - started) * 1000)
        await renderer.event(
            {
                "figure_id": "nvjup-benchmark",
                "event": "up",
                "x": width / 2,
                "y": height / 2,
            }
        )
        await asyncio.sleep(0.5)

        pushed = []
        sizes = []
        while not frames.empty():
            _, frame = frames.get_nowait()
            if frame.get("quality") == "interactive" and frame.get("input_frame"):
                pushed.append(float(frame.get("frame_latency_ms", 0)))
                sizes.append(len(str(frame.get("png", ""))) * 0.75 / 1024)

        print(f"Chromium: {renderer.chromium_path()}")
        print(f"Viewport: {width}x{height}; samples: {samples}")
        print(f"Open: {opened['open_latency_ms']:.2f} ms")
        print(f"Input enqueue: {summary(enqueue)}")
        print(f"Interactive pushed frame: {summary(pushed)}")
        if sizes:
            print(f"Interactive PNG median: {statistics.median(sizes):.1f} KiB")
        print(f"Pushed frames: {len(pushed)} (moves are deliberately coalesced)")
    finally:
        await renderer.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser(description="Profile the nvjup Stage 6 renderer")
    parser.add_argument("--width", type=int, default=900)
    parser.add_argument("--height", type=int, default=540)
    parser.add_argument("--samples", type=int, default=48)
    args = parser.parse_args()
    asyncio.run(benchmark(args.width, args.height, args.samples))


if __name__ == "__main__":
    main()
