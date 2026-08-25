# curlman.nvim

![CI](https://github.com/robbiehirsch/curlman.nvim/actions/workflows/ci.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)

A Postman-style API client that lives inside Neovim. It reads Postman
Collection **v2.1** exports, sends the requests with `curl`, and shows responses —
status, timing, size — either in a quick pane or a two-panel **workspace** where
each request keeps its own response history you can diff, filter, and save.

Built for locked-down machines: the only hard dependency is `curl`. JSON parsing,
the pickers, the panels, and diffing all use Neovim built-ins. `jq` is used only
if present (nicer pretty-print + `:CurlmanJq`). `node` is only needed for the
(planned) pre-request/test script runner.

## Requirements

- Neovim 0.8+ (0.10+ uses `vim.system`; older falls back to `jobstart`)
- `curl` on `$PATH`
- Optional: `postman` CLI or `newman` for collection runs with scripts & assertions (see below)
- Optional: `jq`; `telescope.nvim` + `telescope-ui-select` for fuzzy pickers and the `:Telescope curlman` extension

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "robbiehirsch/curlman.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional
  config = function()
    require("curlman").setup({
      -- collection  = "~/apis/work.postman_collection.json",
      -- environment = "~/apis/work.postman_environment.json",
    })
  end,
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "robbiehirsch/curlman.nvim",
  config = function() require("curlman").setup({}) end,
})
```

Then try `:CurlmanDemo` followed by `:CurlmanUI`. Using Telescope? Add
`require("telescope").load_extension("curlman")` after telescope is set up.

> Replace `robbiehirsch` with your GitHub username if you fork it.

## Two ways to use it

**Quick pane** — fire a request and eyeball the result:

- `:Curlman` — pick a request, send it, response opens in a split.
- `:CurlmanRun` — re-send the last one.

**Workspace** — the dashboard, for juggling multiple configs and comparing runs:

- `:CurlmanUI` — toggle the two-panel workspace.

```
 CONFIGS   (l:load e:edit R:reload D:remove o:reset) │ REQUESTS & HISTORY  (⏎:view x:clear X:all c:cap d:diff s:save)
 ▾ work  ⟨prod⟩                                       │ ▾ GET  Users / list      200 · 138ms  (work)  [3]
    * base_url = https://staging                      │      12:04:31  200  138ms  1.2KB  https://staging/users
      token    = ••••••                               │      12:01:10  200  145ms  1.2KB  https://staging/users
    ▸ GET  Users / list                               │      11:58:02  500   88ms   64B   https://staging/users
    ▸ POST Users / create                             │ ▾ POST Users / create    201 · 210ms (work)  [1]
 ▸ billing.json                                       │      12:03:55  201  210ms  340B   https://staging/users
