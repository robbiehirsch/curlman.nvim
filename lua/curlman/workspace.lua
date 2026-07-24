-- curlman.workspace — the two-panel "dashboard". Left = config cards
-- (variables + requests, collapsible, editable in memory). Right = per-request
-- cards, each with its own response history. Rendering is done by pure functions
-- (build_* / render_*) so it can be unit-tested without Neovim; the rest wires
-- those into scratch buffers with buffer-local keymaps.

local util = require("curlman.util")
local history = require("curlman.history")

local M = {}

M.ns = nil
M.left = {}
M.right = {}
M.tab = nil
M.nodes = {}   -- buf -> { [lineidx1based] = node }
M.ctx = nil    -- callbacks + state, injected by init

------------------------------------------------------------------ pure helpers

local function is_secret(key)
  local k = tostring(key):lower()
  return k:find("token") or k:find("secret") or k:find("password")
    or k:find("passwd") or k:find("key") or k:find("auth") or k:find("bearer")
end
M._is_secret = is_secret

local function display_val(key, val)
  val = tostring(val or "")
  if val == "" then return "(empty)" end
  if is_secret(key) then return "••••••" end
  if #val > 52 then return val:sub(1, 49) .. "…" end
  return val
end

local function status_group(status)
  status = tonumber(status)
  if not status then return "CurlmanStatusErr" end
  if status >= 200 and status < 300 then return "CurlmanStatus2xx" end
  if status >= 300 and status < 400 then return "CurlmanStatus3xx" end
  if status >= 400 and status < 500 then return "CurlmanStatus4xx" end
  return "CurlmanStatus5xx"
end

