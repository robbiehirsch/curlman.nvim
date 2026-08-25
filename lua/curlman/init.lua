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
local runner = require("curlman.runner")
local ui = require("curlman.ui")
local history = require("curlman.history")
local discover = require("curlman.discover")
local workspace = require("curlman.workspace")
local profiles = require("curlman.profiles")
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

local function context_for(req, profile)
  local col = req.collection and M.state.collections[req.collection]
  if profile then
    -- multi-profile runs: the profile REPLACES the env layer, and in-memory
    -- overrides/session tweaks are deliberately excluded so every profile
    -- resolves from the same clean slate (secrets & shell env still apply —
    -- tokens usually live there).
    return {
      overrides = {},
      session = {},
      secrets = M.state.secrets,
      env = profile.values or {},
      collection = col and col.vars_map or {},
      allow_shell = M.cfg.shell_env,
      shell_prefix = M.cfg.shell_env_prefix,
    }
  end
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

------------------------------------------------------------ profiles & multi-run

--- The effective variable table a collection resolves against right now
--- (override > session > env > collection), limited to referenced keys.
--- This is what :CurlmanProfileSave snapshots — it makes today's unsaved
--- in-memory tweaks durable.
function M.effective_vars(config_name)
  local col = M.state.collections[config_name]
  if not col then return {} end
  local env = M.state.current_env and M.state.environments[M.state.current_env]
  local out = {}
  for key in pairs(col.referenced or {}) do
    local v = (col.overrides and col.overrides[key])
      or M.state.session_vars[key]
      or (env and env.map[key])
      or col.vars_map[key]
    if v ~= nil then out[key] = tostring(v) end
  end
  return out
end

