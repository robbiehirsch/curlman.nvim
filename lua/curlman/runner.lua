-- curlman.runner — run a WHOLE collection through the real Postman tooling
-- (the official `postman` CLI or open-source `newman`) instead of curl, then
-- map each execution in the JSON reporter output back onto curlman's normal
-- result shape.
--
-- Why this exists: curl sends one request and knows nothing about Postman's
-- JS sandbox. The CLIs run the collection end to end, so pre-request/test
-- scripts execute, `pm.environment.set` chains values from one request into
-- the next, and `pm.test` assertions actually run. What you give up is
-- per-request granularity — hence this is a collection-level operation.
--
-- The contract: `parse_report` returns entries whose `result` field is
-- structurally identical to what `curl.execute` produces. That is the whole
-- trick — history, the workspace cards, saving and diffing are all written
-- against that shape, so they work on CLI runs with no changes. It also means
-- a CLI response and a curl response for the same request land in the SAME
-- history bucket and can be diffed against each other.
--
-- Neither CLI is a dependency. When neither is installed this module reports
-- so and curlman carries on as a curl-only client.

local util = require("curlman.util")
local curl = require("curlman.curl")
local postman = require("curlman.postman")

local M = {}

-- Reporter output is newman-flavoured for both CLIs (the Postman CLI is built
-- on the same collection runner), but the sub-commands and flag spellings
-- differ. Everything CLI-specific lives in this table.
local CLIS = {
  postman = {
    exe = "postman",
    label = "Postman CLI",
    install = "brew install postman/tap/postman-cli  (or see postman.com/downloads/postman-cli)",
    argv = function(col, env, out)
      local a = { "postman", "collection", "run", col }
      if env then a[#a + 1] = "-e"; a[#a + 1] = env end
      a[#a + 1] = "--reporters"; a[#a + 1] = "json"
      a[#a + 1] = "--reporter-json-export"; a[#a + 1] = out
      return a
    end,
  },
  newman = {
    exe = "newman",
    label = "newman",
    install = "npm install -g newman",
    argv = function(col, env, out)
      local a = { "newman", "run", col }
      if env then a[#a + 1] = "-e"; a[#a + 1] = env end
      a[#a + 1] = "-r"; a[#a + 1] = "json"
      a[#a + 1] = "--reporter-json-export"; a[#a + 1] = out
      -- Without this newman exits 1 when an assertion fails, which we would
      -- otherwise be unable to tell apart from "the CLI itself broke".
      a[#a + 1] = "--suppress-exit-code"
      return a
    end,
  },
}

-- Preference order when mode = "auto": the official CLI first, then newman.
local AUTO_ORDER = { "postman", "newman" }

--- Which CLI should we use? `mode` is "auto" | "postman" | "newman".
-- @return kind ("postman"|"newman") or nil, err
function M.detect(mode)
  mode = mode or "auto"
  if mode ~= "auto" then
    local spec = CLIS[mode]
    if not spec then return nil, "unknown runner '" .. tostring(mode) .. "' (want postman|newman|auto)" end
    if not curl.has_exe(spec.exe) then
      return nil, spec.label .. " is not on $PATH — install it with: " .. spec.install
    end
    return mode
  end
  for _, kind in ipairs(AUTO_ORDER) do
    if curl.has_exe(CLIS[kind].exe) then return kind end
  end
  return nil, "no Postman runner found — install one:\n  "
    .. CLIS.postman.install .. "\n  " .. CLIS.newman.install
end

function M.spec(kind) return CLIS[kind] end

--- Full argv for a collection run. `opts` = { folder, bail, iteration_data,
--- iteration_count, insecure, timeout_request, extra_args }.
function M.build_argv(kind, collection_path, env_path, out_path, opts)
  opts = opts or {}
  local argv = CLIS[kind].argv(util.expand(collection_path), env_path and util.expand(env_path), util.expand(out_path))
  local function add(...)
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  end
  -- These flags are spelled the same for both CLIs.
  if opts.folder and opts.folder ~= "" then add("--folder", opts.folder) end
  if opts.bail then add("--bail") end
  if opts.insecure then add("--insecure") end
  if opts.iteration_data then add("-d", util.expand(opts.iteration_data)) end
  if opts.iteration_count then add("-n", tostring(opts.iteration_count)) end
  if opts.timeout_request then add("--timeout-request", tostring(opts.timeout_request)) end
  for _, extra in ipairs(opts.extra_args or {}) do add(extra) end
  return argv
end

------------------------------------------------------------------- report parsing

--- Reporter bodies arrive as a Node Buffer serialized to JSON: a plain array
--- of byte values. Rebuild the string in batches — `string.char(unpack(t))`
--- overflows on any response of real size.
local function bytes_to_string(data)
  if type(data) ~= "table" then return "" end
  local chunks, buf = {}, {}
  for i = 1, #data do
    local b = tonumber(data[i])
    buf[#buf + 1] = string.char(b and (b % 256) or 0)
    if #buf >= 4096 then
      chunks[#chunks + 1] = table.concat(buf)
      buf = {}
    end
  end
  if #buf > 0 then chunks[#chunks + 1] = table.concat(buf) end
  return table.concat(chunks)
end

--- The body of one execution, whichever way the reporter encoded it.
local function body_of(response)
  local stream = response.stream
  if type(stream) == "table" then
    if type(stream.data) == "table" then return bytes_to_string(stream.data) end
    if type(stream) == "string" then return stream end
  end
  if type(response.body) == "string" then return response.body end
  if type(stream) == "string" then return stream end
  return ""
end

--- Reporter header list -> curlman's { list, map } plus a reconstructed raw
--- block, so the header views that expect curl's `-D` dump still work.
local function headers_of(response)
  local list, map, raw = {}, {}, {}
  local proto = "HTTP/1.1"
  local code = tonumber(response.code)
  local reason = response.status or ""
  local status_line = proto .. " " .. tostring(code or "") .. (reason ~= "" and (" " .. reason) or "")
  raw[#raw + 1] = status_line

  local src = response.header
  if type(src) == "table" then
    for _, h in ipairs(src) do
      if type(h) == "table" and h.key then
        local k, v = tostring(h.key), tostring(h.value or "")
        list[#list + 1] = { key = k, value = v }
        map[k:lower()] = v
        raw[#raw + 1] = k .. ": " .. v
      end
    end
  end

  return {
    proto = proto,
    code = code,
    reason = reason,
    status_line = status_line,
    list = list,
    map = map,
    block_count = 1,
  }, table.concat(raw, "\n") .. "\n"
end

--- Normalize the assertions the JS sandbox produced for one execution.
-- @return list of { name, passed, skipped, message }, passed_count, failed_count
local function assertions_of(execution)
  local out, passed, failed = {}, 0, 0
  for _, a in ipairs(execution.assertions or {}) do
    if type(a) == "table" then
      local skipped = a.skipped == true
      local errm = type(a.error) == "table" and (a.error.message or a.error.name) or nil
      local ok = not skipped and errm == nil
      if skipped then
        -- skipped assertions count as neither
      elseif ok then passed = passed + 1
      else failed = failed + 1 end
      out[#out + 1] = {
        name = tostring(a.assertion or "assertion"),
        passed = ok,
        skipped = skipped,
        message = errm,
      }
    end
  end
  return out, passed, failed
end

--- A transport-level failure (DNS, refused, timeout) for one execution.
--- Verified against real newman output: `execution.requestError` is a raw Node
--- errno object ({errno, code, syscall, hostname}) with NO `message` field, so
--- the readable text has to come from run.failures, correlated by cursor ref.
--- Those failures also carry assertion failures, distinguished by `at`.
local function transport_error(execution, failures_by_ref)
  local e = execution.requestError
  local has_err = e ~= nil and e ~= vim.NIL
  local ref = type(execution.cursor) == "table" and execution.cursor.ref or nil
  local fail = (ref and failures_by_ref) and failures_by_ref[ref] or nil
  -- `at` is "request" for transport errors, "assertion:N in test-script" otherwise.
  if fail and fail.at ~= "request" then fail = nil end
  if not has_err and not fail then return nil end
  if fail and fail.message then return tostring(fail.message) end
  if type(e) == "string" then return e end
  if type(e) == "table" then
    if e.message then return tostring(e.message) end
    local code = e.code or e.errno
    if code then
      local host = e.hostname or e.address
      return tostring(code) .. (host and (" " .. tostring(host)) or "")
    end
  end
  return "request failed"
end

--- Decide whether one CLI execution counts as a SUCCESS (`result.ok`).
--
-- This is the only policy call in the module; everything else is mechanical
-- mapping. `result.ok` is load-bearing downstream:
--   * ui.format_lines (ui.lua:145) shows the BODY when ok, and an error dump
--     with stderr when not;
--   * the workspace card / winbar renders failures differently;
--   * init.dispatch only autosaves when ok, and fires util.err when not.
--
-- Inputs available on `result`:
--   result.transport_error  string|nil  -- DNS/refused/timeout; no response at all
--   result.status           number|nil  -- HTTP status code
--   result.assertions_passed / .assertions_failed   number
--   result.assertions       list of { name, passed, skipped, message }
-- And `cfg_runner` is the user's `runner` config table, so a policy can be
-- made configurable rather than hardcoded (e.g. cfg_runner.assertions).
--
-- TODO(robbie): implement. The interesting case is an HTTP 200 whose `pm.test`
-- assertions FAILED. Treating that as ok=true keeps the body visible and makes
-- the CLI behave just like curl, but a red test silently reads as green. Treating
-- it as ok=false surfaces the failure loudly, but format_lines will hide the
-- response body behind an error dump — exactly when you most want to read it.
-- A third option is to let cfg decide ("strict" | "lenient"), or to gate on
-- HTTP status only and let the UI badge assertions separately.
function M.classify(result, cfg_runner)
  return true -- placeholder so the module loads; replace with the real policy
end


--- Turn one reporter `execution` into { request, result } in curlman's shape.
-- `ctx` = { collection, cfg_runner, failures_by_ref, items }.
--
-- `items` is the collection's already-loaded flat request list. The reporter
-- gives no folder path for an execution, only a bare item name, so a request
-- living in a folder would otherwise get a different display name (and thus a
-- different history bucket) than the curl path produces. Executions arrive in
-- document order, matching that list, so cursor.position recovers the folder —
-- guarded by a name check so a stale on-disk file can't mismatch silently.
function M.execution_to_entry(execution, ctx)
  ctx = ctx or {}
  local item = execution.item or {}
  local req_src = execution.request or {}
  local response = execution.response or {}
  if type(response) ~= "table" then response = {} end
  local err = transport_error(execution, ctx.failures_by_ref)

  local name = tostring(item.name or "request")
  local display, folder = name, ""
  local cursor = type(execution.cursor) == "table" and execution.cursor or {}
  local pos = tonumber(cursor.position)
  if ctx.items and pos then
    local known = ctx.items[pos + 1]
    if known and known.name == name then
      display = known.display or name
      folder = known.folder or ""
    end
  end

  local method = tostring(req_src.method or "GET"):upper()
  local url = postman.url_to_string(req_src.url)

  local request = {
    name = name,
    display = display,
    method = method,
    url = url,
    folder = folder,
    collection = ctx.collection,
    headers = {},
    via = "postman-cli",
  }

  local headers, raw_headers = headers_of(response)
  local body = body_of(response)
  local content_type = headers.map["content-type"]
  local assertions, passed, failed = assertions_of(execution)

  local result = {
    exit_code = err and 1 or 0,
    stderr = err or "",
    status = tonumber(response.code),
    reason = response.status,
    metrics = {
      http_code = tonumber(response.code),
      time_total = response.responseTime and (tonumber(response.responseTime) / 1000) or nil,
      size_download = tonumber(response.responseSize) or #body,
      content_type = content_type,
      url_effective = url,
    },
    headers = headers,
    raw_headers = raw_headers,
    body = body,
    content_type = content_type,
    filetype = curl.filetype_for(content_type),
    request = request,
    -- CLI-only extras; the curl path simply never sets these.
    via = "postman-cli",
    assertions = assertions,
    assertions_passed = passed,
    assertions_failed = failed,
    transport_error = err,
  }

  result.ok = M.classify(result, ctx.cfg_runner)
  return { request = request, result = result }
end

--- Parse a reporter JSON export into a list of { request, result } entries.
-- @return entries, summary  |  nil, err
function M.parse_report(content, collection_name, cfg_runner, items)
  local ok, data = pcall(vim.json.decode, content)
  if not ok then return nil, "reporter output was not valid JSON: " .. tostring(data) end
  if type(data) ~= "table" or type(data.run) ~= "table" then
    return nil, "reporter output has no `run` section (unexpected CLI version?)"
  end

  local run = data.run
  local executions = run.executions
  if type(executions) ~= "table" then
    return nil, "reporter output has no executions"
  end

  local name = collection_name
  if not name and type(data.collection) == "table" then
    name = data.collection.name or (type(data.collection.info) == "table" and data.collection.info.name)
  end

  -- run.failures holds the readable message for both transport and assertion
  -- failures, keyed by the same cursor ref the execution carries.
  local failures_by_ref = {}
  for _, f in ipairs(type(run.failures) == "table" and run.failures or {}) do
    local ref = type(f) == "table" and type(f.cursor) == "table" and f.cursor.ref
    if ref and not failures_by_ref[ref] then
      failures_by_ref[ref] = {
        message = type(f.error) == "table" and f.error.message or nil,
        at = f.at,
      }
    end
  end

  local ctx = {
    collection = name,
    cfg_runner = cfg_runner,
    failures_by_ref = failures_by_ref,
    items = items,
  }
  local entries = {}
  for _, ex in ipairs(executions) do
    if type(ex) == "table" then
      entries[#entries + 1] = M.execution_to_entry(ex, ctx)
    end
  end

  local stats = run.stats or {}
  local function stat(group, field)
    local g = stats[group]
    return (type(g) == "table" and tonumber(g[field])) or 0
  end
  local summary = {
    collection = name,
    requests = stat("requests", "total"),
    requests_failed = stat("requests", "failed"),
    assertions = stat("assertions", "total"),
    assertions_failed = stat("assertions", "failed"),
    duration = type(run.timings) == "table" and tonumber(run.timings.completed and run.timings.started
      and (run.timings.completed - run.timings.started)) or nil,
    failures = type(run.failures) == "table" and #run.failures or 0,
  }
  return entries, summary
end

------------------------------------------------------------------------ running

local function run_job(argv, cb)
  if _G.vim and vim.system then
    vim.system(argv, { text = true }, function(res)
      vim.schedule(function() cb(res.code, res.stdout or "", res.stderr or "") end)
    end)
    return
  end
  local out, errbuf = {}, {}
  local jid = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then out = d end end,
    on_stderr = function(_, d) if d then errbuf = d end end,
    on_exit = function(_, code)
      vim.schedule(function() cb(code, table.concat(out, "\n"), table.concat(errbuf, "\n")) end)
    end,
  })
  if jid <= 0 then
    vim.schedule(function() cb(-1, "", "failed to start the runner") end)
  end
end

--- Run a collection file end to end.
-- opts = { collection_path, collection_name, env_path, mode, folder, bail,
--          insecure, iteration_data, iteration_count, timeout_request,
--          extra_args, runner_cfg }
-- Calls cb(err, entries, summary, meta).
function M.run_collection(opts, cb)
  local kind, derr = M.detect(opts.mode)
  if not kind then return cb(derr) end

  local out_path = util.tempname()
  local argv = M.build_argv(kind, opts.collection_path, opts.env_path, out_path, opts)

  run_job(argv, function(code, stdout, stderr)
    local content = util.read_file(out_path)
    os.remove(util.expand(out_path))

    -- The report is the source of truth. A non-zero exit only means the run
    -- failed outright when no report was written — otherwise it just reflects
    -- failing assertions, which are a result, not an error.
    if not content or util.trim(content) == "" then
      local msg = util.trim(stderr) ~= "" and util.trim(stderr) or util.trim(stdout)
      if msg == "" then msg = "exit " .. tostring(code) .. " with no reporter output" end
      return cb(CLIS[kind].label .. " produced no report: " .. msg)
    end

    local entries, summary = M.parse_report(content, opts.collection_name, opts.runner_cfg, opts.items)
    if not entries then return cb(summary) end

    cb(nil, entries, summary, { kind = kind, label = CLIS[kind].label, argv = argv, exit_code = code })
  end)
end

M._internal = {
  bytes_to_string = bytes_to_string,
  headers_of = headers_of,
  assertions_of = assertions_of,
  body_of = body_of,
  CLIS = CLIS,
}

return M
