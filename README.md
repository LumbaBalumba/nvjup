# nvjup

`nvjup` is a Neovim-native editor for Jupyter notebooks.

The repository now contains the **Stage 3 notebook editor, language tooling, and kernel execution foundation**:

- `.ipynb` opens as code, Markdown, and raw cells rather than JSON;
- jupynvim-inspired cell borders, headers, execution counts, and output sections;
- concealed structural markers with stable cell IDs;
- next/previous cell and code-cell navigation;
- insert, delete, move, split, merge, and type conversion;
- notebook outline;
- load/save with preservation of metadata, attachments, outputs, and unknown MIME bundles;
- text, stream, error, rich-image, Plotly, and Bokeh output previews;
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

Real terminal image placement and interactive Plotly/Bokeh belong to later stages. Rich outputs that do not yet have a Stage 4 renderer are represented by text or explicit capability placeholders.

The complete roadmap is in [`docs/nvjup-plan.md`](docs/nvjup-plan.md). Normative contracts are indexed in [`docs/spec/README.md`](docs/spec/README.md).

## Requirements

- Neovim 0.11 or newer;
- a Tree-sitter parser for every language that should be highlighted;
- an LSP server for every language that should receive language features;
- Python 3.11 or newer with `jupyter_client` for kernel execution;
- an installed kernelspec, such as the one provided by `ipykernel`;
- [`uv`](https://docs.astral.sh/uv/) for the development and test environment.

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
| `<localleader>jo` | insert code cell below |
| `<localleader>jO` | insert code cell above |
| `<localleader>jy` | duplicate cell with cleared execution |
| `<localleader>jd` | delete cell |
| `<localleader>jk` / `<localleader>jj` | move cell up / down |
| `<localleader>js` | split cell at cursor |
| `<localleader>jm` | merge with cell below |
| `<localleader>jt` | cycle code → Markdown → raw |
| `<localleader>jz` | collapse/expand cell source |
| `<localleader>jx` | collapse/expand cell output |
| `<localleader>jc` / `<localleader>jC` | clear current / all outputs |
| `<localleader>jl` | notebook outline |
| `<localleader>jr` | run current cell |
| `<localleader>jn` | run current cell and advance |
| `<localleader>ju` / `<localleader>jb` | run code cells above / below |
| `<localleader>ja` | run all code cells |
| `<localleader>ji` | interrupt kernel |
| `<localleader>jR` | restart kernel |

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

The isolated config sets `<localleader>` to `,`, so insert-below is `,jo` there. All mappings are buffer-local and configurable.

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

The container validates contracts and headless rendering semantics. Pixel-level Kitty Graphics Protocol tests require a real Kitty host and will be introduced with terminal image placement.
