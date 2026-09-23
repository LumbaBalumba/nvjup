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
- `kernel.attach`;
- `kernel.interrupt`;
- `kernel.restart`;
- `kernel.shutdown`.

Execution:

- `execution.enqueue`;
- `execution.cancel`;
- `execution.stdin_reply`;
- `completion.request`;
- `inspect.request`.

Renderer:

- `renderer.start`;
- `renderer.render`;
- `renderer.resize`;
- `renderer.input`;
- `renderer.dispose`;
- `renderer.shutdown`.

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
- `renderer.state`;
- `renderer.frame`;
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
