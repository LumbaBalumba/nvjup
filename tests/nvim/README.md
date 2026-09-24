# Isolated Neovim configuration

`init.lua` is independent from `~/.config/nvim`:

- it does not load the user's plugin manager;
- it prepends only this checkout to `runtimepath`;
- `scripts/test-nvim` redirects XDG config/data/state/cache directories;
- language providers are disabled unless a test explicitly enables them;
- no plugin, parser, or language server is downloaded automatically;
- automatic LSP startup is disabled in unit tests and enabled explicitly by integration tests.

Run it interactively:

```bash
./scripts/test-nvim tests/fixtures/notebooks/01_markdown_code.ipynb
```

Useful commands:

- `:NvJupTestInfo` — show the active config and isolated XDG paths;
- `:NvJupOpenFixture [name]` — open a generated notebook fixture;
- `:NvJupOutline` — select a notebook cell;
- `:NvJupRefresh` — rebuild extmark rendering after manual marker repair;
- `:NvJupLspStatus` — inspect shadow documents and attached language clients;
- `:NvJupKernelStatus` — inspect kernel transport, generation, queue, and active execution;
- `:NvJupVariables` — inspect public variables in the live kernel;
- `:NvJupRemoteFiles` — open the two-panel Telescope local/remote file manager;
- `:NvJupRunCurrent` / `:NvJupRunAll` — execute code cells through the sidecar;
- `:NvJupOutputOpen [float|split|vsplit|tab]` — inspect complete untruncated output.

Run the Stage 1–8, deterministic LSP, local/remote kernel, Contents API, file-transfer, renderer, widget, and rich-output suites through `./scripts/test`.
Run the installed Pyright/Ruff smoke test through `./scripts/test-real-lsp` and the isolated real `ipykernel` profile through `./scripts/test-real-kernel`.
