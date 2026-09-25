# Stage 7: extension and polish

Stage 7 adds live-kernel tooling and optional UI integrations without weakening the notebook, renderer, or trust boundaries established in Stages 1–6.

## Live-kernel tooling

The sidecar supports three bounded shell-channel requests against an **idle** kernel:

- `completion.request` returns at most 512 matches and cursor bounds;
- `inspect.request` returns the kernel's standard MIME inspection bundle;
- `variables.list` evaluates a silent, history-free user expression and returns at most 500 public globals with bounded scalar previews.

Requests time out, reject payloads above 1 MiB, and never race an active execution. The variable expression does not install helper names in the user's namespace. Collection and object values expose their type rather than invoking potentially expensive arbitrary representations.

`:NvJupVariables` / `<leader>nv` opens the variable inspector. Telescope is used when installed and `integrations.telescope` is enabled; otherwise nvjup opens a dependency-free floating table. `<CR>` requests kernel inspection for the selected name, `r` refreshes, and `q` closes.

Live-kernel completion is intentionally optional because shadow-LSP completion remains deterministic and does not require a running kernel:

```lua
require("nvjup").setup({
  completion = {
    kernel = true,
    kernel_timeout_seconds = 2,
  },
})
```

When enabled with nvim-cmp, the lower-priority `nvjup_kernel` source is added beside the primary `nvjup` shadow-LSP source. It never starts a kernel merely because completion was requested.

## Basic widgets and ipympl

The comm bridge forwards a bounded, declarative subset of ipywidget state. Terminal projections are implemented for:

- `LabelModel` and sanitized `HTMLModel`;
- buttons, checkboxes, and toggle buttons;
- text, textarea, and masked password values;
- integer/float text and slider values;
- dropdown, select, and radio-button labels;
- existing progress/HBox output.

No notebook-provided widget JavaScript is loaded or executed. The projection is currently read-only.

For `MPLCanvasModel`, nvjup accepts the synchronized ipympl `_data_url` PNG and `_size` traits, materializes them as ordinary bounded `image/png` output, and reuses the Kitty/chafa image lifecycle. This provides live kernel-driven canvas frames while the backend remains in its data-URL synchronization mode. Browser-grade ipympl toolbar, pointer events, and binary-diff initialization are not emulated; unsupported custom messages remain ignored.

## Optional integrations

### Telescope

`integrations.telescope = true` is the default auto-detect policy. Notebook outline and variable pickers use Telescope only when its modules are available; otherwise existing `vim.ui.select` and floating-window paths remain unchanged.

### Statusline

No statusline plugin dependency is required:

```lua
require("nvjup.statusline").component()
require("nvjup.statusline").get(0)
```

`component()` returns a compact kernel/cell/queue/modified indicator suitable for lualine, heirline, statusline.nvim, or a native `%{%...%}` expression. Outside an nvjup buffer it returns an empty string.

### Health

`:checkhealth nvjup` now reports optional live-kernel completion, Telescope availability, the statusline API, corrected Awrit/TUI bindings, and the existing sidecar, renderer, LSP, graphics, trust, and external-runtime checks.

## Remote Jupyter Server

Remote transport creates an owned kernel through the Jupyter Server REST API. Ordinary Jupyter channels use the negotiated `v1.kernel.websocket.jupyter.org` binary protocol. Google Colab's managed proxy does not negotiate that subprotocol, so Colab uses its default JSON WebSocket framing. Both are bounded and feed the same normalized nvjup RPC/event surface as local ZeroMQ kernels.

### UI-only connection

No remote settings have to be written into Lua. Open a notebook and run `:NvJupRemoteConnect` or `<leader>nK`. The nvjup UI performs the complete client-side workflow:

1. asks for the Jupyter Server base URL;
2. accepts a token through Neovim's hidden secret input, or selects unauthenticated access;
3. confirms HTTPS certificate verification or an explicit HTTP/SSH-tunnel connection;
4. optionally asks for an `Origin` header;
5. probes `/api` and `/api/kernelspecs` without creating a kernel;
6. displays the server kernelspecs and starts the selected owned kernel.

The profile and token live only in Neovim process memory. They are neither written to disk nor placed in command history, notifications, health output, RPC responses, or errors. Reopen `<leader>nK` to show status, reconnect/change server, or disconnect. Global commands are `:NvJupRemoteConnect`, `:NvJupRemoteStatus`, and `:NvJupRemoteDisconnect`. Disconnect shuts down nvjup-owned remote kernels and clears the in-memory credentials. The active connection is also used automatically by `:NvJupRemoteFiles`.

### Static configuration

For unattended setups, the original configuration path remains available:

```lua
require("nvjup").setup({
  kernel = {
    remote = {
      url = "https://jupyter.example.org/jupyter",
      token_env = "JUPYTER_TOKEN",
      verify_ssl = true,
      -- Set only when required by the server's origin policy.
      origin = false,
      reconnect_attempts = 2,
    },
  },
})
```

`token` may instead be a string or a function of `(notebook_path, notebook_state)`. `token_env` avoids storing credentials in the Neovim config. Ordinary Jupyter tokens are sent only in the HTTP `Authorization` header. Managed Colab profiles use the runtime proxy token in Colab's required header and query parameters instead, without a Jupyter `Authorization` header. Tokens are never included in status, health, or errors. URL query/fragment components are discarded. TLS verification defaults to on; disabling it produces a health warning. `origin` is never synthesized and is sent only when explicitly configured.

REST calls and WebSocket frames have time/size bounds, channel queues apply backpressure, unexpected channel loss fails the active request, and idle sessions make at most `reconnect_attempts` reconnects (bounded to 0–5). Interrupt, restart, shutdown, execution, stdin, completion, inspection, and variables all share the remote transport. Restart reconnects the channel; shutdown deletes the owned server kernel. Remote output does **not** receive the ephemeral trust reserved for explicitly run local kernels. Existing-kernel attachment and multi-user authentication flows outside token auth are not enabled.

Stage 8 adds the authenticated Contents API and two-panel Telescope file exchange UI; see [`stage8.md`](stage8.md).

## Validation

Stage 7 tests cover:

- real kernel completion, inspection, and variable listing;
- cell-coordinate completion requests and no-auto-start behavior;
- variable inspector fallback and statusline output;
- basic widget terminal projection;
- ipympl data-URL materialization through the image pipeline;
- optional Telescope fallback and public commands/mappings;
- UI-only authenticated server probe, kernelspec selection, owned-kernel startup, status, and disconnect;
- real authenticated local Jupyter Server execution, completion, restart, and shutdown over REST/WebSocket v1 framing.
