# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] — Unreleased

Initial public release.

### Added
- Parse Postman Collection **v2.1** exports (nested folders, all body modes,
  auth inheritance) and Postman environment exports.
- Send requests with `curl` as async jobs (`vim.system`, falling back to
  `jobstart`); status, timing, and size captured via `curl -w`.
- `{{variable}}` resolution across in-memory overrides, session values, a
  gitignored secrets file, shell env, the active environment, collection
  variables, and dynamic vars (`{{$guid}}`, `{{$timestamp}}`, …).
- **Quick pane** (`:Curlman`) and a two-panel **workspace** (`:CurlmanUI`):
  config cards (variables + requests, editable in memory) and per-request
  response history with inline previews (truncate / full / hide).
- Per-request history keyed by config + method + name, with caps (2/5/10/∞),
  clear-one / clear-all, and each entry stamped with resolved URI + config.
- Native diff of a request's responses; big, resizable response viewer.
- Copy request (as a reproducible `curl`), response, or a full transcript to a
  buffer.
- Optional `jq` for pretty-printing and `:CurlmanJq` filtering.
- Project-aware load menu (discovers Postman JSON, floats recently-loaded up).
- First-class Telescope integration: `telescope-ui-select` routing plus
  `:Telescope curlman requests` / `:Telescope curlman history` with previews.

[0.1.0]: https://github.com/robbiehirsch/curlman.nvim/releases/tag/v0.1.0
