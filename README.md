# nvjup

`nvjup` is a Neovim-native editor for Jupyter notebooks.

The repository now contains the **Stage 2 notebook editor and language tooling foundation**:

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
- IPython magic preprocessing and UTF-8/UTF-16/UTF-32 source maps;
- projected Tree-sitter highlighting for code and Markdown cells, including mixed-language notebooks;
- independent Neovim test configuration and Docker validation.

Kernel execution, real terminal image placement, and interactive Plotly/Bokeh belong to later stages. Existing rich outputs are currently represented by text or explicit capability placeholders.

The complete roadmap is in [`docs/nvjup-plan.md`](docs/nvjup-plan.md). Normative contracts are indexed in [`docs/spec/README.md`](docs/spec/README.md).

## Requirements

- Neovim 0.11 or newer;
- a Tree-sitter parser for every language that should be highlighted;
- an LSP server for every language that should receive language features;
- Python 3.11 or newer and [`uv`](https://docs.astral.sh/uv/) for tests.

The editor and LSP proxy are pure Lua and have no runtime Python dependency. Python notebooks use `pyright-langserver` and `ruff server` automatically when those executables are available. Missing parsers and servers degrade gracefully.

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
| `<localleader>jc` | clear cell output |
| `<localleader>jl` | notebook outline |

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
:NvJupOutline
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

## Language tooling configuration

```lua
require("nvjup").setup({
  treesitter = { enabled = true },
  lsp = {
    auto_start = true,
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

## Run all automated tests

```bash
./scripts/test
```

This runs:

- Python contract/fixture tests;
- Stage 1 headless notebook editor tests;
- Stage 2 source-map and Tree-sitter tests;
- a real Neovim LSP client against a deterministic protocol test server.

To validate the installed Pyright and Ruff servers on the host:

```bash
./scripts/test-real-lsp
```

That test verifies a real cross-cell Pyright definition jump.

## Docker

```bash
docker compose build
docker compose run --rm test
```

The container validates contracts and headless rendering semantics. Pixel-level Kitty Graphics Protocol tests require a real Kitty host and will be introduced with terminal image placement.