--- Run one request once per named profile (sequentially, so history order is
--- deterministic); entries are tagged with their profile and handed to the
--- compare UI (auto-diff for 2, pair picker for 3+).
function M.run_multi(req, profile_names, on_done)
  local entries, failed = {}, {}
  local function step(i)
    if i > #profile_names then
      if #failed > 0 then util.warn("profile(s) not found: " .. table.concat(failed, ", ")) end
      if on_done then on_done(entries) else ui.compare_entries(entries) end
      return
    end
    local pname = profile_names[i]
    local prof = profiles.get(pname)
    if not prof then
      failed[#failed + 1] = pname
      return step(i + 1)
    end
    local resolved, unresolved = vars.resolve_request(req, context_for(req, prof))
    if #unresolved > 0 then
      util.warn("[" .. pname .. "] unresolved: {{" .. table.concat(unresolved, "}}, {{") .. "}}")
    end
    util.info("→ [" .. pname .. "] " .. resolved.method .. " " .. resolved.url)
    curl.execute(resolved, M.cfg.curl, function(result)
      local lines = ui.format_lines(result, M.cfg)
      local _, entry = history.record(resolved, result, lines)
      entry.profile = pname
      M.state.last_request = req
      M.state.last_result = result
      M.state.last_entry = entry
      entries[#entries + 1] = entry
      if workspace.is_open() then workspace.redraw() end
      vim.schedule(function() step(i + 1) end)
    end)
  end
  step(1)
end

-------------------------------------------------------- postman CLI collection run

--- Every variable the CLI should be handed, resolved through curlman's normal
--- precedence (override > session > secrets > shell > env > collection). We
--- take the union of every layer's keys rather than only the statically
--- referenced ones, because scripts in the collection can read variables that
--- never appear literally as {{var}} anywhere.
local function runner_env_values(config_name)
  local col = M.state.collections[config_name]
  if not col then return {} end
  local ctx = context_for({ collection = config_name })

  local keys = {}
  local function add_keys(t) for k in pairs(t or {}) do keys[tostring(k)] = true end end
  add_keys(col.vars_map)
  add_keys(ctx.env)
  add_keys(ctx.secrets)
  add_keys(ctx.session)
  add_keys(ctx.overrides)
  add_keys(col.referenced)

  local out = {}
  for k in pairs(keys) do
    -- Reuse resolve_string so precedence (and shell-env fallback) is defined
    -- in exactly one place rather than duplicated here.
    local v, unresolved = vars.resolve_string("{{" .. k .. "}}", ctx)
    if #unresolved == 0 and v ~= nil then out[k] = tostring(v) end
  end
  return out
end

--- Run an entire collection through the Postman CLI / newman.
--- Each execution in the reporter output is recorded as its own history entry
--- under the same key curl would have used, so the results are saveable,
--- organizable and diffable exactly like curl responses — and a CLI run can be
--- diffed against a curl run of the same request.
function M.run_collection(config_name, folder)
  local col = config_name and M.state.collections[config_name]
  if not col then util.err("config not loaded: " .. tostring(config_name)); return end
  if not col.source then util.err("'" .. config_name .. "' has no source file to hand the runner"); return end

  local rcfg = M.cfg.runner or {}
  local kind, derr = runner.detect(rcfg.mode)
  if not kind then util.err(derr); return end

  -- Hand the CLI a real Postman environment file built from our resolved vars.
  local env_path = util.tempname() .. ".postman_environment.json"
  local values = runner_env_values(config_name)
  local wrote, werr = util.write_file(env_path, profiles.encode(config_name .. " (curlman)", values))
  if not wrote then util.err("could not write runner environment: " .. tostring(werr)); return end

  util.info("→ [" .. runner.spec(kind).label .. "] running '" .. config_name .. "'"
    .. (folder and folder ~= "" and (" / " .. folder) or ""))

  runner.run_collection({
    collection_path = col.source,
    collection_name = config_name,
    env_path = env_path,
    -- lets the runner recover folder paths, so CLI and curl share history buckets
    items = col.requests,
    mode = rcfg.mode,
    folder = folder,
    bail = rcfg.bail,
    insecure = rcfg.insecure,
    iteration_data = rcfg.iteration_data,
    iteration_count = rcfg.iteration_count,
    timeout_request = rcfg.timeout_request,
    extra_args = rcfg.extra_args,
    runner_cfg = rcfg,
  }, function(err, entries, summary, meta)
    os.remove(util.expand(env_path))
    if err then util.err(err); return end

    for _, e in ipairs(entries) do
      local lines = ui.format_lines(e.result, M.cfg)
      local _, entry = history.record(e.request, e.result, lines)
      entry.via = meta.kind
      entry.assertions = e.result.assertions
      M.state.last_request = e.request
      M.state.last_result = e.result
      M.state.last_entry = entry
      if M.cfg.history.enabled and M.cfg.history.autosave and e.result.ok then
        history.save_entry(entry, history.suggest_save_path(col.source, entry.name, entry.timestamp, entry.filetype))
      end
    end

    if workspace.is_open() then workspace.redraw()
    elseif M.state.last_result then ui.show_response(M.state.last_result, ui.format_lines(M.state.last_result, M.cfg), M.cfg) end

    local msg = string.format("%s: %d/%d requests ok", meta.label,
      (summary.requests or 0) - (summary.requests_failed or 0), summary.requests or 0)
    if (summary.assertions or 0) > 0 then
      msg = msg .. string.format(" · %d/%d assertions passed",
        summary.assertions - (summary.assertions_failed or 0), summary.assertions)
    end

    -- Name what actually broke. A bare count tells you something is wrong but
    -- not which request, and a collection run can be long enough that scrolling
    -- the workspace to find the red one is real friction.
    local bad = {}
    for _, e in ipairs(entries) do
      if e.result.transport_error then
        bad[#bad + 1] = "  ✗ " .. e.request.display .. " — " .. e.result.transport_error
      elseif (e.result.assertions_failed or 0) > 0 then
        bad[#bad + 1] = string.format("  ✗ %s — %d assertion(s) failed",
          e.request.display, e.result.assertions_failed)
      end
    end
    if #bad > 0 then
      util.warn(msg .. "\n" .. table.concat(bad, "\n"))
    else
      util.info(msg)
    end
  end)
end

--- Pick a loaded collection (or use the only one) and run it through the CLI.
function M.run_collection_pick(folder)
  local names = M.state.config_order
  if #names == 0 then util.warn("no collections loaded — :CurlmanLoad <file> or :CurlmanDemo"); return end
  if #names == 1 then M.run_collection(names[1], folder); return end
  vim.ui.select(names, { prompt = "curlman: run collection with the Postman CLI" }, function(choice)
    if choice then M.run_collection(choice, folder) end
  end)
end

--- Pick a request, multi-select profiles, fan out.
function M.run_with()
  if #profiles.names() == 0 then
    util.warn("no profiles yet — :CurlmanProfileSave <name> snapshots the current variables into one")
    return
  end
  ui.pick_request(M.state.requests, function(req)
    ui.pick_profiles_multi("run '" .. (req.display or req.name) .. "' with:", function(chosen)
      M.run_multi(req, chosen)
    end)
  end)
end

--- Snapshot current effective variables into a named profile.
function M.profile_save(name)
  local function snapshot(nm, col_name)
    local path, err = profiles.save(nm, col_name and M.effective_vars(col_name) or {})
    if path then util.info("profile '" .. nm .. "' saved → " .. path)
    else util.err("profile save failed: " .. tostring(err)) end
  end
  local function with_collection(nm)
    local order = M.state.config_order
    if #order > 1 then
      vim.ui.select(order, { prompt = "snapshot variables of which collection?" }, function(c)
        if c then snapshot(nm, c) end
      end)
    else
      snapshot(nm, order[1])
    end
  end
  if name and name ~= "" then
    with_collection(name)
  else
    vim.ui.input({ prompt = "profile name: " }, function(nm)
      if nm and nm ~= "" then with_collection(nm) end
    end)
  end
end

--- Manage menu: every profile action in one place.
function M.manage_profiles()
  local names = profiles.names_fav_first()
  local items = {}
  for _, n in ipairs(names) do items[#items + 1] = { kind = "profile", name = n } end
  items[#items + 1] = { kind = "new" }
  vim.ui.select(items, {
    prompt = "curlman profiles",
    format_item = function(it)
      if it.kind == "new" then return "[ new profile from current variables… ]" end
      local p = profiles.get(it.name)
      local n = 0
      for _ in pairs(p and p.values or {}) do n = n + 1 end
      return (profiles.is_fav_profile(it.name) and "★ " or "  ") .. it.name .. "  (" .. n .. " vars)"
    end,
  }, function(it)
    if not it then return end
    if it.kind == "new" then return M.profile_save(nil) end
    local name = it.name
    local actions = { "edit file", "rename", "duplicate", "save a copy to…", "toggle favourite", "delete" }
    vim.ui.select(actions, { prompt = "profile '" .. name .. "'" }, function(a)
      if a == "edit file" then
        local prof = profiles.get(name)
        if prof and prof.path then vim.cmd("edit " .. vim.fn.fnameescape(prof.path)) end
      elseif a == "rename" then
        vim.ui.input({ prompt = "rename to: ", default = name }, function(nm)
          if nm and nm ~= "" and nm ~= name then
            local _, err = profiles.rename(name, nm)
            if err then util.err(err) else util.info("renamed → " .. nm) end
          end
        end)
      elseif a == "duplicate" then
        vim.ui.input({ prompt = "duplicate as: ", default = name .. "-copy" }, function(nm)
          if nm and nm ~= "" then
            local _, err = profiles.duplicate(name, nm)
            if err then util.err(err) else util.info("duplicated → " .. nm) end
          end
        end)
      elseif a == "save a copy to…" then
        local prof = profiles.get(name)
        local suggestion = vim.fn.getcwd() .. "/" .. util.slug(name) .. ".postman_environment.json"
        vim.ui.input({ prompt = "save copy to: ", default = suggestion, completion = "file" }, function(path)
          if path and path ~= "" and prof then
            local ok, err = profiles.save(name, prof.values, path)
            if ok then util.info("copy saved → " .. path) else util.err(tostring(err)) end
          end
        end)
      elseif a == "toggle favourite" then
        local fav = profiles.toggle_fav_profile(name)
        util.info(name .. (fav and " ★ favourited" or " unfavourited"))
      elseif a == "delete" then
        vim.ui.select({ "Yes — delete '" .. name .. "'", "No" }, { prompt = "really delete?" }, function(c)
          if c and c:sub(1, 1) == "Y" then
            profiles.delete(name)
            util.info("deleted '" .. name .. "'")
          end
        end)
      end
    end)
  end)
end

--- Toggle ★ on an endpoint (request). Favourites float to the top of :Curlman.
function M.fav_endpoint()
  ui.pick_request(M.state.requests, function(r)
    local fav = profiles.toggle_fav_endpoint(r)
    util.info((r.display or r.name) .. (fav and " ★ favourited" or " unfavourited"))
  end, { prompt = "toggle favourite endpoint" })
end

-------------------------------------------------------------- history actions

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
    if o.args ~= "" then
      M.load_environment(o.args)
    else
      vim.ui.input({ prompt = "environment file: ", completion = "file" }, function(p)
        if p and p ~= "" then M.load_environment(p) end
      end)
    end
  end, { nargs = "?", complete = "file", desc = "curlman: load an environment" })

  cmd("CurlmanEnv", function() M.pick_env() end, { desc = "curlman: choose environment" })
  cmd("CurlmanInfo", function() ui.show_info(M.state.last_result) end, { desc = "curlman: response info" })
  cmd("CurlmanDiff", function()
    if M.state.last_entry then M.diff_request(history.key(M.state.last_entry.config, M.state.last_entry.method, M.state.last_entry.name))
    else util.warn("no responses yet") end
  end, { desc = "curlman: diff the last request's responses" })
  cmd("CurlmanHistory", function() M.toggle_ui() end, { desc = "curlman: open the workspace/history" })
  cmd("CurlmanClear", function()
    history.clear_all()
    if workspace.is_open() then workspace.redraw() end
    util.info("history cleared")
  end, { desc = "curlman: clear all history" })
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
  cmd("CurlmanProfiles", function() M.manage_profiles() end,
    { desc = "curlman: manage variable profiles (edit/rename/dup/delete/favourite)" })
  cmd("CurlmanProfileSave", function(o) M.profile_save(o.args ~= "" and o.args or nil) end,
    { nargs = "?", desc = "curlman: snapshot current variables into a named profile" })
  cmd("CurlmanRunCollection", function(o)
    -- Optional arg is a folder name to scope the run to.
    M.run_collection_pick(o.args ~= "" and o.args or nil)
  end, { nargs = "?", desc = "curlman: run a whole collection via the Postman CLI / newman" })
  cmd("CurlmanRunner", function()
    local kind, derr = runner.detect(M.cfg.runner and M.cfg.runner.mode)
    if kind then util.info("collection runner: " .. runner.spec(kind).label .. " (" .. kind .. ")")
    else util.warn(derr) end
  end, { desc = "curlman: report which Postman collection runner is available" })
  cmd("CurlmanRunWith", function() M.run_with() end,
    { desc = "curlman: run one request across several profiles and compare" })
  cmd("CurlmanFav", function() M.fav_endpoint() end,
    { desc = "curlman: toggle favourite on an endpoint (floats to top of pickers)" })
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
  profiles.setup(M.cfg.profiles)
  -- editing a profile file (:CurlmanProfiles → edit) hot-reloads the store
  if M.cfg.profiles and M.cfg.profiles.dir then
    vim.api.nvim_create_autocmd("BufWritePost", {
      pattern = vim.fn.fnamemodify(util.expand(M.cfg.profiles.dir), ":p") .. "*.json",
      callback = function() profiles.load_all() end,
    })
  end
  M.load_configured()
  M.load_secrets()
  if M.cfg.keymaps then install_keymaps() end
  vim.api.nvim_create_autocmd("ColorScheme", { callback = function() ui.setup_highlights() end })
  return M
end

return M