```

Left = your loaded configs (variables + requests). Right = one card per request
you've run, each with its own history. Everything is keyboard-driven.

### Workspace keys

Left panel (configs):

- `⏎` on a config = fold/unfold · on a request = **send it** · on a variable = edit it
- `e` edit a variable in-memory · `o` reset a config's overrides
- `y` copy the request (resolved) as a **curl command** into a new buffer
- `R` reload config from disk · `D` remove config · `l` open the load menu · `Tab` fold

Right panel (requests & history):

- `⏎` on a request = fold/unfold · on the preview or a history line = **open the response in a pane**
- `t` cycle the latest-response preview: **truncated → full → hidden**
- `y` copy **request / response / both** into a new editable buffer
- `x` clear this request's history · `X` clear all
- `c` cap this request (2/5/10/unlimited) · `C` set the default cap
- `d` diff this request's responses · `s` save this request's history · `i` timing/headers

Each expanded request shows its **latest response body inline** (truncated to
`ui.preview_lines`, default 12), the resolved URI, and older responses as compact
lines. In the diff view, `q`/`gt` returns you to the workspace.

`q`/`<Esc>` close · `?` help · `<C-w> h/l` move between panels.

### Copy to a buffer

Press `y` (or run `:CurlmanCopy`) to drop content into a new editable buffer you
can yank, `:w`, or edit:

- **request** → a clean, reproducible `curl` command (body inlined, shell-escaped)
- **response** → the body, with its content-type filetype (JSON highlighted, jq-able)
- **both** → a full transcript: the curl command, response headers, and body

In the response viewer float, `y` copies the body straight to a buffer. `y` on a
request in the configs panel copies its curl command (resolved) without running it.

## Loading collections

`:CurlmanLoad` with no argument opens a **project-aware menu**: it scans your
project (git root, else cwd) for Postman JSON files, classifies them as
collection vs environment, and floats **previously-loaded** files to the top.
Pick one and it loads. You can load several — they stack as cards in the left
panel. `:CurlmanLoad <path>` loads a specific file directly (tab-completes).

Export from Postman: right-click the collection → **Export → Collection v2.1**
(and the environment via its ⋯ menu). Point `collection` at it in setup, or just
`:CurlmanDemo` to try the bundled sample.

## In-memory variable tweaks ("what-if")

In the config panel, put the cursor on a variable and press `e` (or `⏎`) to
change its value **for this session only** — the file on disk is untouched. The
variable shows a `*` and the new value; every subsequent request from that config
uses it. `o` resets a config's overrides. Great for "what does staging return vs
prod?" without editing files. Overrides win over the environment and collection
values.

## Profiles & multi-config runs

A **profile** is a named variable set — `dev` / `staging` / `prod` — stored
globally (one Postman-environment JSON per profile in
`stdpath("data")/curlman/profiles/`), so it follows you across projects and
imports/exports cleanly to Postman.

- `:CurlmanProfileSave beta` snapshots the variables a collection currently
  resolves against — including unsaved in-memory `e` tweaks — into a profile.
- `:CurlmanProfiles` is the manager: edit the file, rename, duplicate,
  delete, save a copy to any location, toggle ★ favourite.
- `:CurlmanRunWith` picks a request, lets you multi-select profiles
  (☐/☑ toggles, ▶ fires), runs the request once per profile, records each
  response in history tagged `[profile]`, then compares: exactly two
  profiles auto-open a side-by-side diff tab; three or more get a pair
  picker. During profile runs your in-memory overrides are deliberately
  ignored so every profile resolves from a clean slate (secrets and shell
  env still apply).
- `:CurlmanFav` stars an endpoint; ★ endpoints and ★ profiles float to the
  top of every picker.

## Per-request history

Every response is filed under the request it came from (keyed by config + method
+ name), so a wall of GET/POST calls stays legible — each entry is stamped with
the **resolved URI** and **source config**. Per-request cap defaults to 10 and is
adjustable at runtime (`c` → 2/5/10/unlimited). History is in-memory and clears
when you quit; save it explicitly with `s`.

Saving suggests a sibling folder next to the collection file:

```
~/apis/work.postman_collection.json
~/apis/work.postman_collection-curlman-history/
    Users-list-20260723-143002-response.json
