-- curlman.profiles — named variable sets ("configs"): dev/staging/prod-style
-- profiles you can save, rename, duplicate, edit, favourite, and fan a single
-- request out across (see :CurlmanRunWith). Each profile is stored as ONE
-- Postman-environment JSON file, so profiles are portable to/from Postman and
-- loadable with :CurlmanLoadEnv like any other environment. Unsaved in-memory
-- overrides become durable by snapshotting them into a profile
-- (:CurlmanProfileSave). Storage is GLOBAL (stdpath data), not per-project —
-- your prod credentials shouldn't need re-creating for every repo.

local util = require("curlman.util")
local postman = require("curlman.postman")

local M = {}

M.dir = nil            -- profile store; set by setup()
M.favorites_file = nil -- set by setup()
M.profiles = {}        -- name -> { name, values = {k=v}, path }
M.favorites = { profiles = {}, endpoints = {} } -- sets (name / endpoint key)

local SEP = "\t"

local function ensure_dir(dir)
  if _G.vim and vim.fn and vim.fn.mkdir then
    pcall(vim.fn.mkdir, util.expand(dir), "p")
  end
end

---------------------------------------------------------------- persistence

--- Serialize a values map as a Postman environment JSON string (stable key
--- order, so files diff cleanly in git).
function M.encode(name, values)
  local keys = {}
  for k in pairs(values or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local vals = {}
  for _, k in ipairs(keys) do
    vals[#vals + 1] = { key = k, value = tostring(values[k]), enabled = true }
  end
  return vim.json.encode({
    name = name,
    _postman_variable_scope = "environment",
    values = vals,
  })
end

--- Save (create or overwrite) a profile. `path` is optional: default is the
--- global store; pass an explicit path to save a copy anywhere ("save a
--- config to a location") — explicit-path saves do NOT move the canonical
--- store file.
-- @return path or nil, err
function M.save(name, values, path)
  if not name or name == "" then return nil, "profile needs a name" end
  local canonical = path == nil
  path = path and util.expand(path) or (util.expand(M.dir) .. "/" .. util.slug(name) .. ".json")
  local parent = path:match("^(.*)/[^/]*$")
  if parent then ensure_dir(parent) end
  local ok, werr = util.write_file(path, M.encode(name, values))
  if not ok then return nil, werr end
  if canonical or M.profiles[name] == nil then
    M.profiles[name] = { name = name, values = vim.deepcopy(values or {}), path = canonical and path or M.profiles[name] and M.profiles[name].path or path }
  else
    M.profiles[name].values = vim.deepcopy(values or {})
  end
  return path
end

--- (Re)load every profile from the store directory.
function M.load_all()
  M.profiles = {}
  local dir = util.expand(M.dir or "")
  if dir == "" then return end
  ensure_dir(dir)
  local files = vim.fn.glob(dir .. "/*.json", true, true)
  for _, f in ipairs(files) do
    local content = util.read_file(f)
    if content then
      local env = postman.parse_environment(content)
      if env and env.name then
        M.profiles[env.name] = { name = env.name, values = env.map or {}, path = f }
      end
    end
  end
end

function M.get(name) return M.profiles[name] end

--- Sorted profile names.
function M.names()
  local out = {}
  for n in pairs(M.profiles) do out[#out + 1] = n end
  table.sort(out)
  return out
end

--- Sorted names, favourites floated to the top (used by every picker).
function M.names_fav_first()
  local favs, rest = {}, {}
  for _, n in ipairs(M.names()) do
    if M.favorites.profiles[n] then favs[#favs + 1] = n else rest[#rest + 1] = n end
  end
  for _, n in ipairs(rest) do favs[#favs + 1] = n end
  return favs
end

function M.delete(name)
  local p = M.profiles[name]
  if not p then return false end
  if p.path then pcall(os.remove, util.expand(p.path)) end
  M.profiles[name] = nil
  if M.favorites.profiles[name] then
    M.favorites.profiles[name] = nil
    M.save_favorites()
  end
  return true
end

function M.rename(old, new)
  local p = M.profiles[old]
  if not p then return nil, "no profile '" .. tostring(old) .. "'" end
  if new == nil or new == "" or M.profiles[new] then return nil, "bad or taken name" end
  local values = p.values
  local was_fav = M.favorites.profiles[old]
  M.delete(old)
  local path, err = M.save(new, values)
  if not path then return nil, err end
  if was_fav then
    M.favorites.profiles[new] = true
    M.save_favorites()
  end
  return path
end

function M.duplicate(name, newname)
  local p = M.profiles[name]
  if not p then return nil, "no profile '" .. tostring(name) .. "'" end
  if not newname or newname == "" or M.profiles[newname] then return nil, "bad or taken name" end
  return M.save(newname, p.values)
end

----------------------------------------------------------------- favourites

function M.endpoint_key(config, method, display)
  return table.concat({ config or "?", method or "?", display or "?" }, SEP)
end

local function endpoint_key_of(r)
  return M.endpoint_key(r.collection, r.method, r.display or r.name)
end

function M.load_favorites()
  M.favorites = { profiles = {}, endpoints = {} }
  local content = M.favorites_file and util.read_file(util.expand(M.favorites_file))
  if not content then return end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return end
  for _, n in ipairs(data.profiles or {}) do M.favorites.profiles[n] = true end
  for _, k in ipairs(data.endpoints or {}) do M.favorites.endpoints[k] = true end
end

function M.save_favorites()
  if not M.favorites_file then return end
  local path = util.expand(M.favorites_file)
  local parent = path:match("^(.*)/[^/]*$")
  if parent then ensure_dir(parent) end
  local profs, eps = {}, {}
  for n in pairs(M.favorites.profiles) do profs[#profs + 1] = n end
  for k in pairs(M.favorites.endpoints) do eps[#eps + 1] = k end
  table.sort(profs)
  table.sort(eps)
  util.write_file(path, vim.json.encode({ profiles = profs, endpoints = eps }))
end

function M.is_fav_profile(name) return M.favorites.profiles[name] == true end

function M.toggle_fav_profile(name)
  M.favorites.profiles[name] = not M.favorites.profiles[name] or nil
  M.save_favorites()
  return M.favorites.profiles[name] == true
end

function M.is_fav_endpoint(r) return M.favorites.endpoints[endpoint_key_of(r)] == true end

function M.toggle_fav_endpoint(r)
  local k = endpoint_key_of(r)
  M.favorites.endpoints[k] = not M.favorites.endpoints[k] or nil
  M.save_favorites()
  return M.favorites.endpoints[k] == true
end

--------------------------------------------------------------------- setup

function M.setup(cfg)
  cfg = cfg or {}
  M.dir = cfg.dir
  M.favorites_file = cfg.favorites_file
  M.load_all()
  M.load_favorites()
end

return M
