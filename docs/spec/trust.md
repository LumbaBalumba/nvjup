# Notebook trust and renderer sandbox

## Default policy

Every newly opened notebook is untrusted unless a local trust record matches its content identity. Opening a notebook never executes code, starts a kernel, loads remote resources, or evaluates HTML/JavaScript automatically. Interactive output subsequently produced by an explicitly invoked nvjup local-kernel execution is trusted ephemerally for that cell revision by default.

Trust levels:

- `unknown`: no decision is available;
- `untrusted`: active content is blocked;
- `trusted_static`: kernel execution may be explicitly requested, but active HTML/JS remains blocked;
- `trusted_interactive`: sandboxed Plotly/Bokeh/HTML rendering is allowed;
- `revoked`: a previous decision was explicitly removed.

Trusting a notebook does not automatically execute its cells. Explicit local-kernel execution grants only revision-scoped, in-memory trust to output produced for that cell; it does not create a persisted notebook-wide trust record. `execution.trust_local_kernel = false` disables this default, and an explicit revoke takes precedence.

## Content identity

A trust record is local state and must not be written into notebook metadata by default. It includes:

- canonical absolute path where available;
- hash of executable and active content;
- protocol/policy version;
- granted capability level;
- decision timestamp.

Changes to code, HTML, JavaScript, widget state, Plotly/Bokeh bundles, or external resource declarations invalidate interactive trust. Pure output visibility changes do not.

## Untrusted rendering

Allowed without interactive trust:

- escaped plain text;
- sanitized ANSI;
- Markdown rendered without raw HTML execution;
- decoded PNG/JPEG with resource limits;
- SVG only after sanitization or rasterization;
- static fallback representations from MIME bundles.

Blocked by default:

- JavaScript;
- HTML event handlers;
- remote URLs;
- `file://` access;
- iframe/object/embed;
- notebook-provided browser extensions;
- arbitrary comm/widget models;
- shell commands initiated by rendered content.

## Interactive renderer sandbox

The renderer must use:

- an ephemeral browser profile;
- no inherited authentication/cookies;
- network denied by default;
- local bundled Plotly.js/BokehJS;
- strict Content Security Policy;
- no filesystem access;
- no shell or Neovim RPC capability;
- bounded dimensions, memory, CPU, frame rate, and execution time;
- explicit disposal on output deletion or buffer close.

Requests for blocked resources generate visible diagnostics instead of silent access.

## Remote control

Kitty remote control is not required for graphics. The plugin must not depend on `allow_remote_control` and must not use the user's Kitty control socket without explicit opt-in.

## Secrets and logs

Jupyter connection keys, authorization tokens, environment variables, cell contents, stdin responses, and rendered HTML are sensitive. Default logs contain identifiers and bounded summaries, not raw secret-bearing payloads.
