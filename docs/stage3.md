# Stage 3: Jupyter kernel execution

Stage 3 adds kernel execution without moving Jupyter transport into Neovim.

## Architecture

Neovim starts `python/nvjup_sidecar_main.py` as a separate process. The sidecar uses `jupyter_client`; it does not use `pynvim` or `python3_host_prog`. Communication is newline-delimited JSON over stdin/stdout using `nvjup/1`. Sidecar logs and kernel diagnostics stay on stderr.

The Lua frontend owns:

- cell selection and immutable batch snapshots;
- the sequential execution queue;
- cell status and stale-result decisions;
- nbformat output mutation and persistence;
- stdin UI and notebook rendering.

The Python sidecar owns:

- kernelspec discovery;
- start, interrupt, restart, shutdown, and death detection;
- shell, control, stdin, heartbeat, and IOPub channels;
- parent-message filtering;
- normalized execution events.

One sidecar and one owned kernel are created lazily per open notebook. Closing the notebook shuts them down by default.

## Execution semantics

`run current`, `run and advance`, `run above`, `run below`, `run all`, and `run range` snapshot ordered code-cell IDs, source strings, and revisions. Markdown and raw cells are skipped. Only one snapshot is sent at a time.

`execution.repeat_policy` controls a repeated request for an already queued or running cell:

- `queue`: retain every snapshot;
- `cancel`: cancel the existing request and do not enqueue another;
- `replace`: cancel/remove older work and enqueue the latest snapshot.

When `execution.stop_on_error` is true, a failed snapshot cancels the unsent remainder of its batch. Other independently queued batches remain available.

A source edit does not discard kernel output. If the visible cell no longer matches the execution revision, the result is stored and shown as stale (`[*]`). Starting a new execution clears the stale flag.

## Kernel and execution states

Kernel states follow the Stage 0 contract: `stopped`, `starting`, `idle`, `busy`, `interrupting`, `restarting`, `shutting_down`, `dead`, and `error`.

Cell headers use:

```text
[ ] not executed
[…] queued or sent
[▶] running
[?] waiting for stdin
[12] completed with execution count 12
[!] failed
[×] cancelled
[*] stale
```

Restart cancels old-generation work. Unexpected kernel death emits `kernel.dead`, fails active work, and cancels queued work. A later execution starts a fresh owned kernel.

## Output routing

The sidecar normalizes and orders:

- `stream`;
- `execute_result`;
- `display_data`;
- `update_display_data`;
- `clear_output` including `wait=true`;
- `error`;
- `input_request`.

Lua stores standard nbformat outputs. Consecutive streams with the same name are coalesced. `display_id` is kept only in the live routing table and is not persisted because it is transient Jupyter metadata. `update_display_data` replaces the matching live display. A deferred clear is applied immediately before the next output.

Every output mutation marks the notebook modified. `:write` persists outputs and execution counts through the existing atomic, lossless nbformat path.

## Stdin

Normal input requests use `vim.ui.input`. Password requests use `inputsecret()`. The reply is routed by execution ID. Interrupt and restart release pending stdin waits.

## Commands

```text
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
:NvJupCellClearOutput
:NvJupClearAllOutputs
```

## Configuration

```lua
require("nvjup").setup({
  sidecar = {
    python = false,
    command = false,
    request_timeout_ms = 60000,
    stderr_limit = 16384,
  },
  kernel = {
    default_name = "python3",
    start_timeout_seconds = 30,
    shutdown_on_close = true,
  },
  execution = {
    allow_stdin = true,
    clear_before_run = true,
    repeat_policy = "queue",
    stop_on_error = true,
  },
})
```

`sidecar.python` must point to a Python installation containing `jupyter_client`. When it is false, nvjup probes the checkout `.venv`, `$VIRTUAL_ENV`, `python3_host_prog`, `python3`, and the system Python and selects the first compatible interpreter. `sidecar.command` replaces the entire launch command. The notebook's `metadata.kernelspec.name` overrides `kernel.default_name`.

## Validation

Run all profiles:

```bash
./scripts/test
```

Run only the real kernel profile:

```bash
./scripts/test-real-kernel
```

Coverage includes real streams, execute results, display/update/clear routing, errors, stdin, interrupt, restart, kernel death, multiple queued executions, Lua sequential queues, stop-on-error, stale tracking, and output persistence.
