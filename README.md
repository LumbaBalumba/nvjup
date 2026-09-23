# nvjup

`nvjup` is a Neovim-native editor for Jupyter notebooks.

The repository now contains the **Stage 1 notebook editor**:

- `.ipynb` opens as code, Markdown, and raw cells rather than JSON;
- jupynvim-inspired cell borders, headers, execution counts, and output sections;
- concealed structural markers with stable cell IDs;
- next/previous cell and code-cell navigation;
- insert, delete, move, split, merge, and type conversion;
- notebook outline;
- load/save with preservation of metadata, attachments, outputs, and unknown MIME bundles;
- text, stream, error, rich-image, Plotly, and Bokeh output previews;
- undo-aware structural representation;
- independent Neovim test configuration and Docker validation.

Kernel execution, real terminal image placement, interactive Plotly/Bokeh, and LSP shadow documents belong to later stages. Existing rich outputs are currently represented by text or explicit capability placeholders.

The complete roadmap is in [`docs/nvjup-plan.md`](docs/nvjup-plan.md). Normative contracts are indexed in [`docs/spec/README.md`](docs/spec/README.md).

## Requirements

- Neovim 0.11 or newer;
- Python 3.11 or newer and [`uv`](https://docs.astral.sh/uv/) for tests.

The Stage 1 editor itself is pure Lua and has no runtime Python dependency.

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
```

## Run all automated tests

```bash
./scripts/test
```

This runs:

- 15 Python contract/fixture tests;
- headless Neovim tests for loading, rendering, outputs, navigation, structural editing, undo, and round-trip saving.

## Docker

```bash
docker compose build
docker compose run --rm test
```

The container validates contracts and headless rendering semantics. Pixel-level Kitty Graphics Protocol tests require a real Kitty host and will be introduced with terminal image placement.
