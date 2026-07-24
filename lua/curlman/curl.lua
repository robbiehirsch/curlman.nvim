-- curlman.curl — turn a resolved request into a curl argv, run it as an
-- async job, and parse the response (status, headers, body, timing metrics).
-- Also wraps optional `jq` for pretty-printing and filtering. curl is the only
-- hard external dependency; jq is used only when present.

local util = require("curlman.util")

local M = {}

-- curl -w format. Real newlines; each line is key=value. Body goes to -o and
-- headers to -D, so stdout contains ONLY these metrics.
local METRIC_FORMAT = table.concat({
  "http_code=%{http_code}",
  "time_total=%{time_total}",
  "time_namelookup=%{time_namelookup}",
  "time_connect=%{time_connect}",
  "time_appconnect=%{time_appconnect}",
  "time_pretransfer=%{time_pretransfer}",
  "time_starttransfer=%{time_starttransfer}",
  "size_download=%{size_download}",
  "size_header=%{size_header}",
  "speed_download=%{speed_download}",
  "num_redirects=%{num_redirects}",
  "content_type=%{content_type}",
  "url_effective=%{url_effective}",
  "",
}, "\n")

local LANG_CONTENT_TYPE = {
  json = "application/json",
  xml = "application/xml",
  html = "text/html",
  javascript = "application/javascript",
  text = "text/plain",
}

--- Is an executable available? Uses nvim when present, else `command -v`.
function M.has_exe(name)
  if _G.vim and vim.fn and vim.fn.executable then
    return vim.fn.executable(name) == 1
  end
  local ok = os.execute("command -v " .. name .. " >/dev/null 2>&1")
  return ok == true or ok == 0
end

--- content-type string -> nvim filetype for the response buffer.
function M.filetype_for(content_type)
  local ct = (content_type or ""):lower()
  if ct:find("json") then return "json" end
  if ct:find("xml") then return "xml" end
  if ct:find("html") then return "html" end
  if ct:find("javascript") or ct:find("ecmascript") then return "javascript" end
  if ct:find("csv") then return "csv" end
  if ct:find("yaml") then return "yaml" end
  return "text"
end

