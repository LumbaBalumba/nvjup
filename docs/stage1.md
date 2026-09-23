# Stage 1 implementation notes

## Implemented

- `BufReadCmd`/`BufNewFile` support for `*.ipynb`.
- Pure-Lua nbformat 4 loading and atomic saving.
- Preservation of notebook/cell metadata, attachments, outputs, unknown MIME bundles, and missing legacy cell IDs.
- Composite notebook buffer with stable, concealed structural markers.
- Marker escaping when notebook source resembles an internal marker.
- Extmark rendering inspired by jupynvim:
  - cell header and footer;
  - active-cell highlight;
  - left/right borders repeated on every wrapped visual row;
  - word-aware wrapping with continuation indentation;
  - execution count;
  - Markdown heading highlights;
  - output divider and virtual lines.
- Saved-output previews:
  - stdout/stderr;
  - ANSI-stripped tracebacks;
  - plain text, Markdown, HTML, and LaTeX;
  - terminal-image placeholders for PNG/JPEG/SVG/PDF;
  - explicit Plotly/Bokeh interactive placeholders;
  - unsupported-MIME diagnostics;
  - deterministic truncation.
- Cell navigation and text objects.
- Insert, duplicate, delete, move, split, merge, and type conversion.
- Source folds, output collapsing, and output clearing.
- Notebook outline through `vim.ui.select`.
- Undo-aware cell identity through IDs embedded in concealed markers.
- Buffer-local configurable mappings and commands.
- `:checkhealth nvjup` and `:help nvjup`.

## Intentionally deferred

These features belong to later planned stages:

- Jupyter kernel execution;
- LSP shadow documents;
- Kitty image placements;
- interactive Plotly/Bokeh remote framebuffer;
- ipympl and ipywidgets;
- pixel-level terminal screenshots.

Stage 1 renders persisted rich outputs semantically but does not claim that an image placeholder is the final Kitty renderer.

## Validation

The headless Neovim suite covers:

- isolated XDG configuration;
- all ten notebook fixtures;
- border/header/footer extmarks;
- active-cell and Markdown rendering;
- every planned MIME family and fallback;
- output truncation/collapse/clear;
- navigation;
- structural operations;
- source folding;
- undo of structural and type changes;
- semantic no-op round-trip for every fixture;
- unknown metadata/MIME preservation;
- marker collision escaping;
- malformed marker rejection without overwriting the file;
- creation of new notebooks.

Run locally with `./scripts/test` and in Docker with `docker compose run --rm test`.
