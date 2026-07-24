-- curlman — a Postman-style API client for Neovim/LunarVim. Reads Postman
-- Collection v2.1 exports, runs the requests with curl, and shows responses (with
-- timing) either in a quick pane or a two-panel workspace you can diff, filter,
-- and keep per-request history in. curl is the only hard dependency.
--
--   require("curlman").setup({ collection = "~/apis/work.postman_collection.json" })
--   :Curlman     quick pick + send        :CurlmanUI    open the workspace
--   :CurlmanLoad browse project JSONs      :CurlmanDemo  try the bundled sample
--
-- See README.md for the full option list and keymaps.

local config = require("curlman.config")
local postman = require("curlman.postman")
local vars = require("curlman.vars")
local curl = require("curlman.curl")
local ui = require("curlman.ui")
local history = require("curlman.history")
local discover = require("curlman.discover")
local workspace = require("curlman.workspace")
local util = require("curlman.util")

local M = {}

M.cfg = nil
M.state = {
  collections = {},      -- name -> collection (with .overrides = {})
  config_order = {},     -- names in load order
  requests = {},         -- flat list across collections (quick picker)
  environments = {},     -- name -> env
  current_env = nil,
  secrets = {},
  session_vars = {},
  config_expanded = {},  -- name -> bool
  request_expanded = {}, -- history key -> bool
  preview_mode = {},     -- history key -> "truncated"|"full"|"hidden"
  last_request = nil,
  last_result = nil,
  last_entry = nil,
}

----------------------------------------------------------------- loading state

