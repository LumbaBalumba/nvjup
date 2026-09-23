# Stage 0 specification index

This directory is the normative Stage 0 contract for `nvjup`. If the research plan and these documents disagree, these documents govern implementation until an explicit architecture decision changes them.

- [`nbformat.md`](nbformat.md): supported notebook model and lossless round-trip rules.
- [`protocol.md`](protocol.md): versioned RPC contract between Neovim, the Jupyter sidecar, and the interactive renderer.
- [`state-machines.md`](state-machines.md): lifecycle and transition semantics.
- [`trust.md`](trust.md): notebook trust and renderer sandbox policy.
- [`lsp-navigation.md`](lsp-navigation.md): shadow documents, source maps, safe LSP edits, and cell navigation.
- [`acceptance.md`](acceptance.md): Stage 0 acceptance criteria and fixture coverage.

Machine-readable contracts live under `spec/` and are validated by `tests/python/`.

## Stability

Stage 0 defines protocol version `1`. Before the first implementation release, incompatible corrections may still be made, but every change must update:

1. the relevant human-readable specification;
2. the machine-readable schema or state machine;
3. fixtures and tests;
4. the protocol version when interoperability would otherwise be ambiguous.