--- Build the full curl argv for a resolved request.
-- files = { body_out=path, header_out=path }
-- opts  = { connect_timeout, max_time, follow_redirects, insecure, http_version, extra_args }
-- @return argv (list), input_tmpfiles (list to clean up afterwards)
function M.build_argv(req, opts, files)
  opts = opts or {}
  local argv = { "curl", "-sS", "--globoff" }
  local tmp = {}

  local function add(...)
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  end

  add("-o", files.body_out)
  add("-D", files.header_out)
  add("-w", METRIC_FORMAT)

  if opts.connect_timeout then add("--connect-timeout", tostring(opts.connect_timeout)) end
  if opts.max_time then add("--max-time", tostring(opts.max_time)) end
  if opts.follow_redirects then add("-L") end
  if opts.insecure then add("-k") end
  if opts.http_version == "1.0" then add("--http1.0")
  elseif opts.http_version == "1.1" then add("--http1.1")
  elseif opts.http_version == "2" then add("--http2") end

  local method = (req.method or "GET"):upper()
  local is_head = method == "HEAD"
  if is_head then
    add("-I")
  else
    add("-X", method)
  end

  -- Track whether the request already sets a Content-Type header.
  local have_ct = false
  for _, h in ipairs(req.headers or {}) do
    if h.key and h.key ~= "" then
      add("-H", h.key .. ": " .. (h.value or ""))
      if h.key:lower() == "content-type" then have_ct = true end
    end
  end

  -- Auth -> curl flags / headers.
  local url = req.url or ""
  if req.auth then
    local a = req.auth
    local p = a.params or {}
    if a.type == "bearer" then
      add("-H", "Authorization: Bearer " .. (p.token or ""))
    elseif a.type == "basic" then
      add("-u", (p.username or "") .. ":" .. (p.password or ""))
    elseif a.type == "apikey" then
      local where = (p["in"] or "header")
      local k = p.key or ""
      local v = p.value or ""
      if where == "query" then
        local sep = url:find("?", 1, true) and "&" or "?"
        url = url .. sep .. k .. "=" .. v
      else
        add("-H", k .. ": " .. v)
      end
    elseif a.type == "oauth2" then
      local tok = p.accessToken or p.access_token or p.token
      if tok and tok ~= "" then
        add("-H", "Authorization: Bearer " .. tok)
      else
        util.warn("auth type 'oauth2' has no token — set Authorization manually")
      end
    else
      util.warn("unsupported auth type '" .. tostring(a.type) .. "' — skipped")
    end
  end

  -- Body.
  if req.body and not is_head then
    local b = req.body
    if b.mode == "raw" then
      local path = util.tempname()
      util.write_file(path, b.raw or "")
      tmp[#tmp + 1] = path
      add("--data-binary", "@" .. path)
      if not have_ct and b.language and LANG_CONTENT_TYPE[b.language] then
        add("-H", "Content-Type: " .. LANG_CONTENT_TYPE[b.language])
      end
    elseif b.mode == "urlencoded" then
      for _, p in ipairs(b.params or {}) do
        add("--data-urlencode", (p.key or "") .. "=" .. (p.value or ""))
      end
    elseif b.mode == "formdata" then
      for _, p in ipairs(b.params or {}) do
        if p.ptype == "file" and p.src then
          add("-F", (p.key or "") .. "=@" .. p.src)
        else
          add("-F", (p.key or "") .. "=" .. (p.value or ""))
        end
      end
    elseif b.mode == "graphql" then
      local payload = vim.json.encode({ query = b.query or "", variables = b.variables or vim.empty_dict() })
      local path = util.tempname()
      util.write_file(path, payload)
      tmp[#tmp + 1] = path
      add("--data-binary", "@" .. path)
      if not have_ct then add("-H", "Content-Type: application/json") end
    elseif b.mode == "file" and b.src then
      add("--data-binary", "@" .. b.src)
    end
  end

  for _, extra in ipairs(opts.extra_args or {}) do add(extra) end

  -- URL always last.
  argv[#argv + 1] = url
  return argv, tmp
end

--- Parse the key=value metric block from curl's stdout.
local function parse_metrics(stdout)
  local m = {}
  for _, line in ipairs(util.lines(stdout or "")) do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then
      local num = tonumber(v)
      m[k] = num ~= nil and num or v
    end
  end
  return m
end

--- Parse the response header dump (may contain several blocks after redirects;
--- we keep the last block, i.e. the final response).
local function parse_headers(raw)
  raw = raw or ""
  -- split into blocks separated by a blank line
  local blocks = {}
  local current = {}
  for _, line in ipairs(util.lines(raw)) do
    if util.trim(line) == "" then
      if #current > 0 then blocks[#blocks + 1] = current; current = {} end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then blocks[#blocks + 1] = current end

  local last = blocks[#blocks] or {}
  local status_line = last[1] or ""
  local proto, code, reason = status_line:match("^(HTTP/[%d%.]+)%s+(%d+)%s*(.*)$")
  local list, map = {}, {}
  for i = 2, #last do
    local k, v = last[i]:match("^([^:]+):%s?(.*)$")
    if k then
      list[#list + 1] = { key = k, value = v }
      map[k:lower()] = v
    end
  end
  return {
    proto = proto,
    code = tonumber(code),
    reason = util.trim(reason or ""),
    status_line = status_line,
    list = list,
    map = map,
    block_count = #blocks,
  }
end

--- Run an argv asynchronously, collecting stdout/stderr, then call cb(code, stdout, stderr).
local function run_job(argv, cb)
  if _G.vim and vim.system then
    vim.system(argv, { text = true }, function(res)
      vim.schedule(function() cb(res.code, res.stdout or "", res.stderr or "") end)
    end)
    return
  end
  -- Fallback for Neovim < 0.10.
  local out, errbuf = {}, {}
  local jid = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) if data then out = data end end,
    on_stderr = function(_, data) if data then errbuf = data end end,
    on_exit = function(_, code)
      vim.schedule(function()
        cb(code, table.concat(out, "\n"), table.concat(errbuf, "\n"))
      end)
    end,
  })
  if jid <= 0 then
    vim.schedule(function() cb(-1, "", "failed to start curl (is it installed and on PATH?)") end)
  end
end

--- Execute a resolved request. Calls on_done(result).
-- result = { ok, exit_code, stderr, status, reason, metrics, headers, body, content_type, filetype }
function M.execute(req, opts, on_done)
  local files = { body_out = util.tempname(), header_out = util.tempname() }
  local argv, input_tmp = M.build_argv(req, opts, files)

  run_job(argv, function(code, stdout, stderr)
    local body = util.read_file(files.body_out) or ""
    local raw_headers = util.read_file(files.header_out) or ""
    local metrics = parse_metrics(stdout)
    local headers = parse_headers(raw_headers)

    -- cleanup temp files
    for _, p in ipairs({ files.body_out, files.header_out }) do os.remove(util.expand(p)) end
    for _, p in ipairs(input_tmp) do os.remove(util.expand(p)) end

    local content_type = metrics.content_type
    if not content_type or content_type == "" then content_type = headers.map["content-type"] end

    on_done({
      ok = code == 0,
      exit_code = code,
      stderr = util.trim(stderr or ""),
      status = metrics.http_code or headers.code,
      reason = headers.reason,
      metrics = metrics,
      headers = headers,
      raw_headers = raw_headers,
      body = body,
      content_type = content_type,
      filetype = M.filetype_for(content_type),
      argv = argv,
      request = req,
    })
  end)
end

--- Optional jq: pretty-print a JSON string. Falls back to the Lua formatter.
-- Synchronous, but only used for reasonably sized bodies.
function M.pretty_json(body, use_jq)
  if use_jq and M.has_exe("jq") and #body < 4 * 1024 * 1024 then
    local out
    if _G.vim and vim.system then
      local res = vim.system({ "jq", "." }, { stdin = body, text = true }):wait()
      if res.code == 0 and res.stdout and res.stdout ~= "" then out = res.stdout end
    elseif _G.vim and vim.fn then
      out = vim.fn.system({ "jq", "." }, body)
      if vim.v.shell_error ~= 0 then out = nil end
    end
    if out then return (out:gsub("%s+$", "")) end
  end
  return util.pretty_json(body)
end

--- Optional jq: run an arbitrary filter over a body, async. cb(ok, output).
function M.jq_filter(body, filter, cb)
  if not M.has_exe("jq") then
    cb(false, "jq is not installed")
    return
  end
  local argv = { "jq", filter }
  if _G.vim and vim.system then
    vim.system(argv, { stdin = body, text = true }, function(res)
      vim.schedule(function()
        if res.code == 0 then cb(true, res.stdout or "") else cb(false, res.stderr or "jq error") end
      end)
    end)
  else
    local out = vim.fn.system(argv, body)
    if vim.v.shell_error == 0 then cb(true, out) else cb(false, out) end
  end
end

--- Shell single-quote-escape.
local function shq(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

--- Build a clean, reproducible, shareable curl command (list of args) from a
--- RESOLVED request. Unlike build_argv this inlines the body and omits curlman's
--- internal -o/-D/-w plumbing, so it's something you'd actually paste in a shell.
function M.to_command(req)
  local a = { "curl", "-sS" }
  local method = (req.method or "GET"):upper()
  if method == "HEAD" then a[#a + 1] = "-I"
  elseif method ~= "GET" then a[#a + 1] = "-X " .. method end

  local url = req.url or ""
  local have_ct = false
  for _, h in ipairs(req.headers or {}) do
    if h.key and h.key ~= "" then
      a[#a + 1] = "-H " .. shq(h.key .. ": " .. (h.value or ""))
      if h.key:lower() == "content-type" then have_ct = true end
    end
  end

  if req.auth then
    local p = req.auth.params or {}
    if req.auth.type == "bearer" then
      a[#a + 1] = "-H " .. shq("Authorization: Bearer " .. (p.token or ""))
    elseif req.auth.type == "basic" then
      a[#a + 1] = "-u " .. shq((p.username or "") .. ":" .. (p.password or ""))
    elseif req.auth.type == "apikey" then
      if (p["in"] or "header") == "query" then
        local sep = url:find("?", 1, true) and "&" or "?"
        url = url .. sep .. (p.key or "") .. "=" .. (p.value or "")
      else
        a[#a + 1] = "-H " .. shq((p.key or "") .. ": " .. (p.value or ""))
      end
    end
  end

  local b = req.body
  if b and method ~= "HEAD" then
    if b.mode == "raw" then
      a[#a + 1] = "--data " .. shq(b.raw or "")
      if not have_ct and b.language and LANG_CONTENT_TYPE[b.language] then
        a[#a + 1] = "-H " .. shq("Content-Type: " .. LANG_CONTENT_TYPE[b.language])
      end
    elseif b.mode == "urlencoded" then
      for _, p in ipairs(b.params or {}) do a[#a + 1] = "--data-urlencode " .. shq((p.key or "") .. "=" .. (p.value or "")) end
    elseif b.mode == "formdata" then
      for _, p in ipairs(b.params or {}) do
        if p.ptype == "file" and p.src then a[#a + 1] = "-F " .. shq((p.key or "") .. "=@" .. p.src)
        else a[#a + 1] = "-F " .. shq((p.key or "") .. "=" .. (p.value or "")) end
      end
    elseif b.mode == "graphql" then
      local payload = vim.json.encode({ query = b.query or "", variables = b.variables or vim.empty_dict() })
      a[#a + 1] = "--data " .. shq(payload)
      if not have_ct then a[#a + 1] = "-H " .. shq("Content-Type: application/json") end
    elseif b.mode == "file" and b.src then
      a[#a + 1] = "--data-binary " .. shq("@" .. b.src)
    end
  end

  a[#a + 1] = shq(url)
  return a
end

--- The curl command as a readable multi-line string (backslash continuations).
function M.to_command_string(req)
  return table.concat(M.to_command(req), " \\\n  ")
end

M._internal = {
  parse_metrics = parse_metrics,
  parse_headers = parse_headers,
  METRIC_FORMAT = METRIC_FORMAT,
  shq = shq,
}

return M
