# RPC protocol

## Transport

Neovim launches the Jupyter sidecar and optional interactive renderer as separate processes. Version 1 uses newline-delimited JSON over stdin/stdout:

- UTF-8 only;
- one JSON object per line;
- stdout is reserved for protocol messages;
- logs go to stderr;
- messages may arrive asynchronously;
- request IDs are opaque non-empty strings;
- numeric sequence values are monotonically increasing per process.

The schema is [`../../spec/rpc-message.schema.json`](../../spec/rpc-message.schema.json).

## Envelope

Every message contains:

```json
{
  "protocol": "nvjup/1",
  "kind": "request",
  "type": "kernel.start",
  "id": "request-17",
  "seq": 17,
  "notebook_id": "notebook-1",
  "payload": {}
}
```

Fields:

- `protocol`: exact negotiated protocol version;
- `kind`: `request`, `response`, or `event`;
- `type`: namespaced operation/event;
- `id`: required for requests and responses; response ID equals request ID;
- `seq`: process-local ordering value;
- `notebook_id`: routing identity where applicable;
- `cell_id`: stable cell identity for cell-scoped work;
- `revision`: source revision used for execution/LSP/rendering;
- `payload`: operation-specific JSON object;
- `error`: structured error on failed responses.

Unknown envelope fields are ignored for forward compatibility. Unknown `type` values produce an `unsupported_message` error response when a response is possible.

## Core request types

Sidecar lifecycle:

- `sidecar.hello`;
- `sidecar.shutdown`;
- `sidecar.ping`.

Kernel lifecycle:

- `kernel.list`;
- `kernel.start`;
- `kernel.interrupt`;
- `kernel.restart`;
- `kernel.shutdown`.

`kernel.start` normally owns a local ZeroMQ kernel. An optional `remote` object
selects an owned Jupyter Server kernel and contains `url`, an optional `token`,
`verify_ssl`, optional explicit `origin`, bounded `reconnect_attempts`, and an
optional `provider`. `provider = "colab"` switches REST, Contents, and WebSocket
authentication to Colab runtime-proxy query parameters and headers; ordinary
Jupyter behavior remains the default. Credentials are transported only to the
sidecar and never echoed in responses or events. Remote channels must negotiate
`v1.kernel.websocket.jupyter.org`; legacy
unbounded framing is rejected. Existing-kernel attachment is not part of v1.

Execution:

- `execution.enqueue`;
- `execution.cancel`;
- `execution.stdin_reply`;
- `completion.request`;
- `inspect.request`;
- `variables.list`.

Remote server and files:

- `remote.server.probe` returns bounded server metadata and kernelspec names without creating a kernel;
- `remote.files.list`;
- `remote.files.stat`;
- `remote.files.mkdir`;
- `remote.files.touch`;
- `remote.files.rename`;
- `remote.files.delete`;
- `remote.files.download`;
- `remote.files.upload`;
- `remote.files.download_to`;
- `remote.files.upload_from`;
- `remote.files.copy`.

Every remote-file request carries the resolved remote server object inside the
local Neovim↔sidecar channel. It is never echoed. API-style paths are root-relative,
forward-slash-delimited and reject empty, dot, dot-dot, backslash and NUL segments.
Small compatibility calls may use bounded base64 in nvjup RPC. Normal file-manager
transfers use `download_to` / `upload_from`: the sidecar reads or writes a new
local path directly, so file bytes never enter Neovim's newline-delimited JSON
channel. Same-server copies remain inside the sidecar. The sidecar streams
authenticated Jupyter `/files` downloads, enforces configured byte limits before
publishing a local file, removes partial downloads on error, and uses bounded
Contents API models for mutation. RPC messages themselves have a hard configured
size limit and an oversized frame terminates the sidecar connection.

Renderer:

- `renderer.hello`;
- `renderer.open`;
- `renderer.export_external`;
- `renderer.release_external`;
- `renderer.event`;
- `renderer.resize`;
- `renderer.close`;
- `renderer.status`;
- `renderer.shutdown`.

`renderer.open` selects a bounded `plotly` or `bokeh` backend and may negotiate
push screencast frames. `renderer.export_external` writes only the validated,
CSP-restricted standalone document to a private temporary file for Awrit;
`renderer.release_external` removes that export. `renderer.event` acknowledges queued pointer/keyboard
input; the resulting frame can arrive independently. `plotly.*` request aliases
remain accepted for Stage 5 compatibility but are not emitted by current Lua.

## Core event types

- `kernel.state`;
- `kernel.dead`;
- `execution.state`;
- `execution.stream`;
- `execution.display`;
- `execution.display_update`;
- `execution.clear_output`;
- `execution.error`;
- `execution.stdin_request`;
- `execution.widget`;
- `renderer.state`;
- `renderer.frame`;
- `renderer.warning`;
- `renderer.error`;
- `log`.

Raw Jupyter headers are not the public protocol. The sidecar may include selected diagnostic header fields, but Neovim routes execution by normalized `notebook_id`, `cell_id`, request ID, and revision.

## Errors

Structured errors contain:

```json
{
  "code": "kernel_start_failed",
  "message": "Human-readable summary",
  "retryable": false,
  "details": {}
}
```

No stack trace is sent unless debug mode is enabled. Secrets, connection keys, environment variables, and arbitrary notebook contents must not appear in default errors.

## Flow control

- Each execution has a unique execution ID.
- Stream and frame events carry a monotonically increasing per-execution index.
- Neovim may advertise output and frame limits in `sidecar.hello`.
- Renderer frames are replaceable; a newer frame may supersede an unsent older frame.
- Text stream data is ordered and cannot be silently dropped.
- Oversized messages fail with an explicit error or use a future negotiated binary transport.

## Compatibility

`sidecar.hello` exchanges:

- protocol versions;
- sidecar/renderer version;
- supported message types;
- MIME renderers;
- optional capabilities.

Peers must reject an unsupported major protocol. Additive fields and event types within `nvjup/1` are allowed when capability-gated.
