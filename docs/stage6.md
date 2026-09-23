# Stage 6: production interactive renderer

Stage 6 promotes the Stage 5 Plotly proof of concept into a content-trusted Plotly/Bokeh renderer with an Awrit-powered external browser surface, push-frame TUI fallback, recovery, and explicit lifecycle diagnostics.

## Trust workflow

Interactive output is blocked by default. Opening a notebook does not start Chromium or execute active MIME content.

```vim
:NvJupTrustStatus
:NvJupTrustInteractive
:NvJupTrustRevoke
```

The grant is stored locally under `stdpath("state")/nvjup/trust.json`, with mode `0600` where supported. The notebook is not modified. A record contains the canonical path, policy version, capability, timestamp, and SHA-256 identity—not cell source or output bodies.

The identity covers cell types and sources, active HTML/JavaScript, Plotly/Bokeh payloads, widget views/state, attachments, and document widget metadata. Changing code or active content invalidates an existing grant. Kernel execution remains a separate explicit action.

`interactive.require_trust = false` exists for controlled compatibility environments, but `:checkhealth nvjup` reports the bypass as unsafe.

## Supported interactive data

- `application/vnd.plotly.v1+json` is rendered with the locally installed `plotly.min.js`.
- Bokeh `application/vnd.bokehjs_exec.v0+json` is supported when it contains structured standalone data or the sibling, version-generated `application/javascript` contains parseable `const docs_json = ...` and `const render_items = ...` assignments.
- The notebook-provided Bokeh script is **not executed**. Only the two JSON values are decoded; rendering uses locally bundled BokehJS.
- Serialized `CustomJS*` models and string `code` fields are rejected before BokehJS sees the document; notebook target IDs are replaced with renderer-owned IDs. CSP also disables script attributes and dynamic evaluation.
- Arbitrary HTML, JavaScript, widgets, server-backed Bokeh sessions, and notebook extensions remain blocked.

Bokeh serialization versions must be compatible with the locally installed BokehJS version. Unsupported payloads receive a visible renderer error without changing the original MIME bundle.

## Awrit external focus

`<leader>nf` / `:NvJupPlotFocus` is the default interaction path. The renderer writes the already validated standalone Plotly/Bokeh document to a mode-`0600` temporary file and Neovim launches `awrit file://…` in a separate Kitty OS window through Kitty remote control.

This follows Awrit's rendering path rather than nvjup's screenshot path: Electron emits offscreen `paint` bitmaps, Awrit places raw RGBA buffers in POSIX shared memory, and Kitty atomically composites animation frames into a persistent placement. Mouse and keyboard events go directly to Electron `webContents`. There is no CDP screenshot, PNG/base64 frame RPC, Neovim redraw, or image-ID replacement in the interaction loop.

Requirements are `awrit`, `kitty`, and a working `KITTY_LISTEN_ON` socket. Configure a non-default executable with `interactive.awrit_command`. `awrit_disable_gpu = true` is the default because Awrit consumes Electron CPU bitmaps and the GPU/Wayland offscreen path can repeatedly lose GBM contexts; set it to `false` only after validating the local Electron stack. Only one external focus window is managed at a time. Removing the output, revoking trust, closing the notebook, or shutting down Neovim closes it and removes the temporary file.

Awrit currently describes itself as unmaintained; installations should pin/audit the chosen revision. nvjup passes it only locally generated, CSP-restricted content and never a notebook-provided URL or script wrapper.

## TUI frame pipeline

`<leader>nF` / `:NvJupPlotFocusTui` retains the previous in-Neovim implementation:

1. The renderer creates one isolated page per visible interactive figure.
2. The initial frame uses `page.screenshot()` over the exact viewport. This avoids Playwright locator stability waits.
3. CDP `Page.startScreencast` pushes PNG frames when Chromium reports framebuffer damage.
4. Every frame is acknowledged with `Page.screencastFrameAck`.
5. Lua accepts monotonically sequenced frames and sends them through the Kitty Unicode-placeholder image path.
6. Pull screenshots remain available when screencast startup fails.

Mouse input is accepted into a bounded renderer queue immediately. Consecutive move events are replaced by the newest position and wheel deltas are merged; button press/release and keys preserve ordering. Chromium input uses direct CDP dispatch. This prevents a software-rendered 3D scene from blocking Neovim's event queue.

