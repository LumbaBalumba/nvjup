# Stage 0 acceptance criteria

Stage 0 is complete when the repository provides an internally consistent, executable contract for later implementation.

## Required artifacts

- supported nbformat subset and lossless round-trip definition;
- versioned RPC schema;
- kernel, execution, renderer, and trust state machines;
- trust and sandbox policy;
- LSP/source-map/navigation contract;
- notebook and live-message fixtures covering the planned surface;
- isolated Neovim configuration;
- automated tests;
- Docker test image and instructions.

## Fixture coverage

The manifest must cover:

- Markdown and code cells;
- stream and error outputs;
- stdin request transcript;
- matplotlib-compatible PNG;
- rich HTML/SVG/LaTeX;
- `display_id` update transcript;
- `clear_output` transcript;
- attachments;
- unknown metadata and MIME data;
- Plotly;
- Bokeh;
- large output;
- Unicode and LSP mapping cases.

## Automated checks

Tests must prove:

1. every notebook fixture parses and validates with `nbformat`;
2. every fixture survives an in-memory nbformat round-trip;
3. the manifest references existing files and required capabilities;
4. every protocol transcript line validates against the RPC schema;
5. request/response IDs and sequence numbers are coherent;
6. state-machine transitions reference declared states and all non-initial states are reachable;
7. the independent Neovim config starts headlessly without reading the user config.

Visual Kitty behavior is outside Stage 0 because no renderer exists yet. Docker validates contracts and headless startup; real Kitty E2E begins with the static renderer stage.

## Stage 4 acceptance criteria

Stage 4 is complete when:

1. Markdown, sanitized HTML, and bounded HTML tables render without executing active content;
2. PNG uses Kitty Unicode placeholders in a compatible attached terminal;
3. JPEG, safe SVG, and the first PDF page rasterize with resource and timeout limits;
4. unsafe SVG and oversized image payloads produce visible diagnostics;
5. chafa and text fallbacks work without Kitty;
6. placements follow viewport redraw and are deleted on replacement, collapse, clear, and buffer close;
7. a float/split/tab pager exposes untruncated output;
8. MIME bundles and metadata still round-trip unchanged;
9. headless tests validate protocol encoding, placeholder structure, conversion, security, ordering, fallback, and cleanup;
10. a host-only isolated visual test is available for real Kitty/Ghostty pixels.

## Stage 6 acceptance criteria

Stage 6 is complete when:

1. Plotly and supported standalone Bokeh MIME render from local assets only;
2. interactive rendering is blocked until a local content-identity record grants `trusted_interactive`;
3. code or active-output changes invalidate trust without modifying notebook metadata;
4. Chromium denies network, file, service-worker, download, frame, object, and worker capabilities;
5. damage-driven push frames have acknowledged backpressure and a pull-capture fallback;
6. move/wheel events coalesce while button, release, and keyboard ordering is preserved;
7. focus mode supports pointer, wheel, bounded keyboard input, and resize;
8. multiple figures have independent pages and lifecycle cleanup;
9. renderer crashes replay only still-trusted cached figures with bounded retries;
10. status exposes frame/input metrics and tests cover trust, sandbox, Bokeh, recovery, cleanup, and performance-sensitive paths.
