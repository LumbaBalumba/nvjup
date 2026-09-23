# Isolated Neovim configuration

`init.lua` is independent from `~/.config/nvim`:

- it does not load the user's plugin manager;
- it prepends only this checkout to `runtimepath`;
- `scripts/test-nvim` redirects XDG config/data/state/cache directories;
- language providers are disabled unless a test explicitly enables them;
- no plugin or parser is downloaded automatically.

Run it interactively:

```bash
./scripts/test-nvim tests/fixtures/notebooks/01_markdown_code.ipynb
```

Useful commands:

- `:NvJupTestInfo` — show the active config and isolated XDG paths;
- `:NvJupOpenFixture [name]` — open a generated notebook fixture;
- `:NvJupOutline` — select a notebook cell;
- `:NvJupRefresh` — rebuild extmark rendering after manual marker repair.

Run the headless Stage 1 suite through `./scripts/test`.
