# Stage 4: rich static outputs

Stage 4 adds safe static MIME rendering without changing nbformat persistence or executing notebook-provided browser content.

## Supported output families

- `text/plain`, streams, and tracebacks with ANSI removal;
- `text/markdown` as terminal text with notebook highlight groups;
- sanitized `text/html`;
- bounded terminal tables for HTML `<table>` output;
- PNG through Kitty's Unicode-placeholder graphics protocol;
- JPEG and the first PDF page through ImageMagick-to-PNG conversion;
- sanitized SVG through `rsvg-convert`, with ImageMagick fallback;
- chafa symbol rendering when a compatible Kitty terminal is unavailable;
- bounded textual image diagnostics when neither graphics backend is available;
- explicit non-executing Plotly/Bokeh placeholders for later stages.

A MIME bundle chooses one preferred static image in this order: PNG, JPEG, SVG, PDF. Outputs retain their notebook order. Unknown MIME values remain untouched in the document and receive a visible unsupported-MIME diagnostic.

## Kitty rendering

`lua/nvjup/image.lua` sends PNG base64 in 3072-byte Kitty graphics chunks. The payload is deliberately smaller than Kitty's parser limit so the APC metadata and terminator also fit; oversized 4096-byte payloads can leak their base64 tail as visible terminal text:

```text
a=t,f=100,i=<id>,q=2,m=<more>
a=p,U=1,i=<id>,p=1,c=<cols>,r=<rows>,q=2
```

The second command creates an explicit virtual placement. Extmark virtual lines contain U+10EEEE placeholders with Kitty row/column diacritics, and a per-image foreground highlight encodes the 24-bit image ID. This makes placement viewport-aware: terminal images follow Neovim redraw, scrolling, resize, folds, and window visibility because the placement is anchored to rendered placeholder cells rather than absolute screen coordinates.

No Kitty remote-control socket or `allow_remote_control` setting is used. tmux escape passthrough is wrapped when `$TMUX` is present.

A placement is keyed by buffer, stable cell ID, and output index. Re-rendering identical content reuses it. Changed, collapsed, or cleared output deletes the old terminal image. Buffer teardown deletes every image owned by that notebook.

## Fallback selection

`render.images.backend` accepts:

- `auto`: attached Kitty/Ghostty UI, then chafa, then text;
- `kitty`: Kitty when available, otherwise text;
- `chafa`: chafa when installed, otherwise text;
- `text`: no terminal graphics.

Headless Neovim never writes graphics escapes merely because it inherited `KITTY_WINDOW_ID`; an attached UI is required. Tests inject a bounded writer explicitly.

## Conversion and security

PNG is validated and transmitted directly. Other static formats are written to private temporary files and converted asynchronously. Safe SVG prefers `rsvg-convert` with explicit maximum dimensions; JPEG/PDF and the SVG fallback use ImageMagick. Conversion has configurable time, input-byte, source-pixel, ImageMagick memory, map, disk, and output-dimension limits. Temporary files are removed after success, failure, timeout, or supersession.

Stream text applies terminal carriage-return overwrite semantics. This lets tqdm and similar progress bars update one virtual line while execution is running instead of displaying every historical frame.

SVG is rejected before conversion if it contains declarations/entities, scripts, event handlers, `foreignObject`, iframe/object/embed, `href`/`src`, JavaScript/file URLs, CSS `url()`, or imports. This deliberately rejects some legitimate linked SVGs rather than allowing ImageMagick to resolve external resources.

HTML is never loaded into a browser or evaluated. `render.max_html_bytes` is checked before sanitization, and oversized payloads retain their lossless notebook data while displaying a bounded placeholder plus `text/plain` fallback. Smaller HTML is sanitized once: scripts, styles, iframe, and object blocks are removed; remaining tags become escaped terminal text. Tables are parsed into bounded Unicode grids. `render.max_text_bytes` similarly bounds stream and textual MIME processing before line splitting. Interactive trust and sandboxed HTML/JavaScript remain Stage 6 work.

## Full-output pager

Inline text is capped by `render.max_output_lines`. `<leader>no` toggles full inline rendering for the current cell. `<leader>np` or:

```vim
:NvJupOutputOpen
:NvJupOutputOpen split
:NvJupOutputOpen vsplit
:NvJupOutputOpen tab
```

opens the current cell's textual output without the inline line limit in an ephemeral read-only buffer. HTML/text byte limits still produce metadata placeholders instead of synchronously processing unbounded payloads. `q` or `<Esc>` closes it.

## Configuration

```lua
require("nvjup").setup({
  render = {
    outputs = true,
    debounce_ms = 30,
    max_output_lines = 12,
    max_html_bytes = 512 * 1024,
    max_text_bytes = 1024 * 1024,
    images = {
      enabled = true,
      backend = "auto",
      max_width = 64,
      max_height = 24,
      max_bytes = 10 * 1024 * 1024,
      max_pixels = 16 * 1024 * 1024,
      conversion_timeout_ms = 10000,
    },
  },
})
```

`:checkhealth nvjup` reports the selected image backend and availability of Kitty-compatible graphics, chafa, and ImageMagick.

## Validation

`tests/nvim/stage4_spec.lua` covers:

- HTML table rendering, active-content stripping, and pre-sanitization byte bounds;
- revision-keyed output cache and collapsed-output short circuit;
- lightweight cursor updates and coalesced full rendering;
- static-image MIME priority;
- SVG rejection policy;
- chunked Kitty transmission and explicit virtual placement;
- Unicode placeholder generation and cleanup;
- asynchronous SVG rasterization;
- text fallback;
- full-output pager behavior;
- rendering order and notebook command/keymap integration.

The Docker image includes ImageMagick, `rsvg-convert`, and chafa. Headless CI verifies protocol bytes and placeholder structure, not terminal pixels. Run `./scripts/test-kitty-images` for host visual validation in an isolated Kitty/Ghostty UI.
