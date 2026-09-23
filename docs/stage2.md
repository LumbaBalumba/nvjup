# Stage 2: language tooling foundation

## Tree-sitter

Tree-sitter support is implemented at Stage 2 rather than postponed.

A normal Neovim buffer can have only one active Tree-sitter highlighter, while an `nvjup` composite buffer may contain Markdown, Python, Lua, R, Julia, or other languages. `nvjup` therefore:

1. determines the language of every cell;
2. parses every non-raw cell with the corresponding Tree-sitter parser;
3. traverses root and injected language trees;
4. projects highlight captures back to the visible cell range with extmarks;
5. caches a layout/source fingerprint so cursor-only renders do not reparse cells.

This supports Markdown inline injections and mixed-language notebooks without changing notebook source or wrapping code in synthetic fences. If a parser is missing, only that language loses Tree-sitter highlighting.

## Shadow documents

Every code language gets one hidden shadow buffer. Synthetic comment separators preserve stable cell IDs, while editable segments retain cell source and line structure. Markdown and raw cells are excluded.

Each source-map segment records:

- cell ID and cell index;
- visible notebook source range;
- shadow source range;
- transformed IPython magic lines;
- source-map version.

Notebook byte columns are converted to and from each client's negotiated UTF-8, UTF-16, or UTF-32 position encoding. Source lines resembling internal markers account for the visible escape column.

## IPython syntax

For Python shadows, `%` line magics, `!` shell escapes, help syntax, and `%%` cell magics are replaced with same-byte-width comments. The notebook source is never changed. Edits targeting transformed lines are rejected.

## LSP proxy

LSP clients attach only to shadow buffers. Buffer-local notebook mappings proxy:

- completion;
- hover and signature help;
- definition, declaration, implementation, and type definition;
- references and document symbols;
- diagnostics;
- semantic tokens;
- rename;
- code actions and WorkspaceEdits.

Locations in a shadow document are translated back to notebook cells. External file locations and edits use normal Neovim buffers.

Responses carry the source-map version captured when the request was sent. A response is discarded if notebook structure or source changed before it arrived.

## Safe edits

A shadow-targeted edit is accepted only when both range endpoints:

- map to editable code;
- belong to the same cell;
- do not touch a synthetic separator;
- do not touch an IPython placeholder;
- use the current source-map version.

The complete WorkspaceEdit is validated before notebook edits are applied. External project-file edits remain delegated to Neovim.

## Python defaults

When available, Python shadows start:

- `pyright-langserver --stdio`;
- `ruff server`.

Pyright 1.1.408 can leave workspace folders uninitialized unless a client sends `workspace/didChangeConfiguration`. The default Pyright settings are intentionally non-empty so Neovim sends that notification. Pull-diagnostic dynamic registration is disabled by default because its registration handshake can deadlock that Pyright release; standard published diagnostics are projected instead.

## Tests

The hermetic suite validates source maps, Unicode position encodings, multi-language documents, magic preprocessing, projected Tree-sitter captures, parser fallback, diagnostics, safe and stale edits, and normal-code-equivalent mappings.

A deterministic Python LSP server validates Neovim's real LSP transport, asynchronous diagnostics, cross-cell definition, hover, signature help, semantic tokens, rename, and code actions.

`./scripts/test-real-lsp` additionally validates the installed Pyright and Ruff executables and a real cross-cell Pyright definition jump.
