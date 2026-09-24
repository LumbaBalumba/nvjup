# nvjup

`nvjup` is a Neovim-native editor for Jupyter notebooks.

The repository now contains the **Stage 7 notebook editor, kernel/LSP tooling, rich outputs, and production interactive renderer**:

- `.ipynb` opens as code, Markdown, and raw cells rather than JSON;
- jupynvim-inspired cell borders, headers, execution counts, and output sections;
- concealed structural markers with stable cell IDs;
- next/previous cell and code-cell navigation;
- insert, delete, move, split, merge, and type conversion;
- notebook outline;
- load/save with preservation of metadata, attachments, outputs, and unknown MIME bundles;
- text, stream, error, Markdown, sanitized HTML, terminal tables, and rich-image outputs;
- viewport-safe PNG rendering through Kitty Unicode placeholders, with JPEG/SVG/PDF rasterization and chafa/text fallbacks;
- a full-output float/split/tab pager that bypasses inline truncation;
- content-trusted Plotly/Bokeh rendering with an Awrit-powered, zero-screenshot external focus window plus the legacy CDP/Kitty TUI focus fallback;
- bounded terminal projections for progress, label, HTML, button, checkbox, text, slider, and selection ipywidgets;
- live ipympl data-URL canvas frames through the existing bounded image pipeline;
- variable inspector with optional Telescope picker and kernel MIME inspection;
- optional lower-priority live-kernel completion alongside shadow-LSP completion;
- dependency-free statusline API and expanded health diagnostics;
- an in-Neovim remote connection wizard with hidden token entry, TLS/origin policy, live server probing, kernelspec selection, and memory-only credentials;
- a Telescope two-panel local/remote file manager backed by the authenticated Jupyter Contents API;
- undo-aware structural representation;
- one versioned LSP shadow document per code language;
- cross-cell diagnostics, completion, hover, signature help, navigation, references, symbols, semantic tokens, rename, and safe code actions;
- native `nvim-cmp` source for automatic and manually triggered notebook completion;
- automatic project-local `.venv`/`venv` selection for Pyright;
- IPython magic preprocessing that preserves Python expressions for LSP rename, plus UTF-8/UTF-16/UTF-32 source maps;
- projected Tree-sitter highlighting for code and Markdown cells, including mixed-language notebooks;
- an isolated Python sidecar with local `jupyter_client` kernels and opt-in authenticated Jupyter Server REST/WebSocket transport;
- current/advance/above/below/all/range execution through an immutable sequential queue;
- streaming stdout/stderr, execute results, display updates, deferred clears, errors, and stdin;
- interrupt, restart, restart-and-run-all, execution counts, stale-result tracking, and output persistence;
- independent Neovim test configuration and Docker validation.

Pre-existing Plotly and safely serialized Bokeh documents run only after an explicit local content-identity trust grant; output produced by an explicitly run local kernel receives revision-scoped ephemeral trust. Notebook HTML and arbitrary JavaScript are never executed. The ephemeral renderer uses bundled assets, strict CSP, blocked outbound requests, bounded queues and dimensions, and crash replay.

The complete roadmap is in [`docs/nvjup-plan.md`](docs/nvjup-plan.md). Normative contracts are indexed in [`docs/spec/README.md`](docs/spec/README.md).

## Requirements

