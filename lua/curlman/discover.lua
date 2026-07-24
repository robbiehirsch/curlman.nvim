-- curlman.discover — find Postman JSON files in the current project so the
-- load menu can offer them directly, with previously-loaded files floated to the
-- top. Recent loads are remembered across sessions in a small state file.

local util = require("curlman.util")

local M = {}

M.recent = {}      -- absolute paths, most-recent-first (loaded this + past sessions)
M.state_file = nil -- set by setup()

--- The project root: git toplevel if we're in a repo, else the cwd.
function M.project_root()
  if _G.vim and vim.fn then
    local ok, out = pcall(vim.fn.systemlist, { "git", "rev-parse", "--show-toplevel" })
    if ok and type(out) == "table" and out[1] and out[1] ~= "" and not out[1]:match("fatal") then
      if vim.v.shell_error == 0 then return out[1] end
    end
    return vim.fn.getcwd()
  end
  return "."
end

--- Cheap classifier from a file's head: "collection" | "environment" | nil.
function M.classify(path)
  local fh = io.open(util.expand(path), "rb")
  if not fh then return nil end
  local head = fh:read(8192) or ""
  fh:close()
  if head:find("getpostman", 1, true) and head:find('"item"', 1, true) then return "collection" end
  if head:find('"item"', 1, true) and head:find('"info"', 1, true) then return "collection" end
  if head:find("_postman_variable_scope", 1, true) then return "environment" end
  if head:find('"values"', 1, true) and head:find('"name"', 1, true)
    and not head:find('"item"', 1, true) then return "environment" end
  return nil
end

--- Find candidate json files under `root` (bounded), classified.
-- @return { {path=, kind="collection"|"environment"} ... }
function M.find(root, max_files)
  root = util.expand(root or M.project_root())
  max_files = max_files or 400
  local jsons = {}
  if _G.vim and vim.fs and vim.fs.find then
    jsons = vim.fs.find(function(name) return name:match("%.json$") ~= nil end,
      { path = root, type = "file", limit = max_files })
  elseif _G.vim and vim.fn then
    local raw = vim.fn.glob(root .. "/**/*.json", true, true)
    for _, f in ipairs(raw) do
      if #jsons >= max_files then break end
      jsons[#jsons + 1] = f
    end
  end
  local out = {}
  for _, path in ipairs(jsons) do
    -- skip common noise dirs
    if not path:match("/node_modules/") and not path:match("/%.git/") then
      local kind = M.classify(path)
      if kind then out[#out + 1] = { path = path, kind = kind } end
    end
  end
  return out
end

--- Order candidates: previously-loaded (in recent order) first, then the rest
--- alphabetically. `loaded` is a set of currently-loaded paths (also floated up,
--- after recents). Pure — unit tested.
function M.order_candidates(candidates, recent, loaded)
  recent = recent or {}
  loaded = loaded or {}
  local recent_rank = {}
  for i, p in ipairs(recent) do if recent_rank[p] == nil then recent_rank[p] = i end end

  local function score(path)
    if recent_rank[path] then return 0, recent_rank[path] end
    if loaded[path] then return 1, 0 end
    return 2, 0
  end

  local sorted = {}
  for _, c in ipairs(candidates) do sorted[#sorted + 1] = c end
  table.sort(sorted, function(a, b)
    local ta, ra = score(a.path)
    local tb, rb = score(b.path)
    if ta ~= tb then return ta < tb end
    if ta == 0 and ra ~= rb then return ra < rb end
    return a.path < b.path
  end)
  return sorted
end

--- Record a path as freshly loaded (moves it to the front of recents; persists).
function M.mark_loaded(path)
  path = util.expand(path)
  local next_recent = { path }
  for _, p in ipairs(M.recent) do
    if p ~= path then next_recent[#next_recent + 1] = p end
  end
  while #next_recent > 50 do next_recent[#next_recent] = nil end
  M.recent = next_recent
  M.persist()
end

function M.load_recent()
  if not M.state_file then return end
  local content = util.read_file(M.state_file)
  if not content then return end
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" and type(data.recent) == "table" then
    M.recent = data.recent
  end
end

function M.persist()
  if not M.state_file then return end
  local parent = util.expand(M.state_file):match("^(.*)/[^/]*$")
  if parent and _G.vim and vim.fn and vim.fn.mkdir then pcall(vim.fn.mkdir, parent, "p") end
  local ok, encoded = pcall(vim.json.encode, { recent = M.recent })
  if ok then util.write_file(M.state_file, encoded) end
end

return M