function M.rebuild_requests()
  local reqs = {}
  for _, name in ipairs(M.state.config_order) do
    local col = M.state.collections[name]
    if col then for _, r in ipairs(col.requests) do reqs[#reqs + 1] = r end end
  end
  M.state.requests = reqs
end

function M.load_collection(path)
  path = util.expand(path)
  local content, rerr = util.read_file(path)
  if not content then util.err("could not read " .. path .. ": " .. tostring(rerr)); return false end
  local col, perr = postman.parse_collection(content, path)
  if not col then util.err(path .. ": " .. tostring(perr)); return false end
  -- preserve overrides if reloading a config of the same name
  local prev = M.state.collections[col.name]
  col.overrides = (prev and prev.overrides) or {}
  -- every {{variable}} the requests reference (so the panel can list them all)
  col.referenced = {}
  for _, r in ipairs(col.requests) do vars.referenced_request(r, col.referenced) end
  if not M.state.collections[col.name] then
    M.state.config_order[#M.state.config_order + 1] = col.name
  end
  M.state.collections[col.name] = col
  M.rebuild_requests()
  discover.mark_loaded(path)
  util.info(string.format("loaded '%s' (%d requests)", col.name, #col.requests))
  if workspace.is_open() then workspace.redraw() end
  return true
end

function M.unload_collection(name)
  if not M.state.collections[name] then return end
  M.state.collections[name] = nil
  for i, n in ipairs(M.state.config_order) do
    if n == name then table.remove(M.state.config_order, i); break end
  end
  M.rebuild_requests()
  util.info("removed '" .. name .. "'")
end

function M.load_environment(path)
  path = util.expand(path)
  local content, rerr = util.read_file(path)
  if not content then util.err("could not read " .. path .. ": " .. tostring(rerr)); return false end
  local env, perr = postman.parse_environment(content)
  if not env then util.err(path .. ": " .. tostring(perr)); return false end
  M.state.environments[env.name] = env
  if not M.state.current_env then M.state.current_env = env.name end
  util.info("loaded environment '" .. env.name .. "'")
  if workspace.is_open() then workspace.redraw() end
  return true
end

function M.load_secrets()
  M.state.secrets = {}
  local content = util.read_file(util.expand(M.cfg.secrets_file))
  if not content then return end
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then M.state.secrets = data
  else util.warn("secrets file is not valid JSON: " .. M.cfg.secrets_file) end
end

--------------------------------------------------------------------- resolving

local function context_for(req)
  local col = req.collection and M.state.collections[req.collection]
  local env = M.state.current_env and M.state.environments[M.state.current_env]
  return {
    overrides = col and col.overrides or {},
    session = M.state.session_vars,
    secrets = M.state.secrets,
    env = env and env.map or {},
    collection = col and col.vars_map or {},
    allow_shell = M.cfg.shell_env,
    shell_prefix = M.cfg.shell_env_prefix,
  }
end

function M.send(req)
  local resolved, unresolved = vars.resolve_request(req, context_for(req))
  if #unresolved > 0 and M.cfg.prompt_missing then
    M.prompt_and_send(req, unresolved); return
  end
  if #unresolved > 0 then
    util.warn("unresolved: {{" .. table.concat(unresolved, "}}, {{") .. "}}")
  end
  M.state.last_request = req
  M.dispatch(resolved)
end

function M.prompt_and_send(req, missing)
  local i = 0
  local function next_var()
    i = i + 1
    if i > #missing then
      local resolved, still = vars.resolve_request(req, context_for(req))
      if #still > 0 then util.warn("still unresolved: {{" .. table.concat(still, "}}, {{") .. "}}") end
      M.state.last_request = req
      M.dispatch(resolved)
      return
    end
    vim.ui.input({ prompt = "value for {{" .. missing[i] .. "}}: " }, function(val)
      if val == nil then util.warn("cancelled"); return end
      M.state.session_vars[missing[i]] = val
      next_var()
    end)
  end
  next_var()
end

function M.dispatch(resolved)
  local in_ws = workspace.is_open()
  if not in_ws then ui.show_running(resolved, M.cfg) end
  util.info("→ " .. resolved.method .. " " .. resolved.url)
  curl.execute(resolved, M.cfg.curl, function(result)
    M.state.last_result = result
    local lines = ui.format_lines(result, M.cfg)
    local _, entry = history.record(resolved, result, lines)
    M.state.last_entry = entry
    if workspace.is_open() then workspace.redraw()
    else ui.show_response(result, lines, M.cfg) end
    if M.cfg.history.enabled and M.cfg.history.autosave and result.ok then
      local col = M.state.collections[resolved.collection]
      history.save_entry(entry, history.suggest_save_path(col and col.source, entry.name, entry.timestamp, entry.filetype))
    end
    if not result.ok then
      util.err(resolved.method .. " failed: " .. (result.stderr ~= "" and result.stderr or ("exit " .. tostring(result.exit_code))))
    end
  end)
end

--- Run a request identified by (config, method, display) — used by the panel.
function M.run_named(config_name, method, display)
  local col = M.state.collections[config_name]
  if not col then util.err("config not loaded: " .. tostring(config_name)); return end
  for _, r in ipairs(col.requests) do
    if r.collection == config_name and r.method == method and (r.display or r.name) == display then
      M.send(r); return
    end
  end
  util.err("request not found: " .. tostring(display))
end

------------------------------------------------------------------- var editing

function M.edit_var(config_name, key)
  local col = M.state.collections[config_name]
  if not col then return end
  -- prefill with the effective value: override > env > collection
  local env = M.state.current_env and M.state.environments[M.state.current_env]
  local current = (col.overrides and col.overrides[key])
    or (env and env.map[key])
    or col.vars_map[key] or ""
  vim.ui.input({ prompt = "set {{" .. key .. "}} for " .. config_name .. " = ", default = current }, function(val)
    if val == nil then return end
    col.overrides = col.overrides or {}
    col.overrides[key] = val
    local lk = key:lower()
    local secret = lk:match("token") or lk:match("secret") or lk:match("password") or lk:match("key")
    util.info("{{" .. key .. "}} = " .. (secret and "••••" or val) .. "  (session override)")
    if workspace.is_open() then workspace.redraw() end
  end)
end

function M.reset_overrides(config_name)
  local col = M.state.collections[config_name]
  if col then col.overrides = {}; util.info("reset overrides for '" .. config_name .. "'") end
end

--------------------------------------------------------------- history actions

function M.set_cap(key)
  vim.ui.select({ "2", "5", "10", "unlimited" }, { prompt = "keep how many responses per request?" }, function(choice)
    if not choice then return end
    local n = (choice == "unlimited") and 0 or tonumber(choice)
    history.set_cap(key, n)
    util.info(key and ("cap for this request: " .. choice) or ("default cap: " .. choice))
    if workspace.is_open() then workspace.redraw() end
  end)
end

function M.diff_request(key)
  local rec = history.get(key)
  if rec then ui.diff_entries(rec.entries) end
end

function M.save_request(key)
  local rec = history.get(key)
  if not rec or #rec.entries == 0 then util.warn("no responses to save"); return end
  local col = M.state.collections[rec.request.collection]
  local folder = history.history_dir_for(col and col.source or (vim.fn.getcwd() .. "/x.json"))
  vim.ui.input({ prompt = "save " .. #rec.entries .. " responses to folder: ", default = folder, completion = "dir" }, function(dir)
    if not dir or dir == "" then return end
    local ext = ({ json = "json", xml = "xml", html = "html", text = "txt" })[rec.entries[1].filetype or "text"] or "txt"
    local saved = 0
    for i, e in ipairs(rec.entries) do
      local stamp = os.date("%Y%m%d-%H%M%S", e.timestamp)
      local path = util.expand(dir) .. "/" .. util.slug(e.name) .. "-" .. stamp .. "-" .. i .. "-response." .. ext
      if history.save_entry(e, path) then saved = saved + 1 end
    end
    util.info("saved " .. saved .. " responses → " .. dir)
  end)
end

------------------------------------------------------------------- copy to buffer

--- Copy a stored response's request / response / both into a new buffer.
function M.copy_entry_prompt(key, idx)
  local rec = history.get(key)
  local e = rec and rec.entries[idx or 1]
  if not e then util.warn("no response to copy"); return end
  vim.ui.select({ "request", "response", "both" }, { prompt = "copy to buffer:" }, function(kind)
    if kind then ui.to_buffer(kind, e, M.cfg) end
  end)
end

--- Lines for a telescope preview of a request: resolved curl command + info.
function M.preview_request_lines(r)
  local resolved = vars.resolve_request(r, context_for(r))
  local lines = {
    "# " .. (resolved.method or "?") .. "  " .. (resolved.display or resolved.name or ""),
    "# " .. (resolved.url or ""),
    "",
  }
  for _, l in ipairs(util.lines(curl.to_command_string(resolved))) do lines[#lines + 1] = l end
  return lines
end

--- Copy a (not-yet-run) request from a config as a resolved curl command.
function M.copy_request_named(config_name, method, display)
  local col = M.state.collections[config_name]
  if not col then return end
  for _, r in ipairs(col.requests) do
    if r.method == method and (r.display or r.name) == display then
      local resolved = vars.resolve_request(r, context_for(r))
      ui.to_buffer("request", {
        request = resolved, name = resolved.display or resolved.name,
        config = config_name, uri = resolved.url,
      }, M.cfg)
      return
    end
  end
end

------------------------------------------------------------------- environment

function M.pick_env()
  local names = vim.tbl_keys(M.state.environments)
  if #names == 0 then util.warn("no environments loaded — :CurlmanLoadEnv <path>"); return end
  table.insert(names, 1, "(none)")
  vim.ui.select(names, { prompt = "curlman environment" }, function(choice)
    if not choice then return end
    M.state.current_env = choice ~= "(none)" and choice or nil
    util.info("environment: " .. (M.state.current_env or "none"))
    if workspace.is_open() then workspace.redraw() end
  end)
end

---------------------------------------------------------------- load menu (UI)

local function relpath(path, root)
  if root and path:sub(1, #root) == root then return path:sub(#root + 2) end
  return path
end

function M.load_menu()
  local root = discover.project_root()
  local cands = discover.find(root)
  local loaded = {}
  for _, name in ipairs(M.state.config_order) do
    local c = M.state.collections[name]
    if c and c.source then loaded[c.source] = true end
  end
  local ordered = discover.order_candidates(cands, discover.recent, loaded)
  if #ordered == 0 then
    util.warn("no Postman JSON found under " .. root .. " — use :CurlmanLoad <path>")
    return
  end
  vim.ui.select(ordered, {
    prompt = "curlman: load from " .. root,
    format_item = function(c)
      local tags = {}
      if loaded[c.path] then tags[#tags + 1] = "loaded" end
      local seen = false
      for _, r in ipairs(discover.recent) do if r == c.path then seen = true break end end
      if seen and not loaded[c.path] then tags[#tags + 1] = "recent" end
      local suffix = #tags > 0 and ("  [" .. table.concat(tags, ",") .. "]") or ""
      return string.format("%-4s %s%s", c.kind == "environment" and "env" or "col", relpath(c.path, root), suffix)
    end,
  }, function(c)
    if not c then return end
    if c.kind == "environment" then M.load_environment(c.path) else M.load_collection(c.path) end
  end)
end

------------------------------------------------------------------- workspace ctx

local function ws_ctx()
  return {
    cfg = M.cfg,
    state = M.state,
    run = M.run_named,
    edit_var = M.edit_var,
    reset_overrides = M.reset_overrides,
    reload = function(name)
      local col = M.state.collections[name]
      if col and col.source then M.load_collection(col.source) end
    end,
    unload = M.unload_collection,
    load_menu = M.load_menu,
    pick_env = M.pick_env,
    set_cap = M.set_cap,
    diff_request = M.diff_request,
    save_request = M.save_request,
    show_body = function(e) ui.show_body(e, M.cfg) end,
    show_info = ui.show_info,
    copy_entry = M.copy_entry_prompt,
    copy_request = M.copy_request_named,
  }
end

function M.open_ui() workspace.open(ws_ctx()) end
function M.toggle_ui() workspace.toggle(ws_ctx()) end

------------------------------------------------------------------- sample/demo

local function sample_path(name)
  local found = vim.api.nvim_get_runtime_file("lua/curlman/sample/" .. name, false)
  return found and found[1] or nil
end

------------------------------------------------------------------- commands

local function create_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd("Curlman", function() ui.pick_request(M.state.requests, M.send) end, { desc = "curlman: pick & send a request" })
  cmd("CurlmanPick", function() ui.pick_request(M.state.requests, M.send) end, { desc = "curlman: pick & send a request" })
  cmd("CurlmanUI", function() M.toggle_ui() end, { desc = "curlman: toggle the workspace" })
  cmd("CurlmanRun", function()
    if M.state.last_request then M.send(M.state.last_request) else ui.pick_request(M.state.requests, M.send) end
  end, { desc = "curlman: re-send the last request" })

  cmd("CurlmanLoad", function(o)
    if o.args ~= "" then M.load_collection(o.args) else M.load_menu() end
  end, { nargs = "?", complete = "file", desc = "curlman: load a collection (menu if no arg)" })
  cmd("CurlmanLoadEnv", function(o)
    if o.args ~= "" then M.load_environment(o.args)
    else vim.ui.input({ prompt = "environment file: ", completion = "file" }, function(p) if p and p ~= "" then M.load_environment(p) end end) end
  end, { nargs = "?", complete = "file", desc = "curlman: load an environment" })

  cmd("CurlmanEnv", function() M.pick_env() end, { desc = "curlman: choose environment" })
  cmd("CurlmanInfo", function() ui.show_info(M.state.last_result) end, { desc = "curlman: response info" })
  cmd("CurlmanDiff", function()
    if M.state.last_entry then M.diff_request(history.key(M.state.last_entry.config, M.state.last_entry.method, M.state.last_entry.name))
    else util.warn("no responses yet") end
  end, { desc = "curlman: diff the last request's responses" })
  cmd("CurlmanHistory", function() M.toggle_ui() end, { desc = "curlman: open the workspace/history" })
  cmd("CurlmanClear", function() history.clear_all(); if workspace.is_open() then workspace.redraw() end; util.info("history cleared") end, { desc = "curlman: clear all history" })
  cmd("CurlmanSave", function()
    if not M.state.last_entry then util.warn("no response to save"); return end
    local e = M.state.last_entry
    local col = M.state.collections[e.config]
    ui.save_entry(e, history.suggest_save_path(col and col.source, e.name, e.timestamp, e.filetype))
  end, { desc = "curlman: save the last response" })
  cmd("CurlmanJq", function(o)
    ui.jq_view(M.state.last_result and M.state.last_result.body, o.args ~= "" and o.args or ".")
  end, { nargs = "?", desc = "curlman: filter last response through jq" })
  cmd("CurlmanCopy", function(o)
    if not M.state.last_entry then util.warn("no request yet"); return end
    if o.args ~= "" then ui.to_buffer(o.args, M.state.last_entry, M.cfg)
    else vim.ui.select({ "request", "response", "both" }, { prompt = "copy to buffer:" },
      function(k) if k then ui.to_buffer(k, M.state.last_entry, M.cfg) end end) end
  end, { nargs = "?", complete = function() return { "request", "response", "both" } end,
    desc = "curlman: copy last request/response to a buffer" })
  cmd("CurlmanReload", function()
    for _, name in ipairs(vim.deepcopy(M.state.config_order)) do
      local col = M.state.collections[name]
      if col and col.source then M.load_collection(col.source) end
    end
    M.load_secrets()
    util.info("reloaded collections & secrets")
  end, { desc = "curlman: reload collections & secrets" })
  cmd("CurlmanDemo", function()
    local col = sample_path("demo.postman_collection.json")
    local env = sample_path("demo.postman_environment.json")
    if col then M.load_collection(col) else util.err("sample not found on runtimepath") end
    if env then M.load_environment(env) end
    util.info("demo loaded — :CurlmanUI or :Curlman (hits postman-echo.com)")
  end, { desc = "curlman: load the bundled demo" })
end

local function install_keymaps()
  local m = { Cp = "Curlman", Cu = "CurlmanUI", Cr = "CurlmanRun", Ce = "CurlmanEnv", Cl = "CurlmanLoad",
    Ci = "CurlmanInfo", Cd = "CurlmanDiff", Ch = "CurlmanHistory", Cs = "CurlmanSave" }
  for lhs, command in pairs(m) do
    vim.keymap.set("n", "<leader>" .. lhs, "<cmd>" .. command .. "<cr>", { desc = command })
  end
end

function M.load_configured()
  local function as_list(v)
    if v == nil then return {} end
    if type(v) == "table" then return v end
    return { v }
  end
  for _, p in ipairs(as_list(M.cfg.collection)) do M.load_collection(p) end
  for _, d in ipairs(M.cfg.collection_dirs or {}) do
    for _, f in ipairs(discover.find(d)) do if f.kind == "collection" then M.load_collection(f.path) end end
  end
  for _, p in ipairs(as_list(M.cfg.environment)) do M.load_environment(p) end
end

function M.setup(user_config)
  M.cfg = config.build(user_config)
  history.default_cap = (M.cfg.history and M.cfg.history.max_recent) or 10
  discover.state_file = M.cfg.history and M.cfg.history.state_file
  ui.setup_highlights()
  create_commands()
  discover.load_recent()
  M.load_configured()
  M.load_secrets()
  if M.cfg.keymaps then install_keymaps() end
  vim.api.nvim_create_autocmd("ColorScheme", { callback = function() ui.setup_highlights() end })
  return M
end

return M
