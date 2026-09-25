# Stage 8: remote Jupyter files

Stage 8 extends the remote Jupyter Server transport with a bounded file-exchange layer and a two-panel Telescope file manager.

## Connection

The normal workflow is entirely interactive: `:NvJupRemoteConnect` or `<leader>nK` selects a Jupyter Server or Google Colab. The Jupyter flow asks for URL/authentication/TLS/origin. The Colab flow (also `:NvJupColabConnect`) uses the optional official `google-colab-cli`, requests OAuth only when its cached credentials cannot be used, offers CPU/GPU/TPU hardware, and provisions the runtime. Both flows probe kernelspecs and reuse the resulting connection in this file manager. nvjup retains only its imported Colab connection copy in Neovim memory; the official CLI persists OAuth credentials and the runtime proxy/session token in its protected config/state files and owns the keepalive. Disconnecting nvjup leaves the VM running. Until profile activation, cancellation, probe failure, and kernel-picker dismissal report the session ID and a safely quoted recovery command; after activation, disconnect reports the same command. It preserves the allocation's global `--auth` and `--config` arguments. Static Jupyter configuration remains available when desired:

```lua
require("nvjup").setup({
  kernel = {
    remote = {
      url = "https://jupyter.example.org/jupyter",
      token_env = "JUPYTER_TOKEN",
      verify_ssl = true,
      origin = false,
      reconnect_attempts = 2,
      -- Optional per-server overrides:
      file_timeout_seconds = 60,
      max_file_bytes = 64 * 1024 * 1024,
      max_entries = 10000,
    },
  },
  remote_files = {
    -- false starts beside the notebook, or at cwd outside a notebook.
    local_root = false,
    -- Jupyter Contents API path relative to the server root.
    remote_root = "",
    show_hidden = false,
    confirm_delete = true,
    max_file_bytes = 64 * 1024 * 1024,
    max_transfer_bytes = 512 * 1024 * 1024,
    max_entries = 10000,
    timeout_seconds = 60,
  },
})
```

Open the manager with `:NvJupRemoteFiles` from any buffer, or `<leader>ne` from an nvjup notebook. If disconnected, use `:NvJupRemoteConnect` first. Telescope is required only for the file-manager UI; the connection wizard itself uses built-in Neovim UI primitives.

## Two-panel model

Telescope's results window is the **active** filesystem and the preview window is the other filesystem. Both local and remote directory listings are always visible. `<Tab>` swaps their roles while preserving each current directory. Filtering applies to the active panel.

The remote side uses Jupyter Server's authenticated Contents API for metadata and mutation. Downloads prefer the authenticated `/files` byte stream so notebooks and binary files remain byte-identical; the standard Contents model is a bounded fallback. Uploads use base64 Contents models only inside the sidecar. Normal transfers use direct sidecar `download_to` / `upload_from` requests, so large file bytes do not pass through Neovim's JSON RPC or its UI thread. Same-server copies also remain inside the sidecar. No shell command is constructed from a remote path.

## Bindings

The operations follow the default nvim-tree bindings where they are meaningful in a two-panel Telescope picker:

| Mapping | Operation |
|---|---|
| `<Tab>` | switch active local/remote panel |
| `<CR>`, `o` | enter directory or open file |
| `-`, `P`, `<BS>` | parent directory |
| `f` | enter Telescope filter |
| `R` | refresh both filesystems |
| `H` | toggle hidden files |
| `a` | create file; append `/` to create a directory |
| `r`, `e` | rename selected entry |
| `d`, `<Del>` | delete selected entry |
| `c` | copy selected entry into the manager clipboard |
| `x`, `gp` | cut/move selected entry |
| `p` | paste; across panels this uploads or downloads |
| `y` | copy filename |
| `ge` | copy basename without extension |
| `Y` | copy panel-relative name |
| `gy` | copy absolute local or API-style remote path |
| `<C-k>` | show metadata |
| `g?` | show help |
| `q`, `<C-c>` | close |

A cross-filesystem transfer is therefore `c`, `<Tab>`, `p`; use `x`, `<Tab>`, `p` to move. Files and directory trees are supported. Same-server moves use the Contents rename endpoint, while copies are streamed through bounded download/upload operations. Opening a remote file downloads it into the local panel directory and opens that local copy.

## Safety and failure semantics

- API paths reject NUL, backslashes, empty components, `.` and `..` before any request.
- REST redirects are rejected so authorization headers are not forwarded to a redirected endpoint.
- TLS verification remains enabled by default and tokens are never returned in RPC responses, health output, or normal errors.
- Individual files, directory entry counts, aggregate cross-filesystem bytes, response models, request timeouts, and WebSocket frames are bounded.
- Local symlinks are preserved for local-to-local copies. Cross-filesystem copies dereference file symlinks and reject symlinks resolving to unsupported non-files.
- A failed local recursive copy removes its partial target. Remote/cross-directory copies make a best-effort cleanup of the partial target and report the original error.
- Copy is not a distributed transaction. A cross-filesystem move copies first and deletes the source only after success; if source deletion fails, the UI reports that both copies remain.
- Overwriting an existing destination always requires confirmation.

## Tests

Automated coverage includes:

- real UI-only authenticated server probe, kernelspec selection, kernel startup, status and disconnect;
- real authenticated Jupyter Server mkdir/list/stat/upload/download/rename/touch/delete;
- byte-identical binary and Unicode-path notebook transfer;
- path traversal rejection and token redaction;
- local recursive copy/move/delete and hidden-file filtering;
- RPC file operations without starting a kernel;
- a mocked Telescope two-panel picker with nvim-tree mappings and local-to-remote transfer;
- a host E2E against real Telescope confirming distinct results and preview windows.
