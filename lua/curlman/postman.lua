-- curlman.postman — parse Postman Collection v2.1 exports and environment
-- exports into flat, plugin-friendly tables. Depends on `vim.json.decode`
-- (built into Neovim) plus curlman.util. No third-party libraries.

local util = require("curlman.util")

local M = {}

local function json_decode(str)
  local ok, data = pcall(vim.json.decode, str)
  if not ok then return nil, tostring(data) end
  return data
end

--- Convert a Postman url (string OR {raw=..., host=..., path=...}) to a string.
local function url_to_string(url)
  if url == nil then return "" end
  if type(url) == "string" then return url end
  if type(url) == "table" then
    if type(url.raw) == "string" and url.raw ~= "" then
      return url.raw
    end
    -- Reconstruct from parts as a fallback.
    local proto = url.protocol or "https"
    local host = url.host
    if type(host) == "table" then host = table.concat(host, ".") else host = host or "" end
    local path = url.path
    if type(path) == "table" then path = table.concat(path, "/") else path = path or "" end
    local s = proto .. "://" .. host
    if path ~= "" then s = s .. "/" .. path end
    if type(url.query) == "table" and #url.query > 0 then
      local parts = {}
      for _, q in ipairs(url.query) do
        if not q.disabled and q.key then
          parts[#parts + 1] = tostring(q.key) .. "=" .. tostring(q.value or "")
        end
      end
      if #parts > 0 then s = s .. "?" .. table.concat(parts, "&") end
    end
    return s
  end
  return ""
end

--- Postman header array -> list of { key, value }, skipping disabled ones.
local function normalize_headers(header)
  local out = {}
  if type(header) ~= "table" then return out end
  for _, h in ipairs(header) do
    if type(h) == "table" and not h.disabled and h.key and h.key ~= "" then
      out[#out + 1] = { key = tostring(h.key), value = tostring(h.value or "") }
    end
  end
  return out
end

--- Postman auth block -> { type = "bearer", params = { token = "..." } }.
-- Postman stores auth params as an array of {key,value}; flatten to a map.
local function normalize_auth(auth)
  if type(auth) ~= "table" then return nil end
  local t = auth.type
  if not t or t == "noauth" then return nil end
  local params = {}
  local arr = auth[t]
  if type(arr) == "table" then
    for _, kv in ipairs(arr) do
      if type(kv) == "table" and kv.key ~= nil then
        params[tostring(kv.key)] = kv.value
      end
    end
  end
  return { type = t, params = params }
end

--- Postman body block -> normalized { mode = ..., ... }.
local function normalize_body(body)
  if type(body) ~= "table" then return nil end
  local mode = body.mode
  if mode == "raw" then
    local lang = "text"
    if type(body.options) == "table" and type(body.options.raw) == "table" then
      lang = body.options.raw.language or "text"
    end
    return { mode = "raw", raw = body.raw or "", language = lang }
  elseif mode == "urlencoded" then
    local params = {}
    if type(body.urlencoded) == "table" then
      for _, p in ipairs(body.urlencoded) do
        if not p.disabled and p.key then
          params[#params + 1] = { key = tostring(p.key), value = tostring(p.value or "") }
        end
      end
    end
    return { mode = "urlencoded", params = params }
  elseif mode == "formdata" then
    local params = {}
    if type(body.formdata) == "table" then
      for _, p in ipairs(body.formdata) do
        if not p.disabled and p.key then
          params[#params + 1] = {
            key = tostring(p.key),
            value = p.value ~= nil and tostring(p.value) or nil,
            ptype = p.type or "text",
            src = p.src,
          }
        end
      end
    end
    return { mode = "formdata", params = params }
  elseif mode == "graphql" then
    local g = body.graphql or {}
    return { mode = "graphql", query = g.query or "", variables = g.variables }
  elseif mode == "file" then
    local f = body.file or {}
    return { mode = "file", src = f.src }
  end
  return nil
end

--- Build a normalized request from a Postman item.
local function normalize_request(item, folder_path)
  local r = item.request
  if type(r) == "string" then
    -- shorthand: request is just a URL string
    r = { method = "GET", url = r }
  end
  local method = (r.method or "GET"):upper()
  local name = item.name or method .. " request"
  local display = name
  if folder_path and folder_path ~= "" then
    display = folder_path .. " / " .. name
  end
  return {
    name = name,
    display = display,
    method = method,
    url = url_to_string(r.url),
    headers = normalize_headers(r.header),
    auth = normalize_auth(r.auth), -- may be nil; inheritance applied by caller
    body = normalize_body(r.body),
    folder = folder_path,
  }
end

--- Recursively flatten Postman items (folders + requests) into a request list.
-- Auth inheritance: a request with no auth inherits the nearest folder/collection auth.
local function flatten(items, folder_path, inherited_auth, acc)
  if type(items) ~= "table" then return end
  for _, item in ipairs(items) do
    if type(item) == "table" then
      if item.item ~= nil then
        -- a folder
        local sub_path = folder_path
        if item.name then
          sub_path = (folder_path ~= "" and (folder_path .. " / ") or "") .. item.name
        end
        local folder_auth = normalize_auth(item.auth) or inherited_auth
        flatten(item.item, sub_path, folder_auth, acc)
      elseif item.request ~= nil then
        local req = normalize_request(item, folder_path)
        if req.auth == nil then req.auth = inherited_auth end
        acc[#acc + 1] = req
      end
    end
  end
end

--- Collection-level variables -> ordered list + lookup map.
local function collection_vars(data)
  local list, map = {}, {}
  if type(data.variable) == "table" then
    for _, v in ipairs(data.variable) do
      if type(v) == "table" and v.key then
        list[#list + 1] = { key = tostring(v.key), value = tostring(v.value or "") }
        map[tostring(v.key)] = tostring(v.value or "")
      end
    end
  end
  return list, map
end

--- Public: parse a Postman collection export.
-- @return collection table { name, source, requests, vars, vars_map } or nil, err
function M.parse_collection(content, source)
  local data, err = json_decode(content)
  if not data then return nil, "invalid JSON: " .. tostring(err) end
  if type(data) ~= "table" or data.item == nil then
    return nil, "does not look like a Postman collection (no `item` array)"
  end
  local name = "collection"
  if type(data.info) == "table" and data.info.name then name = data.info.name end

  local requests = {}
  local root_auth = normalize_auth(data.auth)
  flatten(data.item, "", root_auth, requests)

  local vars, vars_map = collection_vars(data)
  local collection = {
    name = name,
    source = source,
    requests = requests,
    vars = vars,
    vars_map = vars_map,
  }
  for _, req in ipairs(requests) do
    req.collection = name
    req.source = source
  end
  return collection
end

--- Public: parse a Postman environment export (or a flat {k=v} JSON object).
-- @return env table { name, values = {{key,value}}, map = {k=v} } or nil, err
function M.parse_environment(content)
  local data, err = json_decode(content)
  if not data then return nil, "invalid JSON: " .. tostring(err) end
  local values, map = {}, {}
  if type(data.values) == "table" then
    -- Standard Postman environment export.
    for _, v in ipairs(data.values) do
      if type(v) == "table" and v.key and v.enabled ~= false then
        values[#values + 1] = { key = tostring(v.key), value = tostring(v.value or "") }
        map[tostring(v.key)] = tostring(v.value or "")
      end
    end
    return { name = data.name or "environment", values = values, map = map }
  elseif type(data) == "table" then
    -- Fallback: a plain flat object of key -> scalar.
    for k, v in pairs(data) do
      if type(v) ~= "table" then
        values[#values + 1] = { key = tostring(k), value = tostring(v) }
        map[tostring(k)] = tostring(v)
      end
    end
    return { name = "environment", values = values, map = map }
  end
  return nil, "unrecognized environment format"
end

-- Expose internals for testing.
M._internal = {
  url_to_string = url_to_string,
  normalize_headers = normalize_headers,
  normalize_auth = normalize_auth,
  normalize_body = normalize_body,
}

return M