During interaction, screencast output is bounded to `interactive_width_px × interactive_height_px` (default `720×432`). After 150 ms idle it returns to `width_px × height_px` (default `900×540`). Event coordinates always use the full source viewport.

## TUI focus input and resize

`<leader>nF` or `:NvJupPlotFocusTui` opens the fallback Plotly/Bokeh TUI focus mode. Supported input:

- move, click, drag, release;
- wheel zoom;
- arrows, Enter, Space, Tab, Backspace, `+`, `-`, and `=`;
- `q` or `<Esc>` closes the focus window.

`WinResized` resizes the focus window and sends `renderer.resize`; Plotly receives `Plots.resize`, while Bokeh views receive layout resize requests.

## Recovery and cleanup

The Lua cache retains only the validated serialized figure and latest PNG. If the renderer process exits unexpectedly, pending entries transition to an error state and are replayed into a fresh process up to `interactive.restart_attempts` times. Untrusted or invalidated entries are never replayed.

Deleting or replacing output sends `renderer.close`, removes its exported HTML, and closes a managed Awrit window. Buffer teardown disposes all owned pages, external windows, and Kitty images. `VimLeavePre` requests renderer shutdown. Screencasts, CDP sessions, idle restoration tasks, and input workers are cancelled before a page closes.

## Sandbox

The inline Chromium context is ephemeral and has no inherited cookies or permissions. Downloads and service workers are disabled, and context routing aborts every request. Both inline and Awrit documents use a CSP that denies network connections, frames, objects, media, workers, forms, and base URLs; only inline bundled scripts/styles and data/blob images are allowed. Exported files contain renderer-generated HTML only, have mode `0600`, and are deleted with their figure lifecycle.

Figure payloads, protocol messages, viewport dimensions, frame cadence, queues, and renderer operations are bounded. The renderer has no Neovim RPC or shell capability.

## Performance

Profiling host: Ryzen 9 9950X, Chromium with SwiftShader software rendering, `900×540` source viewport.

Stage 5 baseline:

| Workload | Median frame period |
|---|---:|
| 2D scatter | 67 ms |
| 3D surface | 100 ms |

The main cause was synchronization rather than transport: locator screenshot took about 50 ms wall time but only 20.5 ms aggregate process-tree CPU. Python/Lua JSON, base64, and Kitty command construction were each below 0.2 ms.

Stage 6 changes:

- viewport screenshot: about 16–20 ms instead of 50 ms locator capture;
- pull fallback deadline measured from the previous frame start, not completion;
- push screencast prototype: about 16.7 ms event-to-frame for a simple damaged frame;
- direct CDP 3D drag input: about 33 ms instead of 94 ms through Playwright mouse dispatch;
- production 3D burst test at 60 input events/s with input-sequence correlation: enqueue response around 0.01 ms, interactive pushed-frame median about 15.0 ms and P90 about 27.8 ms in a representative 25-sample run with the 60 FPS cap; moves were coalesced from 25 submissions to 14 rendered states, and idle full-quality restoration frames were excluded.

`:NvJupPlotStatus` requests renderer health and reports figures, backend, push/fallback state, quality, blocked requests, frame count, and component latency metrics. Run `./scripts/benchmark-renderer` for a reproducible 3D burst profile; `--width`, `--height`, and `--samples` adjust the workload.

Hardware GPU flags are not forced. On the profiling host ANGLE OpenGL did not improve capture and Vulkan regressed because readback and PNG encoding dominate. SwiftShader remains the portable default.

## Configuration

```lua
require("nvjup").setup({
  interactive = {
    enabled = true,
    awrit_command = { "awrit" },
    awrit_disable_gpu = true,
    width_px = 900,
    height_px = 540,
    interactive_width_px = 720,
    interactive_height_px = 432,
    focus_width = 112,
    focus_height = 40,
    screencast = true,
    adaptive_resolution = true,
    require_trust = true,
    trust_file = false,
    restart_attempts = 2,
    restart_delay_ms = 150,
    max_figures = 8,
    max_fps = 60,
  },
})
```

## Validation

`./scripts/test` covers:

- trust grant, revocation, content invalidation, and no-source persistence;
- blocked output without Chromium startup;
- crash replay;
- Plotly pull and push frames;
- Bokeh standalone rendering from local assets;
- CSP-restricted external export lifecycle and Awrit launcher routing;
- multiple figures, resize, pointer and keyboard input;
- CSP/network denial;
- frame sequencing, queue behavior, static image regressions, and existing notebook/kernel/LSP behavior.
