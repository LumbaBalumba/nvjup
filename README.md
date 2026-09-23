# nvjup

`nvjup` is a Neovim-native editor for Jupyter notebooks.

The repository now contains the **Stage 4 notebook editor, language tooling, kernel execution, and rich static output foundation**:

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
- explicit Plotly and Bokeh capability placeholders pending the interactive renderer;
- undo-aware structural representation;
- one versioned LSP shadow document per code language;
- cross-cell diagnostics, completion, hover, signature help, navigation, references, symbols, semantic tokens, rename, and safe code actions;
- native `nvim-cmp` source for automatic and manually triggered notebook completion;
- automatic project-local `.venv`/`venv` selection for Pyright;
- IPython magic preprocessing that preserves Python expressions for LSP rename, plus UTF-8/UTF-16/UTF-32 source maps;
- projected Tree-sitter highlighting for code and Markdown cells, including mixed-language notebooks;
- an isolated Python `jupyter_client` sidecar with owned kernel lifecycle;
- current/advance/above/below/all/range execution through an immutable sequential queue;
- streaming stdout/stderr, execute results, display updates, deferred clears, errors, and stdin;
- interrupt, restart, restart-and-run-all, execution counts, stale-result tracking, and output persistence;
- independent Neovim test configuration and Docker validation.

Interactive Plotly/Bokeh belongs to Stages 5 and 6. Active HTML/JavaScript remains blocked; Stage 4 only renders a safe static subset and rasterized images.

The complete roadmap is in [`docs/nvjup-plan.md`](docs/nvjup-plan.md). Normative contracts are indexed in [`docs/spec/README.md`](docs/spec/README.md).

## Requirements

- Neovim 0.11 or newer;
- a Tree-sitter parser for every language that should be highlighted;
- an LSP server for every language that should receive language features;
- Python 3.11 or newer with `jupyter_client` for kernel execution;
- an installed kernelspec, such as the one provided by `ipykernel`;
- [`uv`](https://docs.astral.sh/uv/) for the development and test environment;
- Kitty or Ghostty for native terminal images (optional; chafa/text fallback otherwise);
- ImageMagick for JPEG/SVG/PDF rasterization (optional but recommended);
- chafa for a terminal-symbol image fallback outside Kitty (optional).

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
| `<leader>no` | collapse/expand cell output |
| `<leader>np` | open full output in a floating pager |
| `<leader>nc` / `<leader>nC` | clear current / all outputs |
| `<leader>nl` / `<leader>nL` | notebook outline / refresh display |
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
:NvJupCellClearOutput
:NvJupClearAllOutputs
:NvJupOutline
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

`auto` selects Kitty Unicode placeholders when a compatible terminal UI is attached, then chafa, then a bounded textual fallback. PNG is sent directly. JPEG, sanitized SVG, and the first PDF page are rasterized through ImageMagick. Image IDs are cached by output content and deleted when output changes, is collapsed/cleared, or the notebook buffer closes. Unicode placeholders are part of extmark virtual lines, so images naturally follow scrolling, resizing, folds, and hidden windows without Kitty remote control.

HTML is never executed. Stage 4 strips active elements and renders ordinary text or `<table>` content in the terminal. SVG with scripts, event handlers, external references, entities, or embedded objects is rejected before rasterization. Image byte, pixel, conversion-time, memory, and disk limits are configurable.

Use `<leader>np` or `:NvJupOutputOpen` to inspect complete output without `max_output_lines` truncation. The command also accepts `split`, `vsplit`, or `tab`.

See [`docs/stage4.md`](docs/stage4.md) for lifecycle, fallback, and security details.

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

Because language servers are attached to hidden shadow buffers, the ordinary `nvim_lsp` completion source cannot see them from the visible notebook buffer. When `nvim-cmp` is installed, nvjup registers a dedicated `nvjup` source and adds it to the notebook's buffer-local source list. Existing `buffer`, `path`, snippets, and other completion sources remain enabled.

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
- real `ipykernel` execution, interruption, restart, and sequential batch tests.

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