-- segment builder: accumulates text and byte-accurate highlight spans per line
local function seg()
  local parts, spans, col = {}, {}, 0
  return {
    add = function(text, group)
      text = text or ""
      if group and text ~= "" then spans[#spans + 1] = { s = col, e = col + #text, group = group } end
      parts[#parts + 1] = text
      col = col + #text
    end,
    done = function() return table.concat(parts), spans end,
  }
end

------------------------------------------------------------- build view models

--- All variables in play for a config: its declared vars + the active
--- environment's vars + any in-memory overrides, each shown with its EFFECTIVE
--- value (override > env > collection) and where that value comes from.
local function build_vars_view(col, env_map, referenced)
  env_map = env_map or {}
  referenced = referenced or {}
  local order, seen = {}, {}
  local function push(k) if not seen[k] then seen[k] = true; order[#order + 1] = k end end
  for _, v in ipairs(col.vars or {}) do push(v.key) end
  -- remaining keys (env + overrides + referenced-but-undefined), sorted
  local rest = {}
  for k in pairs(env_map) do if not seen[k] then rest[k] = true end end
  if col.overrides then for k in pairs(col.overrides) do if not seen[k] then rest[k] = true end end end
  for k in pairs(referenced) do if not seen[k] then rest[k] = true end end
  local restlist = {}
  for k in pairs(rest) do restlist[#restlist + 1] = k end
  table.sort(restlist)
  for _, k in ipairs(restlist) do push(k) end

  local out = {}
  for _, key in ipairs(order) do
    local overridden = col.overrides ~= nil and col.overrides[key] ~= nil
    local source, val
    if overridden then source, val = "override", col.overrides[key]
    elseif env_map[key] ~= nil then source, val = "env", env_map[key]
    elseif col.vars_map and col.vars_map[key] ~= nil then source, val = "collection", col.vars_map[key]
    else source, val = "ref", "" end -- referenced by a request but not defined anywhere
    local disp = display_val(key, val)
    if source == "ref" then disp = "(unset)" end
    out[#out + 1] = {
      key = key, display_value = disp,
      overridden = overridden, secret = is_secret(key), source = source,
    }
  end
  return out
end

function M.build_config_cards(state)
  local cards = {}
  for _, name in ipairs(state.config_order or {}) do
    local col = state.collections[name]
    if col then
      local env = state.current_env and state.environments and state.environments[state.current_env]
      cards[#cards + 1] = {
        name = name,
        source = col.source,
        env_name = state.current_env,
        expanded = state.config_expanded[name] ~= false, -- default expanded
        vars = build_vars_view(col, env and env.map or {}, col.referenced),
        requests = col.requests or {},
      }
    end
  end
  return cards
end

function M.build_request_cards(cards, expanded, preview_mode, preview_lines)
  expanded = expanded or {}
  preview_mode = preview_mode or {}
  local out = {}
  for _, c in ipairs(cards) do
    local req = c.request or {}
    out[#out + 1] = {
      key = c.key,
      method = req.method,
      name = req.display or req.name,
      config = req.collection,
      cap = c.cap,
      latest = c.latest,
      expanded = expanded[c.key] ~= false,     -- default expanded
      preview_mode = preview_mode[c.key] or "truncated", -- truncated | full | hidden
      preview_lines = preview_lines or 12,
      entries = c.entries or {},
    }
  end
  return out
end

------------------------------------------------------------------- render pure

function M.render_configs(cards)
  local lines, hl, nodes = {}, {}, {}
  local function push(line, spans, node)
    lines[#lines + 1] = line
    nodes[#lines] = node
    for _, s in ipairs(spans or {}) do
      hl[#hl + 1] = { line = #lines - 1, s = s.s, e = s.e, group = s.group }
    end
  end

  do
    local s = seg()
    s.add(" CONFIGS", "CurlmanTitle")
    s.add("   (l:load  e:edit  y:copy-curl  R:reload  D:remove)", "CurlmanDim")
    local l, sp = s.done(); push(l, sp, { kind = "title" })
  end

  if #cards == 0 then
    push("", {}, { kind = "blank" })
    push("  no configs loaded.", {}, { kind = "empty" })
    push("  press  l  to load one from this project,", {}, { kind = "empty" })
    push("  or run :CurlmanLoad <path>", {}, { kind = "empty" })
    return { lines = lines, hl = hl, nodes = nodes }
  end

  for _, c in ipairs(cards) do
    local s = seg()
    s.add(c.expanded and "▾ " or "▸ ", "CurlmanDim")
    s.add(c.name, "CurlmanConfig")
    if c.env_name then s.add("  ⟨" .. c.env_name .. "⟩", "CurlmanDim") end
    local l, sp = s.done(); push(l, sp, { kind = "config_header", config = c.name })

    if c.expanded then
      if #c.vars == 0 then
        push("     (no variables — load an environment or add collection vars)", {}, { kind = "empty" })
      end
      for _, v in ipairs(c.vars) do
        local vs = seg()
        vs.add(v.overridden and "   * " or "     ", "CurlmanOverride")
        vs.add(v.key, "CurlmanVarKey")
        vs.add(" = ", "CurlmanDim")
        vs.add(v.display_value, v.overridden and "CurlmanOverride" or "CurlmanDim")
        if v.source == "env" then vs.add("   ·env", "CurlmanDim")
        elseif v.source == "override" then vs.add("   ·set", "CurlmanDim")
        elseif v.source == "ref" then vs.add("   ·needs value", "CurlmanOverride") end
        local vl, vsp = vs.done(); push(vl, vsp, { kind = "var", config = c.name, key = v.key })
      end
      for _, r in ipairs(c.requests) do
        local rs = seg()
        rs.add("     ")
        rs.add(string.format("%-5s ", r.method), "CurlmanMethod")
        rs.add(r.display or r.name or "")
        local rl, rsp = rs.done()
        push(rl, rsp, { kind = "request", config = c.name, method = r.method, display = r.display or r.name })
      end
    end
    push("", {}, { kind = "blank" })
  end
  return { lines = lines, hl = hl, nodes = nodes }
end

function M.render_requests(cards)
  local lines, hl, nodes = {}, {}, {}
  local function push(line, spans, node)
    lines[#lines + 1] = line
    nodes[#lines] = node
    for _, s in ipairs(spans or {}) do
      hl[#hl + 1] = { line = #lines - 1, s = s.s, e = s.e, group = s.group }
    end
  end

  do
    local s = seg()
    s.add(" REQUESTS & HISTORY", "CurlmanTitle")
    s.add("   (⏎:open  t:preview  y:copy  x:clear  c:cap  d:diff)", "CurlmanDim")
    local l, sp = s.done(); push(l, sp, { kind = "title" })
  end

  if #cards == 0 then
    push("", {}, { kind = "blank" })
    push("  no requests run yet.", {}, { kind = "empty" })
    push("  select a request on the left and press ⏎.", {}, { kind = "empty" })
    return { lines = lines, hl = hl, nodes = nodes }
  end

  for _, c in ipairs(cards) do
    -- header
    local s = seg()
    s.add(c.expanded and "▾ " or "▸ ", "CurlmanDim")
    s.add((c.method or "?") .. " ", "CurlmanMethod")
    s.add(c.name or "")
    if c.latest and c.latest.status then
      s.add("   ")
      s.add(tostring(c.latest.status), status_group(c.latest.status))
      if c.latest.time_total then s.add(" · " .. util.human_time(c.latest.time_total), "CurlmanDim") end
    elseif c.latest and not c.latest.ok then
      s.add("   "); s.add("ERR", "CurlmanStatusErr")
    end
    if c.config then s.add("   (" .. c.config .. ")", "CurlmanDim") end
    s.add("   [" .. #c.entries .. "]", "CurlmanDim")
    local l, sp = s.done(); push(l, sp, { kind = "req_header", key = c.key })

    if c.expanded then
      local latest = c.entries[1]
      if latest then
        -- latest-response meta line (status/time/URI) + preview-mode marker
        local ms = seg()
        ms.add("     latest ", "CurlmanDim")
        ms.add("[" .. c.preview_mode .. "]", "CurlmanOverride")
        ms.add("  ", "CurlmanDim")
        ms.add(latest.ok and tostring(latest.status or "?") or "ERR", status_group(latest.status))
        ms.add("  " .. util.human_time(latest.time_total) .. "  " .. util.human_size(latest.size), "CurlmanDim")
        ms.add("  " .. (latest.uri or ""), "CurlmanDim")
        ms.add("   ⏎ open · t", "CurlmanDim")
        local ml, msp = ms.done(); push(ml, msp, { kind = "preview_meta", key = c.key, idx = 1 })

        if c.preview_mode ~= "hidden" then
          local body = latest.lines or {}
          local limit = (c.preview_mode == "truncated") and c.preview_lines or #body
          for i = 1, math.min(limit, #body) do
            push("     " .. body[i], {}, { kind = "preview", key = c.key, idx = 1 })
          end
          if c.preview_mode == "truncated" and #body > c.preview_lines then
            local more = seg()
            more.add("     … +" .. (#body - c.preview_lines) .. " more lines · ⏎ open", "CurlmanDim")
            local mrl, mrsp = more.done(); push(mrl, mrsp, { kind = "preview", key = c.key, idx = 1 })
          end
        end
      end
      -- older responses as compact lines
      for i = 2, #c.entries do
        local e = c.entries[i]
        local es = seg()
        es.add("       " .. (e.time_str or "") .. "  ", "CurlmanDim")
        es.add(e.ok and tostring(e.status or "?") or "ERR", status_group(e.status))
        es.add("  " .. util.human_time(e.time_total) .. "  " .. util.human_size(e.size), "CurlmanDim")
        es.add("  " .. (e.uri or ""), "CurlmanDim")
        local el, esp = es.done()
        push(el, esp, { kind = "hist_entry", key = c.key, idx = i })
      end
    end
    push("", {}, { kind = "blank" })
  end
  return { lines = lines, hl = hl, nodes = nodes }
end

------------------------------------------------------------------- nvim wiring

function M.is_open()
  return M.tab and vim.api.nvim_tabpage_is_valid(M.tab)
    and M.left.win and vim.api.nvim_win_is_valid(M.left.win)
    and M.right.win and vim.api.nvim_win_is_valid(M.right.win)
end

local function node_at(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return (M.nodes[buf] or {})[line]
end

local function apply(buf, model)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, model.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(model.hl) do
    pcall(vim.api.nvim_buf_add_highlight, buf, M.ns, h.group, h.line, h.s, h.e)
  end
  M.nodes[buf] = model.nodes
end

function M.redraw()
  if not M.is_open() then return end
  local st = M.ctx.state
  local preview_lines = (M.ctx.cfg.ui and M.ctx.cfg.ui.preview_lines) or 12
  apply(M.left.buf, M.render_configs(M.build_config_cards(st)))
  apply(M.right.buf, M.render_requests(
    M.build_request_cards(history.cards(), st.request_expanded, st.preview_mode, preview_lines)))
end

-- action handlers -----------------------------------------------------------

local function toggle(map, k) if map[k] == false then map[k] = true else map[k] = false end end

function M.on_left(action)
  local node = node_at(M.left.buf)
  if not node then return end
  local st = M.ctx.state
  if action == "enter" then
    if node.kind == "config_header" then
      toggle(st.config_expanded, node.config); M.redraw()
    elseif node.kind == "request" then
      M.ctx.run(node.config, node.method, node.display)
    elseif node.kind == "var" then
      M.ctx.edit_var(node.config, node.key)
    end
  elseif action == "toggle" then
    if node.kind == "config_header" then toggle(st.config_expanded, node.config); M.redraw() end
  elseif action == "edit" then
    if node.kind == "var" then M.ctx.edit_var(node.config, node.key)
    elseif node.kind == "config_header" then M.ctx.pick_env() end
  elseif action == "reload" then
    if node.config then M.ctx.reload(node.config) end
  elseif action == "remove" then
    if node.config then M.ctx.unload(node.config); M.redraw() end
  elseif action == "reset" then
    if node.config then M.ctx.reset_overrides(node.config); M.redraw() end
  elseif action == "load" then
    M.ctx.load_menu()
  elseif action == "copy" then
    if node.kind == "request" then M.ctx.copy_request(node.config, node.method, node.display) end
  end
end

function M.on_right(action)
  local node = node_at(M.right.buf)
  local key = node and node.key
  if action == "enter" then
    if node and node.kind == "req_header" then
      toggle(M.ctx.state.request_expanded, key); M.redraw()
    elseif node and node.idx and key then
      local rec = history.get(key)
      if rec and rec.entries[node.idx] then M.ctx.show_body(rec.entries[node.idx]) end
    end
  elseif action == "preview" then
    if key then
      local pm = M.ctx.state.preview_mode
      local cur = pm[key] or "truncated"
      pm[key] = (cur == "truncated" and "full") or (cur == "full" and "hidden") or "truncated"
      M.redraw()
    end
  elseif action == "toggle" then
    if node and node.kind == "req_header" then toggle(M.ctx.state.request_expanded, key); M.redraw() end
  elseif action == "clear" then
    if key then history.clear(key); M.redraw() end
  elseif action == "clear_all" then
    history.clear_all(); M.redraw()
  elseif action == "cap" then
    M.ctx.set_cap(key); -- prompts, then redraws
  elseif action == "cap_all" then
    M.ctx.set_cap(nil)
  elseif action == "diff" then
    if key then M.ctx.diff_request(key) end
  elseif action == "save" then
    if key then M.ctx.save_request(key) end
  elseif action == "info" then
    if key then
      local rec = history.get(key)
      local e = rec and (node.kind == "hist_entry" and rec.entries[node.idx] or rec.entries[1])
      if e then M.ctx.show_info(e.result) end
    end
  elseif action == "copy" then
    if key then M.ctx.copy_entry(key, (node and node.idx) or 1) end
  end
end

local function map(buf, lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
end

local function setup_keymaps(buf, side)
  local on = (side == "left") and M.on_left or M.on_right
  map(buf, "<CR>", function() on("enter") end)
  map(buf, "<Tab>", function() on("toggle") end)
  map(buf, "q", function() M.close() end)
  map(buf, "?", function() M.help() end)
  map(buf, "<Esc>", function() M.close() end)
  if side == "left" then
    map(buf, "e", function() on("edit") end)
    map(buf, "R", function() on("reload") end)
    map(buf, "D", function() on("remove") end)
    map(buf, "o", function() on("reset") end)
    map(buf, "l", function() on("load") end)
    map(buf, "y", function() on("copy") end)
  else
    map(buf, "t", function() on("preview") end)
    map(buf, "y", function() on("copy") end)
    map(buf, "x", function() on("clear") end)
    map(buf, "X", function() on("clear_all") end)
    map(buf, "c", function() on("cap") end)
    map(buf, "C", function() on("cap_all") end)
    map(buf, "d", function() on("diff") end)
    map(buf, "s", function() on("save") end)
    map(buf, "i", function() on("info") end)
  end
end

local function make_panel_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide" -- keep the panel alive when we open a body/diff/copy tab
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "curlman-panel"
  return buf
end

function M.open(ctx)
  M.ctx = ctx
  M.ns = M.ns or vim.api.nvim_create_namespace("curlman")
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(M.tab)
    M.redraw()
    return
  end
  vim.cmd("tabnew")
  M.tab = vim.api.nvim_get_current_tabpage()

  local lbuf = make_panel_buf("curlman://configs")
  local lwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(lwin, lbuf)

  vim.cmd("vertical rightbelow split")
  local rbuf = make_panel_buf("curlman://requests")
  local rwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(rwin, rbuf)

  local frac = (ctx.cfg.ui and ctx.cfg.ui.left_width) or 0.34
  vim.api.nvim_win_set_width(lwin, math.max(28, math.floor(vim.o.columns * frac)))

  for _, w in ipairs({ lwin, rwin }) do
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].wrap = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].cursorline = true
    vim.wo[w].winfixwidth = true
  end

  M.left = { win = lwin, buf = lbuf }
  M.right = { win = rwin, buf = rbuf }
  setup_keymaps(lbuf, "left")
  setup_keymaps(rbuf, "right")
  vim.api.nvim_set_current_win(lwin)
  M.redraw()
end

function M.close()
  if M.tab and vim.api.nvim_tabpage_is_valid(M.tab) then
    -- close the workspace tab
    local ok = pcall(vim.cmd, "tabclose")
    if not ok then
      for _, w in ipairs({ M.left.win, M.right.win }) do
        if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
      end
    end
  end
  M.tab, M.left, M.right = nil, {}, {}
end

function M.toggle(ctx)
  if M.is_open() then M.close() else M.open(ctx) end
end

function M.help()
  local lines = {
    " curlman workspace ",
    "",
    " Left panel — CONFIGS",
    "   ⏎    run request / fold config / edit variable",
    "   e    edit variable (in-memory)   o  reset overrides",
    "   y    copy request as a curl command → buffer",
    "   R    reload config from disk      D  remove config",
    "   l    load a collection            Tab  fold",
    "",
    " Right panel — REQUESTS & HISTORY",
    "   ⏎    open response in a pane / fold request",
    "   t    latest-response preview: truncated → full → hidden",
    "   y    copy request / response / both → buffer",
    "   x    clear this request's history",
    "   X    clear ALL history            c/C  set cap (this/all)",
    "   d    diff this request's responses (q/gt in diff to return)",
    "   s    save this request's history  i  timing/headers info",
    "",
    "   q / <Esc>   close workspace       ?  this help",
    "   <C-w> h/l   move between panels",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = width + 2, height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2), col = math.floor((vim.o.columns - width) / 2),
    style = "minimal", border = "rounded",
  })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end,
      { buffer = buf, nowait = true, silent = true })
  end
end

M._internal = { build_vars_view = build_vars_view, display_val = display_val, status_group = status_group }

return M
