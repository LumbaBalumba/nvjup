# Stage 5: interactive Plotly proof of concept

Stage 5 validates the remote-framebuffer architecture described in the project plan.
Plotly figures stay inside Neovim/Kitty; no visible browser window is opened.

## Pipeline

1. The kernel emits `application/vnd.plotly.v1+json`.
2. `lua/nvjup/interactive.lua` sends the bounded MIME object to a dedicated renderer process.
3. `python/nvjup_plotly_renderer/server.py` starts headless Chromium through Playwright.
4. The renderer loads the locally installed `plotly.min.js`, creates the figure, and returns a PNG frame.
5. The existing Kitty Unicode-placeholder image backend displays the frame and keeps it attached to notebook virtual lines.
6. Focus mode maps only the rendered image-cell rectangle to figure pixels and forwards hover, button down/up, drag, and wheel events without dropping clicks behind in-flight hover frames.
7. The renderer throttles screenshots to at most 30 frames per second and reports open/frame latency.

The renderer process is separate from both the Jupyter transport sidecar and the notebook kernel.

## Setup

The project environment includes Playwright and Plotly:

```bash
uv sync --frozen --group test
```

A local Chromium executable is required. Discovery checks `NVJUP_CHROMIUM`, then `chromium`, `chromium-browser`, `google-chrome-stable`, and `google-chrome`.

```bash
export NVJUP_CHROMIUM=/usr/bin/chromium
```

Run `:checkhealth nvjup` to inspect renderer dependencies. Docker installs Chromium and runs the renderer integration test.

## Usage

Execute a cell that returns a Plotly figure. The first PNG frame appears asynchronously below the output.

```vim
:NvJupPlotFocus
:NvJupPlotStatus
```

Default mapping: `<leader>nf`. The default focus window is 112 columns by 40 rows (bounded by the current editor), and its image backend can use the full focus dimensions instead of the smaller inline-image limit.

Inside focus mode:

- move the mouse for hover;
- click for Plotly click/legend actions;
- drag to pan/select according to the figure's current Plotly mode;
- use the mouse wheel to zoom;
- press `q` or `<Esc>` to close.

## Security boundary

- Notebook HTML and JavaScript are not passed to the renderer.
- Only the structured Plotly MIME object is accepted.
- Plotly.js is loaded from the renderer's local Python package.
- Chromium HTTP and HTTPS requests are aborted.
- downloads and service workers are disabled;
- figure dimensions and JSON-line message size are bounded;
- stale figures are explicitly closed when outputs disappear.

This is an architectural gate, not the Stage 6 production renderer. Bokeh, keyboard forwarding, crash restart/replay, multiple simultaneously focused figures, trust policy, and deeper performance profiling remain Stage 6 work.

## `tqdm.auto` note

`tqdm.auto` selects an ipywidgets progress bar inside an IPython kernel. Stage 5 includes a deliberately narrow widget adapter for `HBoxModel`, `HTMLModel`, and `FloatProgressModel`/`IntProgressModel`. It renders live progress as terminal text without executing widget JavaScript. Arbitrary ipywidgets remain Stage 7.
