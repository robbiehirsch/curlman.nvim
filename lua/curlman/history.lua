-- curlman.history — per-request response history. Each distinct request
-- (identified by config + method + name) gets its own bucket of responses, with
-- a configurable cap. Every entry records the resolved URI and source config so
-- a wall of GET/POST responses stays legible. Optionally persisted to a folder
-- next to the collection file.

local util = require("curlman.util")

local M = {}

M.store = {}       -- request_key -> { entries = {newest-first}, cap = n|nil, request = req }
M.order = {}       -- request_keys in first-seen order (stable card order)
M.default_cap = 10 -- responses kept per request unless overridden

local SEP = "\0"

--- Stable identity for a request (independent of resolved variable values, so
--- the same call groups together even when base_url/env changes).
function M.key(config, method, name)
  return table.concat({ config or "?", method or "?", name or "?" }, SEP)
end

local ext_for = {
  json = "json", xml = "xml", html = "html",
  javascript = "js", csv = "csv", yaml = "yaml", text = "txt",
}

--- Build a compact entry from a curl result + formatted body lines.
function M.make_entry(request, result, body_lines)
  request = request or result.request or {}
  local m = result.metrics or {}
  local ts = os.time()
  return {
    timestamp = ts,
    time_str = os.date("%H:%M:%S", ts),
    method = request.method,
    name = request.display or request.name,
    config = request.collection,
    uri = m.url_effective or request.url,
    ok = result.ok,
    status = result.status,
    reason = result.reason,
    time_total = m.time_total,
    size = m.size_download,
    content_type = result.content_type,
    filetype = result.filetype or "text",
    lines = body_lines,
    raw_headers = result.raw_headers,
    metrics = m,
    result = result,
    request = request,
  }
end

--- Record a completed response under its request bucket, enforcing the cap.
-- @return key, entry
function M.record(request, result, body_lines)
  local key = M.key(request.collection, request.method, request.display or request.name)
  local rec = M.store[key]
  if not rec then
    rec = { entries = {}, cap = nil, request = request }
    M.store[key] = rec
    M.order[#M.order + 1] = key
  end
  rec.request = request
  local entry = M.make_entry(request, result, body_lines)
  table.insert(rec.entries, 1, entry)
  M.trim(key)
  return key, entry
end

--- Trim a request's entries down to its effective cap.
function M.trim(key)
  local rec = M.store[key]
  if not rec then return end
  local cap = rec.cap or M.default_cap
  if cap and cap > 0 then
    while #rec.entries > cap do rec.entries[#rec.entries] = nil end
  end
end

--- Set the cap for one request (key) or, when key is nil, the default for all.
function M.set_cap(key, n)
  if key then
    local rec = M.store[key]
    if rec then rec.cap = n; M.trim(key) end
  else
    M.default_cap = n
    for k in pairs(M.store) do M.trim(k) end
  end
end

--- Clear one request's history (removes the whole bucket).
function M.clear(key)
  if not M.store[key] then return false end
  M.store[key] = nil
  for i, k in ipairs(M.order) do
    if k == key then table.remove(M.order, i); break end
  end
  return true
end

--- Clear all history.
function M.clear_all()
  M.store = {}
  M.order = {}
end

--- Ordered list of request buckets for rendering: { key, request, entries, cap, latest }.
function M.cards()
  local out = {}
  for _, key in ipairs(M.order) do
    local rec = M.store[key]
    if rec then
      out[#out + 1] = {
        key = key,
        request = rec.request,
        entries = rec.entries,
        cap = rec.cap or M.default_cap,
        latest = rec.entries[1],
      }
    end
  end
  return out
end

function M.get(key) return M.store[key] end

--- Human label for an entry (pickers / diff).
function M.entry_label(e)
  local parts = {}
  if e.method then parts[#parts + 1] = e.method end
  parts[#parts + 1] = e.name or "response"
  if e.profile then parts[#parts + 1] = "[" .. e.profile .. "]" end
  if e.status then parts[#parts + 1] = tostring(e.status) end
  if e.time_total then parts[#parts + 1] = util.human_time(e.time_total) end
  return table.concat(parts, " · ") .. "  (" .. (e.time_str or "") .. ")"
end

--- Directory that history for a given config file should live in:
---   <dir-of-config>/<config-filename-without-.json>-curlman-history/
function M.history_dir_for(config_path)
  config_path = util.expand(config_path or "")
  local dir = config_path:match("^(.*)/[^/]*$") or "."
  local base = config_path:match("([^/]*)$") or "curlman"
  base = base:gsub("%.json$", "")
  if base == "" then base = "curlman" end
  return dir .. "/" .. base .. "-curlman-history"
end

--- Suggested save path for one response (a sibling history folder next to config).
function M.suggest_save_path(config_path, request_name, timestamp, filetype)
  local dir = M.history_dir_for(config_path)
  local ext = ext_for[filetype or "text"] or "txt"
  local stamp = os.date("%Y%m%d-%H%M%S", timestamp or os.time())
  return dir .. "/" .. util.slug(request_name) .. "-" .. stamp .. "-response." .. ext
end

--- Ensure a directory exists (best effort).
local function ensure_dir(dir)
  if _G.vim and vim.fn and vim.fn.mkdir then
    pcall(vim.fn.mkdir, util.expand(dir), "p")
  else
    os.execute('mkdir -p "' .. util.expand(dir) .. '" 2>/dev/null')
  end
end

--- Write one entry's body to a path (creating parent dirs). @return path or nil,err
function M.save_entry(entry, path)
  local parent = util.expand(path):match("^(.*)/[^/]*$")
  if parent then ensure_dir(parent) end
  local ok, werr = util.write_file(path, table.concat(entry.lines or {}, "\n"))
  if not ok then return nil, werr end
  return path
end

return M
