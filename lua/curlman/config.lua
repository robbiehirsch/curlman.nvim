-- curlman.config — default options + merge. Defaults are produced lazily so
-- vim.fn.stdpath is only called inside Neovim (keeps modules import-safe in tests).

local M = {}

function M.defaults()
  local data = (vim.fn and vim.fn.stdpath and vim.fn.stdpath("data")) or (os.getenv("HOME") .. "/.local/share/nvim")
  local cache = (vim.fn and vim.fn.stdpath and vim.fn.stdpath("cache")) or (os.getenv("HOME") .. "/.cache/nvim")
  local state = (vim.fn and vim.fn.stdpath and vim.fn.stdpath("state")) or (os.getenv("HOME") .. "/.local/state/nvim")
  return {
    -- WHERE TO FIND REQUESTS -------------------------------------------------
    collection = nil,        -- path (string) or list of paths to *.postman_collection.json
    collection_dirs = {},    -- directories to scan for collections
    environment = nil,       -- default environment: a file path
    environment_dirs = {},   -- directories to scan for *.postman_environment.json

    -- SECRETS / VARIABLES ----------------------------------------------------
    -- A gitignored JSON map of { "token": "...", "base_url": "..." } used to fill
    -- {{variables}}. Defaults OUTSIDE your dotfiles repo so secrets never commit.
    secrets_file = data .. "/curlman.local.json",
    shell_env = true,        -- also resolve {{FOO}} from $FOO
    shell_env_prefix = "",   -- e.g. "CURLMAN_" -> {{token}} can read $CURLMAN_token
    prompt_missing = true,   -- prompt for any {{var}} still unresolved at send time

    -- CURL BEHAVIOR ----------------------------------------------------------
    curl = {
      connect_timeout = 10,
      max_time = 30,
      follow_redirects = true,
      insecure = false,      -- set true for self-signed / corporate certs
      http_version = nil,    -- "1.0" | "1.1" | "2"
      extra_args = {},       -- appended to every curl invocation
    },

    -- UI ---------------------------------------------------------------------
    ui = {
      split = "vertical",    -- "vertical" | "horizontal" quick response pane
      size = 0.5,            -- fraction of the editor (quick pane)
      left_width = 0.34,     -- workspace: fraction for the configs panel
      preview_lines = 12,    -- workspace: lines of the latest response to show inline
      body_width = 0.85,     -- response viewer float: fraction of the editor
      body_height = 0.85,
      pretty_json = true,
      jq_pretty = true,      -- use jq for pretty-printing when installed
      focus_response = false,-- keep cursor in the current window after sending
    },

    -- HISTORY ----------------------------------------------------------------
    history = {
      enabled = true,
      dir = cache .. "/curlman/history",
      max_recent = 10,       -- default responses kept PER REQUEST (cap 2/5/10 at runtime)
      autosave = false,      -- write every response to disk automatically
      state_file = state .. "/curlman/recent.json", -- remembers recently-loaded files
    },

    -- Install default <leader>a* keymaps. Off by default; Robbie's keymaps.lua
    -- wires these explicitly instead.
    keymaps = false,
  }
end

-- shallow-ish deep merge: user values win; nested tables merged recursively.
local function is_list(t)
  local fn = vim.islist or vim.tbl_islist
  return fn and fn(t)
end

local function deep_merge(base, override)
  if type(override) ~= "table" then return base end
  for k, v in pairs(override) do
    if type(v) == "table" and type(base[k]) == "table" and not is_list(v) then
      deep_merge(base[k], v)
    else
      base[k] = v
    end
  end
  return base
end

function M.build(user)
  local cfg = M.defaults()
  if user then deep_merge(cfg, user) end
  return cfg
end

return M
