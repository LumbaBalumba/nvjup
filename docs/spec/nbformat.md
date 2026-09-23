# nbformat support and lossless round-trip contract

## Scope

The first implementation targets Jupyter `nbformat` major version 4 and accepts every minor version understood by the installed `nbformat` library. It must not silently upgrade or downgrade a notebook merely because the file was opened.

Machine-readable support levels are recorded in [`../../spec/nbformat-support.json`](../../spec/nbformat-support.json).

## Notebook fields

The implementation treats the following as first-class fields:

- `nbformat` and `nbformat_minor`;
- notebook `metadata`;
- ordered `cells`;
- code-cell `execution_count` and `outputs`;
- Markdown-cell `attachments`;
- cell `id` where present;
- all cell metadata.

Cell types:

- `code`: editable, executable, LSP-enabled;
- `markdown`: editable and renderable;
- `raw`: editable and preserved, never executed.

Unknown notebook, cell, metadata, attachment, output, and MIME keys are opaque data. They must survive load/save even when no renderer understands them.

## Output types

The model recognizes:

- `stream`;
- `execute_result`;
- `display_data`;
- `error`.

Recognized MIME representations include:

- `text/plain`;
- `text/markdown`;
- `text/html`;
- `text/latex`;
- `image/png`;
- `image/jpeg`;
- `image/svg+xml`;
- `application/pdf`;
- `application/json`;
- `application/vnd.plotly.v1+json`;
- Bokeh vendor MIME types.

Recognition affects display selection only. Saving must preserve the complete MIME bundle, not only the selected representation.

## Live messages versus persisted outputs

Jupyter messages such as `update_display_data`, `clear_output`, `status`, and `input_request` are runtime events and are not all legal persisted nbformat outputs. Runtime transcripts therefore live in `tests/fixtures/messages/`, while notebook files contain the valid final persisted state.

A `display_id` is maintained in runtime state and removed from persisted output unless the nbformat specification explicitly permits it.

## Cell IDs

- Existing IDs are preserved exactly.
- Missing IDs are not added during a no-op save.
- A newly created cell receives a unique, stable ID compatible with the active nbformat minor version.
- Move, type conversion, execution, and output changes do not replace a cell ID.
- Split creates one new ID; merge preserves the destination ID and removes the consumed ID.

## Source representation

The in-memory model normalizes `source` to logical text while retaining enough information to avoid semantic changes. Both string and list-of-lines JSON encodings are accepted. A no-op save may normalize JSON formatting, but must not change the logical source.

## Lossless round-trip definition

A load/save cycle without user or runtime changes is successful when:

1. both documents validate as nbformat;
2. notebook and cell order is unchanged;
3. every known and unknown field has an equivalent JSON value;
4. source text is logically identical;
5. every MIME representation and attachment is identical after base64 normalization;
6. execution counts and outputs are unchanged;
7. IDs are unchanged;
8. no metadata is synthesized, removed, or rewritten;
9. only insignificant JSON formatting may differ.

The Stage 0 tests enforce a stronger form for fixtures: `nbformat.reads(nbformat.writes(node))` must compare equal to the original parsed node.

## Save safety

Saving will eventually use:

1. model snapshot;
2. nbformat validation;
3. serialization to a sibling temporary file;
4. flush and optional fsync;
5. atomic rename;
6. external-modification check based on the loaded file identity/hash.

A validation failure must leave the original file untouched.
