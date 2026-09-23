# LSP and notebook navigation contract

## LSP model

Code cells of the same language form one logical shadow text document. This preserves cross-cell definitions, references, imports, rename, and diagnostics. Per-cell LSP clients are not acceptable because they lose notebook-wide code context.

One notebook may have multiple shadow documents, one per language. The primary language comes from kernelspec/language metadata; explicit per-cell language metadata may select another document.

## Source maps

Every mapped segment records:

- notebook buffer and revision;
- stable cell ID;
- cell-local range;
- shadow URI and range;
- whether the segment is editable source or synthetic separator.

Mappings are versioned. Responses produced for an obsolete mapping are discarded or remapped only after an explicit equivalence check.

Position conversion must account for Neovim byte columns and the LSP client's negotiated UTF-8/UTF-16/UTF-32 encoding.

## Required LSP behavior

The first usable release supports:

- diagnostics;
- completion;
- hover;
- signature help;
- definition and declaration;
- references;
- document symbols;
- semantic tokens;
- rename;
- safe code actions and WorkspaceEdits.

Locations in another code cell move the cursor to that cell and create a jumplist entry. Locations in project files use normal Neovim navigation.

## Safe edits

An edit is applied only when all notebook-targeted ranges map to editable code segments in the current source-map revision. Edits that touch synthetic separators, Markdown, raw cells, or cell boundaries are rejected with a visible reason. External project-file edits are delegated to Neovim's normal WorkspaceEdit implementation.

## IPython transformations

Line and cell magics and shell escapes are replaced in the shadow document by syntax-safe placeholders. Transformations preserve line count and mapped columns for surrounding code. The original notebook source is never rewritten merely to satisfy an LSP.

## Navigation

Required cell motions:

- next/previous cell;
- next/previous code cell;
- next/previous output;
- next/previous failed or stale cell;
- count-aware movement;
- `inner cell` and `around cell` text objects.

Required structural navigation:

- notebook outline;
- Markdown heading hierarchy;
- filtering by cell type/status;
- jump to running/error/stale cells;
- `vim.ui.select` baseline and optional Telescope adapter.

All jumps update the jumplist, avoid concealed structural markers, and remain independent of rendered output height. Default mappings are buffer-local and configurable; the plugin must not claim the user's `<leader>r` namespace.
