-- curlman.vars — {{variable}} resolution across collection vars, the selected
-- environment, a gitignored secrets file, shell env vars, and Postman dynamic
-- variables ({{$guid}}, {{$timestamp}}, ...). Pure Lua; unit-testable.

local M = {}

local seeded = false
local function seed()
  if seeded then return end
  seeded = true
  local t = os.time()
  local c = math.floor((os.clock() or 0) * 1e6)
  math.randomseed(t + c)
end

--- RFC-4122-ish v4 UUID (random). Good enough for request ids / test data.
local function uuid4()
  seed()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(ch)
    local v = (ch == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

--- Resolve a Postman dynamic variable name (leading "$"). Returns nil if unknown.
local function dynamic(name)
  if name == "$guid" or name == "$randomUUID" then
    return uuid4()
  elseif name == "$timestamp" then
    return tostring(os.time())
  elseif name == "$isoTimestamp" then
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
  elseif name == "$randomInt" then
    seed()
    return tostring(math.random(0, 1000))
  elseif name == "$epoch" then
    return tostring(os.time())
  end
  return nil
end

--- Look a single key up across all sources in priority order.
-- ctx = { overrides, session, secrets, env, collection, allow_shell, shell_prefix }
local function lookup(key, ctx)
  if key:sub(1, 1) == "$" then
    return dynamic(key)
  end
  -- in-memory per-config overrides win over everything (the "what-if" tweak)
  if ctx.overrides and ctx.overrides[key] ~= nil then return tostring(ctx.overrides[key]) end
  if ctx.session and ctx.session[key] ~= nil then return tostring(ctx.session[key]) end
  if ctx.secrets and ctx.secrets[key] ~= nil then return tostring(ctx.secrets[key]) end
  if ctx.allow_shell then
    local e = os.getenv(key)
    if e then return e end
    local prefix = ctx.shell_prefix
    if prefix and prefix ~= "" then
      e = os.getenv(prefix .. key) or os.getenv((prefix .. key):upper())
      if e then return e end
    end
  end
  if ctx.env and ctx.env[key] ~= nil then return tostring(ctx.env[key]) end
  if ctx.collection and ctx.collection[key] ~= nil then return tostring(ctx.collection[key]) end
  return nil
end

--- Resolve every {{var}} in a string. Runs a few passes so a value that itself
-- contains {{...}} (indirection) gets resolved too. Returns resolved string and
-- a set-list of variable names that could not be resolved.
function M.resolve_string(s, ctx)
  if type(s) ~= "string" then return s, {} end
  local unresolved = {}
  local seen_unresolved = {}
  local pattern = "{{%s*([^{}]-)%s*}}"
  for _ = 1, 5 do
    if not s:find("{{") then break end
    s = s:gsub(pattern, function(key)
      local val = lookup(key, ctx)
      if val == nil then
        if not seen_unresolved[key] then
          seen_unresolved[key] = true
          unresolved[#unresolved + 1] = key
        end
        return "{{" .. key .. "}}" -- leave intact for now
      end
      return val
    end)
    -- if nothing resolvable remains, stop early
    local still = false
    for key in s:gmatch(pattern) do
      if lookup(key, ctx) ~= nil then still = true break end
    end
    if not still then break end
  end
  -- recompute unresolved against the final string (some may have resolved on later pass)
  unresolved = {}
  seen_unresolved = {}
  for key in s:gmatch(pattern) do
    if not seen_unresolved[key] then
      seen_unresolved[key] = true
      unresolved[#unresolved + 1] = key
    end
  end
  return s, unresolved
end

local function merge_unresolved(dst, src)
  for _, k in ipairs(src) do dst[#dst + 1] = k end
end

--- Resolve a whole request (deep copy; original left untouched).
-- @return resolved_request, unresolved_list
function M.resolve_request(req, ctx)
  local unresolved = {}
  local function rs(s)
    local out, u = M.resolve_string(s, ctx)
    merge_unresolved(unresolved, u)
    return out
  end

  local out = {
    name = req.name,
    display = req.display,
    method = req.method,
    collection = req.collection,
    source = req.source,
    url = rs(req.url),
    headers = {},
    auth = nil,
    body = nil,
  }

  for _, h in ipairs(req.headers or {}) do
    out.headers[#out.headers + 1] = { key = rs(h.key), value = rs(h.value) }
  end

  if req.auth then
    local params = {}
    for k, v in pairs(req.auth.params or {}) do
      params[k] = rs(tostring(v))
    end
    out.auth = { type = req.auth.type, params = params }
  end

  if req.body then
    local b = req.body
    if b.mode == "raw" then
      out.body = { mode = "raw", raw = rs(b.raw), language = b.language }
    elseif b.mode == "urlencoded" or b.mode == "formdata" then
      local params = {}
      for _, p in ipairs(b.params or {}) do
        params[#params + 1] = {
          key = rs(p.key),
          value = p.value ~= nil and rs(p.value) or nil,
          ptype = p.ptype,
          src = p.src and rs(p.src) or nil,
        }
      end
      out.body = { mode = b.mode, params = params }
    elseif b.mode == "graphql" then
      out.body = { mode = "graphql", query = rs(b.query), variables = b.variables and rs(b.variables) or nil }
    elseif b.mode == "file" then
      out.body = { mode = "file", src = b.src and rs(b.src) or nil }
    end
  end

  -- de-dup unresolved
  local seen, uniq = {}, {}
  for _, k in ipairs(unresolved) do
    if not seen[k] then seen[k] = true; uniq[#uniq + 1] = k end
  end
  return out, uniq
end

--- Collect {{variable}} names referenced in a string (skips dynamic {{$...}}).
local function collect_refs(s, set)
  if type(s) ~= "string" then return end
  for name in s:gmatch("{{%s*([^{}]-)%s*}}") do
    name = (name:gsub("^%s+", ""):gsub("%s+$", ""))
    if name ~= "" and name:sub(1, 1) ~= "$" then set[name] = true end
  end
end

--- Every variable name a (normalized) request references, as a set.
function M.referenced_request(req, set)
  set = set or {}
  collect_refs(req.url, set)
  for _, h in ipairs(req.headers or {}) do
    collect_refs(h.key, set); collect_refs(h.value, set)
  end
  if req.auth then
    for _, v in pairs(req.auth.params or {}) do collect_refs(tostring(v), set) end
  end
  local b = req.body
  if b then
    if b.mode == "raw" then
      collect_refs(b.raw, set)
    elseif b.mode == "urlencoded" or b.mode == "formdata" then
      for _, p in ipairs(b.params or {}) do
        collect_refs(p.key, set); collect_refs(p.value, set)
        if p.src then collect_refs(p.src, set) end
      end
    elseif b.mode == "graphql" then
      collect_refs(b.query, set); collect_refs(b.variables, set)
    elseif b.mode == "file" then
      collect_refs(b.src, set)
    end
  end
  return set
end

M._internal = { uuid4 = uuid4, dynamic = dynamic, lookup = lookup, collect_refs = collect_refs }

return M