- Neovim 0.11 or newer;
- a Tree-sitter parser for every language that should be highlighted;
- an LSP server for every language that should receive language features;
- Python 3.11 or newer with `jupyter_client` and `aiohttp` for local/remote kernel execution;
- an installed kernelspec, such as the one provided by `ipykernel`;
- [`uv`](https://docs.astral.sh/uv/) for the development and test environment;
- Kitty or Ghostty for native terminal images (optional; chafa/text fallback otherwise);
- ImageMagick for JPEG/PDF rasterization and an SVG fallback (optional but recommended);
- `rsvg-convert` for bounded SVG rasterization (optional; preferred when available);
- chafa for a terminal-symbol image fallback outside Kitty (optional);
- Playwright, the Python Plotly and Bokeh packages (for local browser assets), and Chromium for inline interactive previews;
- [Awrit](https://github.com/chase/awrit), Kitty remote control, and `KITTY_LISTEN_ON` for the zero-screenshot external focus window (optional; `<leader>nf` uses the TUI fallback);
- nvim-cmp for optional live-kernel completion;
- Telescope for optional outline/variable pickers and the required two-panel remote file manager UI.

The editor and LSP proxy remain pure Lua. Kernel transport runs in a separate Python sidecar and does not depend on `pynvim` or `python3_host_prog`. Python notebooks use `pyright-langserver` and `ruff server` automatically when those executables are available. Missing parsers and servers degrade gracefully.

## Test with the isolated configuration

The recommended first test does not load or modify `~/.config/nvim`:

```bash
cd /home/i3alumba/Projects/Personal/nvjup
./scripts/test-nvim tests/fixtures/notebooks/01_markdown_code.ipynb
```

Inside Neovim:

```vim
:NvJupTestInfo
:NvJupOutline
:NvJupOpenFixture 03_rich_outputs.ipynb
```

The launcher redirects config, data, state, and cache into `.test-runtime/`.

## Default navigation and operations

| Mapping | Action |
|---|---|
| `]c` / `[c` | next / previous cell |
| `]C` / `[C` | next / previous code cell |
| `ic` / `ac` | inner / around cell text object |
| `<leader>na` / `<leader>nb` | insert code cell above / below |
| `<leader>nyy` | duplicate cell with cleared execution |
| `<leader>nd` | delete cell |
| `<leader>nk` / `<leader>nj` | move cell up / down |
| `<leader>nq` | split cell at cursor |
| `<leader>nM` | merge with cell below |
| `<leader>nt` | cycle code → Markdown → raw |
| `<leader>nm` / `<leader>ny` | convert to Markdown / code |
| `<leader>nz` | collapse/expand cell source |
| `<leader>no` | expand/collapse truncated inline output |
| `<leader>np` | open full output in a floating pager |
| `<leader>nf` | open the current Plotly/Bokeh output in the responsive TUI focus window |
| `<leader>nF` | open the current Plotly/Bokeh output in a separate Awrit/Kitty OS window |
| `<leader>nc` / `<leader>nC` | clear current / all outputs |
| `<leader>nl` / `<leader>nL` | notebook outline / refresh display |
| `<leader>nv` | inspect live kernel variables |
| `<leader>nK` | connect to/manage a remote Jupyter Server entirely in the nvjup UI |
| `<leader>ne` | open the two-panel local/remote Jupyter file manager |
| `<C-CR>` | run current cell (Normal and Insert modes) |
| `<S-CR>` / `<leader>nr` | run current cell and advance |
| `<leader>nA` / `<leader>nB` | run code cells above / below |
| `<leader>nR` | run all code cells |
| `<leader>ns` / `<leader>nS` | start / stop kernel |
| `<leader>ni` | interrupt kernel |
| `<leader>nx` | restart kernel |

Language actions intentionally mirror the normal-code mappings from the target Neovim configuration:

| Mapping | Action |
|---|---|
| `gd` / `gD` | definition / declaration |
| `gi` | implementation |
| `<leader>D` | type definition |
| `gr` | references |
| `K` | hover |
| `<leader>ls` | signature help |
| `<C-Space>` | completion in Insert mode |
| `<leader>ra` | rename across code cells |
| `<leader>ca` | safe code action |
| `<localleader>ls` | document symbols |

The notebook mappings follow jupynvim's `<leader>n…`, `<S-CR>`, and `<C-CR>` defaults. nvjup reserves `<leader>n` buffer-locally in every attached `.ipynb`, so a global mapping such as NvChad's line-number toggle cannot consume the notebook prefix. New paths and existing empty/whitespace-only `.ipynb` files both open with one code cell. All mappings are buffer-local and configurable.

Commands:

```text
:NvJupWrite
:NvJupRefresh
:NvJupCellNext
:NvJupCellPrevious
:NvJupCellInsertAbove [code|markdown|raw]
:NvJupCellInsertBelow [code|markdown|raw]
:NvJupCellDuplicate
:NvJupCellDelete
:NvJupCellMoveUp
:NvJupCellMoveDown
:NvJupCellSplit
:NvJupCellMergeBelow
:NvJupCellType [code|markdown|raw]
:NvJupCellToggleSource
:NvJupCellToggleOutput
:NvJupOutputOpen [float|split|vsplit|tab]
:NvJupPlotFocus
:NvJupPlotFocusTui
:NvJupPlotStatus
:NvJupTrustInteractive
:NvJupTrustRevoke
:NvJupTrustStatus
:NvJupCellClearOutput
:NvJupClearAllOutputs
:NvJupOutline
:NvJupVariables
:NvJupRemoteConnect
:NvJupRemoteDisconnect
:NvJupRemoteStatus
:NvJupRemoteFiles
:NvJupRunCurrent
:NvJupRunAndAdvance
:NvJupRunAbove
:NvJupRunBelow
:NvJupRunAll
:[range]NvJupRunRange
:NvJupKernelInterrupt
:NvJupKernelRestart
:NvJupKernelRestartRunAll
:NvJupKernelShutdown
:NvJupKernelStatus
:NvJupLspDefinition
:NvJupLspDeclaration
:NvJupLspImplementation
:NvJupLspTypeDefinition
:NvJupLspReferences
:NvJupLspHover
:NvJupLspSignature
:NvJupLspCompletion
:NvJupLspRename [new_name]
:NvJupLspCodeAction
:NvJupLspSymbols
:NvJupLspSemanticTokens
:NvJupLspStatus
```

## Kernel execution configuration

```lua
require("nvjup").setup({
  sidecar = {
    -- Python that has jupyter_client installed. false auto-detects one.
    python = false,
    -- A complete custom command can be supplied instead.
    command = false,
  },
  kernel = {
    default_name = "python3",
    -- Optional override. By default, project-root .venv/venv is preferred.
    python_path = false,
    -- Optional fallback override when the project has no usable virtualenv.
    system_python = false,
    start_timeout_seconds = 30,
    shutdown_on_close = true,
  },
  execution = {
    trust_local_kernel = true, -- locally produced output is trusted for its cell revision
    allow_stdin = true,
    clear_before_run = true,
    repeat_policy = "queue", -- queue, cancel, or replace
    stop_on_error = true,
  },
})
```

For Python notebooks, nvjup first looks for `.venv/bin/python` or `venv/bin/python` at the project root (and Windows equivalents) and verifies that `ipykernel` is importable. If no usable project environment exists, it falls back to a system Python with `ipykernel`. `kernel.python_path` and `kernel.system_python` provide explicit overrides. The selected executable is sent to the sidecar and used directly as `python -m ipykernel_launcher`; it is therefore independent from the Python that runs the sidecar and from a possibly stale global `python3` kernelspec. Non-Python notebooks continue to use their kernelspec.

Batch commands snapshot cell IDs, source, and revisions before execution and dispatch one cell at a time. Editing a cell while its snapshot is running preserves the returned output but marks it stale (`[*]`). Outputs and execution counts are written back into nbformat on `:write`.

## Rich static output configuration

```lua
require("nvjup").setup({
  render = {
    outputs = true,
    max_output_lines = 12,
    images = {
      enabled = true,
      backend = "auto", -- auto, kitty, chafa, or text
      max_width = 64,
      max_height = 24,
      max_bytes = 10 * 1024 * 1024,
      max_pixels = 16 * 1024 * 1024,
      conversion_timeout_ms = 10000,
    },
  },
})
```

`auto` selects Kitty Unicode placeholders when a compatible terminal UI is attached, then chafa, then a bounded textual fallback. PNG is sent directly. JPEG and the first PDF page use ImageMagick; sanitized SVG prefers `rsvg-convert` and falls back to ImageMagick. Image IDs are cached by output content and deleted when output changes, is collapsed/cleared, or the notebook buffer closes. Unicode placeholders are part of extmark virtual lines, so images naturally follow scrolling, resizing, folds, and hidden windows without Kitty remote control.

Stream rendering implements bare-carriage-return overwrite semantics used by console tqdm and similar progress bars. `tqdm.auto` selects ipywidgets in a Jupyter kernel, so nvjup also projects the bounded HBox/HTML/progress model subset into a live terminal progress bar. Arbitrary widget JavaScript remains disabled.

HTML is never executed. Stage 4 strips active elements and renders ordinary text or `<table>` content in the terminal. SVG with scripts, event handlers, external references, entities, or embedded objects is rejected before rasterization. Image byte, pixel, conversion-time, memory, and disk limits are configurable.

Use `<leader>no` to toggle the inline `max_output_lines` limit for the current cell. Use `<leader>np` or `:NvJupOutputOpen` to inspect complete output without truncation in a pager; the command also accepts `split`, `vsplit`, or `tab`.

See [`docs/stage4.md`](docs/stage4.md) for lifecycle, fallback, and security details.

## Interactive Plotly and Bokeh

Plotly MIME output and safely extracted Bokeh standalone document JSON are rendered by a dedicated Playwright/Chromium process with locally installed assets and blocked outbound requests. Output produced by nvjup's local kernel is trusted by default only for the executed cell revision; editing that cell invalidates the ephemeral grant. Pre-existing notebook output remains blocked until `:NvJupTrustInteractive` records the current notebook content identity locally. Use `execution.trust_local_kernel = false` for strict manual trust, `:NvJupTrustStatus` to inspect trust, and `:NvJupTrustRevoke` to revoke it.

`<leader>nF` / `:NvJupPlotFocus` exports the already validated standalone document to a mode-`0600` temporary HTML file and opens it with Awrit in a separate Kitty OS window. Awrit uses Electron offscreen paint events, raw shared-memory buffers, and Kitty animation-frame composition, so browser input is native and interaction does not wait for screenshot capture, PNG/base64 transport, Neovim redraws, or image replacement.

`<leader>nf` / `:NvJupPlotFocusTui` opens the in-Neovim focus mode. It sizes the browser viewport and responsive Plotly/Bokeh layout to the actual popup grid, keeps the current frame visible until its replacement has started painting, pushes damage-driven PNG frames through CDP screencast, coalesces high-rate moves, and forwards pointer/keyboard input. Exported HTML keeps the same local assets, renderer-owned Bokeh targets, strict CSP, content trust, and network denial policy. Closing/replacing output, revoking trust, or closing the notebook closes the managed Awrit window and removes the temporary file.

```lua
require("nvjup").setup({
  interactive = {
    enabled = true,
    command = false, -- optional renderer command override
    awrit_command = { "awrit" },
    awrit_disable_gpu = true, -- stable Electron CPU offscreen paint path
    width_px = 900,
    height_px = 540,
    interactive_width_px = 720,
    interactive_height_px = 432,
    focus_width = 112,
    focus_height = 40,
    screencast = true,
    adaptive_resolution = true,
    require_trust = true,
    max_figures = 8,
    max_fps = 60,
  },
})
```

See [`docs/stage6.md`](docs/stage6.md) for lifecycle, trust, sandbox, recovery, and performance details. Use `./scripts/benchmark-renderer` for a local 3D renderer profile.

## Stage 7 live tooling and integrations

```lua
require("nvjup").setup({
  kernel = {
    -- false for a local owned kernel, or an authenticated Jupyter Server:
    remote = false,
    -- remote = {
    --   url = "https://jupyter.example.org/jupyter",
    --   token_env = "JUPYTER_TOKEN",
    --   verify_ssl = true,
    --   reconnect_attempts = 2,
    -- },
  },
  remote_files = {
    local_root = false, -- notebook directory, or cwd outside a notebook
    remote_root = "", -- path relative to the Jupyter Server root
    show_hidden = false,
    confirm_delete = true,
    max_file_bytes = 64 * 1024 * 1024,
    max_transfer_bytes = 512 * 1024 * 1024,
    max_entries = 10000,
    timeout_seconds = 60,
  },
  completion = {
    kernel = false, -- opt in to the lower-priority nvjup_kernel nvim-cmp source
    kernel_timeout_seconds = 2,
  },
  inspector = {
    max_variables = 200,
    timeout_seconds = 5,
    width = 88,
    height = 24,
  },
  integrations = {
    telescope = true, -- auto-detect; required for remote files, optional elsewhere
  },
})
```

Use `:NvJupVariables` or `<leader>nv` for the live variable inspector. Statusline plugins can call `require("nvjup.statusline").component()`. Basic ipywidgets are projected as safe terminal UI, while ipympl `_data_url` frames reuse the bounded image renderer.

The preferred remote workflow needs no Lua configuration or environment variable: open a notebook and run `:NvJupRemoteConnect` or `<leader>nK`. nvjup asks for the URL, accepts the token through hidden input, asks for TLS/origin policy, probes the server, shows its kernelspecs, remembers the selected connection only in Neovim memory, and starts the chosen kernel. Reopen the same UI to inspect, reconnect, change server, or disconnect. `:NvJupRemoteStatus` and `:NvJupRemoteDisconnect` are also available globally. Static `kernel.remote` configuration remains supported for unattended setups. See [`docs/stage7.md`](docs/stage7.md).

`:NvJupRemoteFiles` or `<leader>ne` opens a two-panel Telescope manager using the active UI or configured connection: the results and preview windows show the active and inactive local/remote filesystems, and `<Tab>` switches them. The nvim-tree-style `a/r/e/d/c/x/p/R/H/P/g?` operations include recursive copies and moves; `c`, `<Tab>`, `p` copies between filesystems. See [`docs/stage8.md`](docs/stage8.md) for the complete binding table, limits, and failure semantics.

## Language tooling configuration

```lua
require("nvjup").setup({
  treesitter = { enabled = true },
  lsp = {
    auto_start = true,
    -- Optional override; otherwise .venv/bin/python is detected from root_dir.
    python_path = false,
    servers = {
      python = {
        {
          name = "nvjup-pyright",
          cmd = { "pyright-langserver", "--stdio" },
          settings = { python = { analysis = {} } },
        },
        { name = "nvjup-ruff", cmd = { "ruff", "server" } },
      },
    },
  },
})
```

The notebook `metadata.language_info.name` chooses the primary language. A code cell can override it through `cell.metadata.language`, `cell.metadata.languageId`, `cell.metadata.nvjup.language`, or `cell.metadata.vscode.languageId`.

Tree-sitter parses each cell independently and projects captures into the composite buffer. This avoids treating Markdown and code as one language and does not require generated fenced-code wrappers.

Because language servers are attached to hidden shadow buffers, the ordinary `nvim_lsp` completion source cannot see them from the visible notebook buffer. When `nvim-cmp` is installed, nvjup registers a dedicated `nvjup` source and adds it to the notebook's buffer-local source list. Existing `buffer`, `path`, snippets, and other completion sources remain enabled. Setting `completion.kernel = true` adds the optional lower-priority `nvjup_kernel` source when a live kernel is already idle; typing never starts a kernel implicitly.

For Python, nvjup searches the project root for `.venv/bin/python`, `venv/bin/python`, and their Windows equivalents. An explicitly configured `lsp.python_path` takes precedence, followed by `$VIRTUAL_ENV` and the system Python.

## Run all automated tests

```bash
./scripts/test
```

This runs:

- Python contract/fixture tests;
- Stage 1 headless notebook editor tests;
- Stage 2 source-map and Tree-sitter tests;
- a real Neovim LSP client against a deterministic protocol test server;
- Stage 3 queue, lifecycle, output-routing, stdin, and stale-result tests;
- Stage 4 HTML/table, MIME selection, SVG security, Kitty protocol, conversion, cleanup, fallback, and pager tests;
- Stage 5 Plotly MIME/cache lifecycle tests;
- Stage 6 trust/invalidation/recovery tests plus real Plotly/Bokeh Chromium screencast, pointer, keyboard, resize, and sandbox tests;
- Stage 7 variable-inspector, kernel-completion, widget/ipympl, Telescope/statusline, and real remote Jupyter Server transport tests;
- Stage 8 local/remote filesystem, real Contents API, binary transfer, traversal security, and two-panel Telescope tests;
- real `ipykernel` execution, completion, inspection, variables, interruption, restart, and sequential batch tests.

To validate the installed Pyright and Ruff servers on the host:

```bash
./scripts/test-real-lsp
```

That test verifies a real cross-cell Pyright definition jump. To run only the real kernel integration profile:

```bash
./scripts/test-real-kernel
```

## Docker

```bash
docker compose build
docker compose run --rm test
```

The container includes ImageMagick and chafa and validates conversion, fallback, Kitty protocol encoding, lifecycle cleanup, and headless rendering semantics. Actual terminal pixels still require a real Kitty/Ghostty host; run `:checkhealth nvjup` and then:

```bash
./scripts/test-kitty-images
```

The host-only script opens `03_rich_outputs.ipynb` under the isolated configuration for visual PNG/SVG/table verification.
