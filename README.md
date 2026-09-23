# nvjup

`nvjup` is a planned Neovim-native editor and runtime for Jupyter notebooks.

The project is currently at **Stage 0: executable specification and fixtures**. No notebook UI or kernel implementation is present yet. The repository contains the contracts that later stages must satisfy:

- supported `nbformat` subset and lossless round-trip rules;
- Lua ↔ sidecar ↔ renderer protocol;
- kernel, execution, renderer, and trust state machines;
- LSP shadow-document and navigation contract;
- trusted/untrusted notebook policy;
- valid notebook and Jupyter-message fixtures;
- isolated Neovim test configuration;
- local and Docker validation commands.

The full research and implementation plan is in [`docs/nvjup-plan.md`](docs/nvjup-plan.md). Stage 0 specifications are indexed in [`docs/spec/README.md`](docs/spec/README.md).

## Validate Stage 0

Requirements:

- Neovim 0.11 or newer;
- Python 3.11 or newer;
- [`uv`](https://docs.astral.sh/uv/).

Run all checks:

```bash
./scripts/test
```

Run only the Python contract tests:

```bash
uv run --group test pytest
```

Validate the independent Neovim configuration:

```bash
./scripts/test-nvim --headless \
  '+lua assert(vim.g.nvjup_test_config == 1)' \
  '+qa'
```

Open a fixture interactively using the isolated configuration:

```bash
./scripts/test-nvim tests/fixtures/notebooks/01_markdown_code.ipynb
```

At Stage 0 the file is intentionally shown as JSON because the notebook compositor is scheduled for Stage 1. Run `:NvJupTestInfo` to verify that the isolated configuration is active.

## Docker

```bash
docker compose build
docker compose run --rm test
```

The container validates contracts, fixtures, and headless Neovim startup. Visual Kitty Graphics Protocol tests must run on the host in a real Kitty session and will be added with the renderer implementation.
