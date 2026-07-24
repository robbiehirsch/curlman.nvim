-- curlman.util — small, dependency-free helpers.
-- Pure Lua (LuaJIT / Lua 5.1 compatible). Only touches `vim` for notify/tempname,
-- which are guarded so the pure-logic bits stay unit-testable outside nvim.

local M = {}

local has_vim = type(_G.vim) == "table"

--- Notifications -----------------------------------------------------------

function M.notify(msg, level)
  if has_vim and vim.notify then
    level = level or (vim.log and vim.log.levels.INFO) or nil
    vim.notify("[curlman] " .. msg, level)
  else
    io.stderr:write("[curlman] " .. msg .. "\n")
  end
end

function M.info(msg) M.notify(msg, has_vim and vim.log.levels.INFO or nil) end
function M.warn(msg) M.notify(msg, has_vim and vim.log.levels.WARN or nil) end
function M.err(msg) M.notify(msg, has_vim and vim.log.levels.ERROR or nil) end

--- String helpers ----------------------------------------------------------

function M.trim(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split `s` on a literal separator. Simple, predictable, no vim dependency.
function M.split(s, sep)
  local out = {}
  if s == nil then return out end
  sep = sep or "\n"
  local from = 1
  local start, stop = s:find(sep, from, true)
  while start do
    out[#out + 1] = s:sub(from, start - 1)
    from = stop + 1
    start, stop = s:find(sep, from, true)
  end
  out[#out + 1] = s:sub(from)
  return out
end

--- Split into lines, tolerating \r\n and a trailing newline.
function M.lines(s)
  s = (s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local out = M.split(s, "\n")
  -- drop a single trailing empty line produced by a terminal newline
  if #out > 1 and out[#out] == "" then out[#out] = nil end
  return out
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- Expand a leading ~ and $ENV in a path.
function M.expand(path)
  if type(path) ~= "string" then return path end
  if has_vim and vim.fn and vim.fn.expand then
    -- let nvim handle ~, $VAR, etc.
    return vim.fn.expand(path)
  end
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or ""
    path = home .. path:sub(2)
  end
  return path
end

--- File IO -----------------------------------------------------------------

function M.read_file(path)
  local fh, oerr = io.open(M.expand(path), "rb")
  if not fh then return nil, oerr end
  local content = fh:read("*a")
  fh:close()
  return content
end

function M.write_file(path, content)
  local fh, oerr = io.open(M.expand(path), "wb")
  if not fh then return false, oerr end
  fh:write(content or "")
  fh:close()
  return true
end

--- A temp file path. Prefers nvim's tempname (cleaned up on exit) if present.
function M.tempname()
  if has_vim and vim.fn and vim.fn.tempname then
    return vim.fn.tempname()
  end
  return os.tmpname()
end

--- Formatting --------------------------------------------------------------

--- Bytes -> human readable ("1.2 KB").
function M.human_size(bytes)
  bytes = tonumber(bytes) or 0
  local units = { "B", "KB", "MB", "GB" }
  local i = 1
  while bytes >= 1024 and i < #units do
    bytes = bytes / 1024
    i = i + 1
  end
  if i == 1 then
    return string.format("%d %s", math.floor(bytes + 0.5), units[i])
  end
  return string.format("%.1f %s", bytes, units[i])
end

--- Seconds (float) -> human readable ("142 ms" / "1.24 s").
function M.human_time(sec)
  sec = tonumber(sec) or 0
  if sec < 1 then
    return string.format("%d ms", math.floor(sec * 1000 + 0.5))
  end
  return string.format("%.2f s", sec)
end

--- Turn an arbitrary string into a filesystem-safe slug.
function M.slug(s)
  s = tostring(s or "response")
  s = s:gsub("[^%w%-_%. ]", ""):gsub("%s+", "-")
  if s == "" then s = "response" end
  return s:sub(1, 60)
end

--- JSON pretty-printer -----------------------------------------------------
-- Reformats a JSON string WITHOUT decoding it, so key order and values are
-- preserved byte-for-byte (only whitespace changes). That matters a lot for
-- diffing two responses. Returns the input unchanged if it isn't valid JSON.

local function json_tokens(str)
  local toks = {}
  local i, n = 1, #str
  while i <= n do
    local c = str:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    elseif c == "{" or c == "}" or c == "[" or c == "]" or c == ":" or c == "," then
      toks[#toks + 1] = { t = c }
      i = i + 1
    elseif c == '"' then
      -- read a string literal, honouring escapes
      local j = i + 1
      while j <= n do
        local cj = str:sub(j, j)
        if cj == "\\" then
          j = j + 2
        elseif cj == '"' then
          break
        else
          j = j + 1
        end
      end
      if j > n then return nil end -- unterminated string
      toks[#toks + 1] = { t = "str", v = str:sub(i, j) }
      i = j + 1
    else
      -- a bare literal: number / true / false / null
      local j = i
      while j <= n do
        local cj = str:sub(j, j)
        if cj:match("[%w%.%+%-eE]") then
          j = j + 1
        else
          break
        end
      end
      if j == i then return nil end -- unexpected char
      toks[#toks + 1] = { t = "lit", v = str:sub(i, j - 1) }
      i = j
    end
  end
  return toks
end

function M.pretty_json(str, indent)
  if type(str) ~= "string" then return str end
  local toks = json_tokens(str)
  if not toks or #toks == 0 then return str end
  -- Only reformat if this is actually a JSON object/array; otherwise leave the
  -- input untouched (e.g. plain text, a bare number, or an unquoted scalar).
  if toks[1].t ~= "{" and toks[1].t ~= "[" then return str end
  indent = indent or "  "
  local out = {}
  local depth = 0
  local function pad(d) return indent:rep(d) end
  for idx, tok in ipairs(toks) do
    local t = tok.t
    local nxt = toks[idx + 1]
    if t == "{" or t == "[" then
      if nxt and ((t == "{" and nxt.t == "}") or (t == "[" and nxt.t == "]")) then
        out[#out + 1] = t -- keep {} / [] compact; closer handled next iteration
      else
        out[#out + 1] = t .. "\n" .. pad(depth + 1)
        depth = depth + 1
      end
    elseif t == "}" or t == "]" then
      local prev = toks[idx - 1]
      if prev and ((t == "}" and prev.t == "{") or (t == "]" and prev.t == "[")) then
        out[#out + 1] = t -- close of an empty container
      else
        depth = depth - 1
        out[#out + 1] = "\n" .. pad(depth) .. t
      end
    elseif t == "," then
      out[#out + 1] = ",\n" .. pad(depth)
    elseif t == ":" then
      out[#out + 1] = ": "
    elseif t == "str" or t == "lit" then
      out[#out + 1] = tok.v
    end
  end
  return table.concat(out)
end

--- Does this string look like JSON we should pretty print?
function M.looks_json(str)
  if type(str) ~= "string" then return false end
  local s = M.trim(str)
  local first = s:sub(1, 1)
  return first == "{" or first == "["
end

return M
