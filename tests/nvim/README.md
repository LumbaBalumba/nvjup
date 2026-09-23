# Isolated Neovim configuration

`init.lua` is intentionally independent from `~/.config/nvim`:

- it does not load the user's plugin manager;
- it prepends only this checkout to `runtimepath`;
- `scripts/test-nvim` redirects XDG data/state/cache/config directories;
- language providers are disabled unless a test enables them;
- no plugins or parsers are downloaded automatically.

Useful commands:

- `:NvJupTestInfo` — show the active config and isolated XDG paths;
- `:NvJupOpenFixture [name]` — open a generated notebook fixture.

Stage 0 deliberately shows `.ipynb` as JSON. Stage 1 will add the notebook compositor through the same isolated harness.