```

## Collection runs via the Postman CLI

curl sends one request and knows nothing about Postman's JS sandbox. When you
need the sandbox — pre-request/test scripts, `pm.test` assertions, or values
chained between requests with `pm.environment.set` — curlman can hand the whole
collection to the real Postman collection runner instead:

```vim
:CurlmanRunCollection            " run a loaded collection end to end
:CurlmanRunCollection Auth       " scope the run to one folder
:CurlmanRunner                   " report which runner was found
```

It drives either CLI, preferring the official one:

| Runner | Install | Notes |
| --- | --- | --- |
| Postman CLI | `brew install postman/tap/postman-cli` | Official, standalone (no node), can report runs to your Postman workspace |
| newman | `npm install -g newman` | Open source, fully offline, needs node |

Neither is a dependency. With neither installed curlman is exactly what it was
before — a curl client — and `:CurlmanRunCollection` says so.

**Every execution becomes an ordinary history entry.** Each request in the run
gets its own bucket, so saving, organizing, capping and diffing all behave
exactly as they do for curl responses. Because the buckets are keyed on
collection + method + name, a CLI response and a curl response for the *same*
request land in the same bucket — so `d` in the workspace will diff **what
Postman got against what curl got**, which is a fast way to find out that a
test script was mutating a variable behind your back.

The runner is handed a Postman environment file built from curlman's own
resolved variables, so overrides, the secrets file, shell env and the active
environment all apply, with the same precedence as a curl send.

This is deliberately collection-level only; single-request sends stay on curl,
which is faster and has no startup cost.

## Telescope

curlman works with or without Telescope. All its transient pickers use the
standard `vim.ui.select` / `vim.ui.input`, so installing **telescope-ui-select**
makes every prompt (request picker, load menu, environment, cap, copy, diff)
render as a fuzzy Telescope picker automatically — no curlman changes.

It also ships a first-class extension. After
`require("telescope").load_extension("curlman")`:

- `:Telescope curlman requests` — fuzzy-find a request across all loaded
  collections; the preview pane shows its **resolved curl command**. `⏎` runs it,
  `<C-y>` copies the curl to a buffer.
- `:Telescope curlman history` — browse the whole response history; the preview
  pane shows the **response body**. `⏎` opens it in the big viewer, `<C-y>` copies
  the transcript.

The two workspace panels are intentionally *not* Telescope — Telescope covers the
"find one of many" moments; the workspace is the persistent dashboard.

## Configuration

```lua
require("curlman").setup({
  collection      = nil,   -- path OR list of paths to *.postman_collection.json
  collection_dirs = {},    -- directories to auto-scan
  environment     = nil,   -- default environment file

  secrets_file = vim.fn.stdpath("data") .. "/curlman.local.json", -- gitignored, out of repo
  shell_env = true,        -- also resolve {{FOO}} from $FOO
  shell_env_prefix = "",   -- e.g. "CURLMAN_" -> {{token}} reads $CURLMAN_token
  prompt_missing = true,   -- prompt for any {{var}} still unresolved at send time

  curl = {
    connect_timeout = 10, max_time = 30,
    follow_redirects = true,
    insecure = false,      -- true for self-signed / corporate certs
    http_version = nil,    -- "1.0" | "1.1" | "2"
    extra_args = {},       -- appended to every curl call
  },

  ui = {
    split = "vertical", size = 0.5,   -- quick pane
    left_width = 0.34,                -- workspace configs panel width
    pretty_json = true, jq_pretty = true,
  },

  history = {
    enabled = true,
    max_recent = 10,       -- default responses kept PER REQUEST
    autosave = false,      -- write every response to its sibling folder
  },

  keymaps = false,         -- true to auto-install <leader>C* maps
})
```

## Variables & secrets

`{{variable}}` placeholders resolve in this order (first hit wins): in-memory
**overrides** → session values → **secrets file** → **shell env** → selected
**environment** → **collection** variables → **dynamic** (`{{$guid}}`,
`{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`). Anything still
unresolved at send time is prompted for (secret-ish names are masked).

`secrets_file` defaults to `~/.local/share/nvim/curlman.local.json` — **outside**
your dotfiles repo, so tokens never commit:

```json
{ "token": "eyJhbGc...", "base_url": "https://api.internal.example.com" }
```

## Commands

`:Curlman` `:CurlmanUI` `:CurlmanRun` `:CurlmanLoad` `:CurlmanLoadEnv`
`:CurlmanEnv` `:CurlmanInfo` `:CurlmanDiff` `:CurlmanHistory` `:CurlmanClear`
`:CurlmanSave` `:CurlmanCopy [request|response|both]` `:CurlmanJq <filter>`
`:CurlmanReload` `:CurlmanDemo`

:CurlmanProfiles     Manage profiles (edit/rename/dup/delete/copy/favourite)
:CurlmanProfileSave  Snapshot current variables into a named profile
:CurlmanRunWith      Run one request across several profiles and compare
:CurlmanFav          Toggle favourite on an endpoint
:CurlmanRunCollection [folder]  Run a whole collection via the Postman CLI/newman
:CurlmanRunner       Report which collection runner is available

## Corporate certs / proxies

- Self-signed cert → `curl = { insecure = true }`.
- Proxy curl won't auto-detect → `curl = { extra_args = { "--proxy", "http://proxy:8080" } }` (or `$HTTPS_PROXY`).

## Roadmap

- **Pre-request / test scripts for single-request sends.** Collection runs
  already execute them via the Postman CLI / newman (see above); doing it for a
  one-off `:Curlman` send needs an in-process `pm.*` subset on optional `node`.

## Files

```
lua/curlman/
  init.lua        setup(), commands, orchestration
  config.lua      defaults + merge
  runner.lua      Postman CLI / newman collection runs
  postman.lua     collection / environment parsing
  vars.lua        {{variable}} resolution (+ overrides, dynamic vars)
  curl.lua        build curl argv, run it, parse response; jq wrappers
  discover.lua    project-aware collection discovery + recent-loads
  workspace.lua   the two-panel card dashboard (pure render + nvim wiring)
  ui.lua          quick pane, response body float, info, diff, jq, save
  history.lua     per-request keyed history + caps + save
  util.lua        helpers incl. order-preserving JSON pretty-printer
  sample/         demo collection + environment (:CurlmanDemo)
```
