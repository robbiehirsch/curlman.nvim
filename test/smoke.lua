-- Headless smoke test for curlman profiles / favourites / multi-run.
-- run from the repo root:  nvim --headless -u NONE -c "luafile test/smoke.lua"
local PLUGIN = vim.fn.fnamemodify("./", ":p")
vim.opt.runtimepath:prepend(PLUGIN)
vim.o.swapfile = false

local passed, failed = 0, 0
local function ok(cond, msg)
  if cond then passed = passed + 1; print("  ok   - " .. msg)
  else failed = failed + 1; print("  FAIL - " .. msg) end
end
local function eq(a, b, msg)
  ok(a == b, msg .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

local function run()
  local tmp = "/tmp/cmtest"
  vim.fn.delete(tmp, "rf")

  -- stub curl BEFORE anything sends: record every resolved request, answer 200
  local curl = require("curlman.curl")
  local sent = {}
  curl.execute = function(resolved, _cfg, cb)
    sent[#sent + 1] = resolved
    cb({
      ok = true, status = 200, reason = "OK",
      body = '{"url":"' .. resolved.url .. '"}',
      filetype = "json", content_type = "application/json",
      raw_headers = "HTTP/2 200", stderr = "", exit_code = 0,
      metrics = { time_total = 0.01, size_download = 20 },
      request = resolved,
      headers = { list = {} },
    })
  end

  local cm = require("curlman")
  cm.setup({
    history = { state_file = tmp .. "/recent.json", dir = tmp .. "/history" },
    secrets_file = tmp .. "/nope.json",
    profiles = { dir = tmp .. "/profiles", favorites_file = tmp .. "/favorites.json" },
    ui = { jq_pretty = false },
  })
  local profiles = require("curlman.profiles")
  local postman = require("curlman.postman")
  local ui = require("curlman.ui")

  -- load the bundled demo collection (2+ requests referencing {{base_url}})
  local col = vim.api.nvim_get_runtime_file("lua/curlman/sample/demo.postman_collection.json", false)[1]
  ok(col ~= nil, "sample collection found on rtp")
  cm.load_collection(col)
  ok(#cm.state.requests > 0, "demo requests loaded (" .. #cm.state.requests .. ")")

  -- -- profile CRUD --------------------------------------------------------
  local path = profiles.save("dev", { base_url = "https://dev.example.com", token = "dev-t" })
  ok(path and vim.fn.filereadable(path) == 1, "save: profile file written")
  local env = postman.parse_environment(table.concat(vim.fn.readfile(path), "\n"))
  ok(env and env.name == "dev", "save: file round-trips through parse_environment")
  eq(env and env.map.base_url, "https://dev.example.com", "save: values survive the round-trip")

  profiles.save("prod", { base_url = "https://prod.example.com", token = "prod-t" })
  profiles.save("staging", { base_url = "https://staging.example.com" })
  eq(#profiles.names(), 3, "list: three profiles")

  profiles.load_all() -- reload from disk
  eq(#profiles.names(), 3, "load_all: reload from disk finds all three")
  eq(profiles.get("prod").values.base_url, "https://prod.example.com", "load_all: values intact")

  local _, rerr = profiles.rename("staging", "stage")
  ok(rerr == nil and profiles.get("stage") and not profiles.get("staging"), "rename: staging → stage")
  ok(profiles.rename("stage", "dev") == nil, "rename: refuses to clobber an existing name")

  profiles.duplicate("dev", "dev2")
  eq(profiles.get("dev2").values.token, "dev-t", "duplicate: values copied")
  profiles.delete("dev2")
  ok(profiles.get("dev2") == nil, "delete: removes the profile")
  eq(#vim.fn.glob(tmp .. "/profiles/dev2.json", true, true), 0, "delete: removes the file")

  -- save a copy to an explicit location; canonical path unchanged
  local copy = tmp .. "/exported-dev.json"
  profiles.save("dev", profiles.get("dev").values, copy)
  ok(vim.fn.filereadable(copy) == 1, "save-to-location: explicit copy written")
  ok(profiles.get("dev").path:find("/profiles/dev.json", 1, true) ~= nil,
    "save-to-location: canonical store path unchanged")

  -- -- favourites ----------------------------------------------------------
  ok(profiles.toggle_fav_profile("prod"), "fav: profile toggled on")
  local r1 = cm.state.requests[1]
  ok(profiles.toggle_fav_endpoint(r1), "fav: endpoint toggled on")
  profiles.load_favorites() -- reload from disk
  ok(profiles.is_fav_profile("prod"), "fav: profile persisted")
  ok(profiles.is_fav_endpoint(r1), "fav: endpoint persisted")
  eq(profiles.names_fav_first()[1], "prod", "fav: favourite floats to top of profile list")

  -- -- effective_vars snapshot ---------------------------------------------
  local cname = cm.state.config_order[1]
  cm.state.collections[cname].overrides = { base_url = "https://override.example.com" }
  local eff = cm.effective_vars(cname)
  eq(eff.base_url, "https://override.example.com", "effective_vars: unsaved override captured")
  cm.state.collections[cname].overrides = {}

  -- -- multi-run: isolation + tagging + compare ----------------------------
  cm.state.collections[cname].overrides = { base_url = "https://SHOULD-NOT-LEAK" }
  local req
  for _, r in ipairs(cm.state.requests) do
    if not req then req = r end
  end
  local done_entries
  local tabs_before = #vim.api.nvim_list_tabpages()
  cm.run_multi(req, { "dev", "prod" }, function(entries) done_entries = entries end)
  vim.wait(2000, function() return done_entries ~= nil end, 10)
  ok(done_entries ~= nil, "multi-run: completed")
  eq(#done_entries, 2, "multi-run: one entry per profile")
  eq(done_entries[1].profile, "dev", "multi-run: first entry tagged dev")
  eq(done_entries[2].profile, "prod", "multi-run: second entry tagged prod")
  ok(sent[#sent - 1].url:find("dev.example.com", 1, true) ~= nil,
    "multi-run: dev run resolved against the dev profile")
  ok(sent[#sent].url:find("prod.example.com", 1, true) ~= nil,
    "multi-run: prod run resolved against the prod profile")
  ok(not sent[#sent].url:find("SHOULD%-NOT%-LEAK"),
    "multi-run: in-memory overrides do NOT leak into profile runs")
  cm.state.collections[cname].overrides = {}

  -- entry label carries the profile
  local history = require("curlman.history")
  ok(history.entry_label(done_entries[1]):find("[dev]", 1, true) ~= nil,
    "labels: entry_label includes [profile]")

  -- compare: exactly two entries opens a diff tab automatically
  ui.compare_entries(done_entries)
  eq(#vim.api.nvim_list_tabpages(), tabs_before + 1, "compare: diff tab opened for 2 profiles")
  local diffed = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then diffed = diffed + 1 end
  end
  eq(diffed, 2, "compare: both windows in diff mode")
  pcall(vim.cmd, "tabclose")

  -- missing profile is reported, not fatal
  local done2
  cm.run_multi(req, { "dev", "ghost" }, function(entries) done2 = entries end)
  vim.wait(2000, function() return done2 ~= nil end, 10)
  eq(#done2, 1, "multi-run: unknown profile skipped gracefully")

  -- -- postman CLI runner ---------------------------------------------------
  local runner = require("curlman.runner")

  -- argv shapes for both CLIs
  local pargv = runner.build_argv("postman", "/c.json", "/e.json", "/o.json", { folder = "Auth", bail = true })
  eq(pargv[1] .. " " .. pargv[2] .. " " .. pargv[3], "postman collection run", "runner: postman sub-command")
  ok(vim.tbl_contains(pargv, "--reporter-json-export"), "runner: postman exports json report")
  ok(vim.tbl_contains(pargv, "Auth") and vim.tbl_contains(pargv, "--bail"), "runner: shared flags appended")

  local nargv = runner.build_argv("newman", "/c.json", nil, "/o.json", {})
  eq(nargv[1] .. " " .. nargv[2], "newman run", "runner: newman sub-command")
  ok(vim.tbl_contains(nargv, "--suppress-exit-code"), "runner: newman exit code suppressed")
  ok(not vim.tbl_contains(nargv, "-e"), "runner: no -e flag when there is no environment")

  eq(select(1, runner.detect("nope")), nil, "runner: unknown mode rejected")

  -- reporter body arrives as a serialized Node Buffer (array of bytes)
  local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[i] = s:byte(i) end
    return t
  end
  local payload = '{"hello":"world"}'
  eq(runner._internal.bytes_to_string(to_bytes(payload)), payload, "runner: Buffer byte array decoded")

  local report = vim.json.encode({
    collection = { name = "Demo" },
    run = {
      stats = { requests = { total = 2, failed = 0 }, assertions = { total = 3, failed = 1 } },
      executions = {
        {
          item = { name = "Get user" },
          request = { method = "get", url = { raw = "https://api.test/u/1" } },
          response = {
            code = 200, status = "OK", responseTime = 250, responseSize = #payload,
            header = { { key = "Content-Type", value = "application/json" } },
            stream = { type = "Buffer", data = to_bytes(payload) },
          },
          assertions = {
            { assertion = "status is 200" },
            { assertion = "has id", error = { message = "expected id" } },
            { assertion = "skipped one", skipped = true },
          },
        },
        {
          item = { name = "Down" },
          request = { method = "POST", url = "https://api.test/x" },
          requestError = { message = "getaddrinfo ENOTFOUND" },
        },
      },
    },
  })

  local entries, summary = runner.parse_report(report, "Demo", { assertions = "strict" })
  ok(entries ~= nil, "runner: report parsed")
  eq(#entries, 2, "runner: one entry per execution")

  local e1 = entries[1]
  eq(e1.request.method, "GET", "runner: method upper-cased")
  eq(e1.request.display, "Get user", "runner: display name from item")
  eq(e1.request.collection, "Demo", "runner: entry tagged with collection")
  eq(e1.result.status, 200, "runner: status mapped")
  eq(e1.result.body, payload, "runner: body decoded onto result")
  -- a failed assertion prepends a diagnostic block, so the buffer is no longer
  -- pure JSON and the filetype must drop to text or highlighting lies
  eq(e1.result.filetype, "text", "runner: filetype drops to text when diagnostics are shown")
  eq(e1.result.diagnostics, true, "runner: failed assertion flags diagnostics")
  eq(e1.result.headers.map["content-type"], "application/json", "runner: header map built")
  ok(e1.result.raw_headers:find("HTTP/1.1 200"), "runner: raw header block reconstructed")
  eq(e1.result.metrics.time_total, 0.25, "runner: responseTime converted to seconds")
  eq(e1.result.assertions_passed, 1, "runner: passing assertions counted")
  eq(e1.result.assertions_failed, 1, "runner: failing assertions counted")
  eq(#e1.result.assertions, 3, "runner: skipped assertion still listed")

  local e2 = entries[2]
  eq(e2.request.url, "https://api.test/x", "runner: string url accepted")
  eq(e2.result.transport_error, "getaddrinfo ENOTFOUND", "runner: transport error surfaced")

  eq(summary.assertions_failed, 1, "runner: summary reads run stats")
  eq(summary.requests, 2, "runner: summary request total")

  -- Shapes below were captured from a REAL `newman run -r json` export; the
  -- reporter does NOT match the naive reading of the docs, so these are
  -- regression tests rather than guesses:
  --   * request.url is a structured Url object, never {raw=...}
  --   * requestError is a bare Node errno object with NO message field
  --   * the readable message lives in run.failures, keyed by cursor.ref
  --   * folders are absent from executions, so position recovers them
  local real = vim.json.encode({
    collection = { name = "Real" },
    run = {
      stats = { requests = { total = 2, failed = 1 }, assertions = { total = 1, failed = 0 } },
      failures = {
        { at = "request", cursor = { ref = "ref-dead" }, error = { name = "Error", message = "getaddrinfo ENOTFOUND nope.invalid" } },
      },
      executions = {
        {
          cursor = { position = 0, ref = "ref-ok" },
          item = { name = "Get JSON" },
          request = { method = "GET", url = { protocol = "https", host = { "postman-echo", "com" },
            path = { "get" }, query = { { key = "a", value = "robbie" } } } },
          response = { code = 200, status = "OK", responseTime = 246, responseSize = 5,
            header = { { key = "Content-Type", value = "application/json; charset=utf-8" } },
            stream = { type = "Buffer", data = to_bytes("hello") } },
          assertions = { { assertion = "status is 200", skipped = false } },
        },
        {
          cursor = { position = 1, ref = "ref-dead" },
          item = { name = "Dead host" },
          request = { method = "GET", url = { protocol = "https", host = { "nope", "invalid" }, path = { "x" } } },
          requestError = { errno = -3008, code = "ENOTFOUND", syscall = "getaddrinfo", hostname = "nope.invalid" },
        },
      },
    },
  })

  -- position -> folder recovery, so a foldered request shares curl's history bucket
  local loaded = {
    { name = "Get JSON", display = "Auth / Get JSON", folder = "Auth" },
    { name = "Dead host", display = "Auth / Dead host", folder = "Auth" },
  }
  local rentries = runner.parse_report(real, "Real", {}, loaded)
  ok(rentries ~= nil, "runner(real): report parsed")
  eq(rentries[1].request.url, "https://postman-echo.com/get?a=robbie", "runner(real): structured Url reconstructed")
  eq(rentries[1].request.display, "Auth / Get JSON", "runner(real): folder recovered from cursor position")
  eq(rentries[1].request.folder, "Auth", "runner(real): folder set on request")
  eq(rentries[1].result.body, "hello", "runner(real): Buffer body decoded")
  eq(rentries[1].result.assertions_passed, 1, "runner(real): assertion with no error counts as passed")
  eq(rentries[1].result.transport_error, nil, "runner(real): healthy execution has no transport error")
  eq(rentries[1].result.diagnostics, false, "runner(real): clean execution needs no diagnostics")
  eq(rentries[1].result.filetype, "json", "runner(real): clean execution keeps its content-type filetype")
  eq(rentries[1].result.ok, true, "runner(real): clean execution is a success")
  eq(rentries[2].request.url, "https://nope.invalid/x", "runner(real): dead-host url reconstructed")
  eq(rentries[2].result.transport_error, "getaddrinfo ENOTFOUND nope.invalid",
    "runner(real): message taken from run.failures, not the errno object")
  eq(rentries[2].result.status, nil, "runner(real): failed execution has no status")

  -- an assertion failure must NOT be mistaken for a transport error
  local afail = vim.json.encode({
    run = {
      stats = {}, failures = { { at = "assertion:1 in test-script", cursor = { ref = "r1" },
        error = { message = "expected 1 to deeply equal 2" } } },
      executions = { { cursor = { position = 0, ref = "r1" }, item = { name = "T" },
        request = { method = "GET", url = "https://x.test/" },
        response = { code = 200, status = "OK", header = {}, stream = { type = "Buffer", data = to_bytes("{}") } },
        assertions = { { assertion = "t", error = { message = "expected 1 to deeply equal 2" } } } } },
    },
  })
  local ae = runner.parse_report(afail, "A", {})
  eq(ae[1].result.transport_error, nil, "runner(real): assertion failure is not a transport error")
  eq(ae[1].result.assertions_failed, 1, "runner(real): assertion failure still counted")
  eq(ae[1].result.status, 200, "runner(real): body/status preserved despite failed assertion")

  -- -- classify: what counts as a failure ----------------------------------
  -- a transport failure is never a success, whatever the assertion policy
  eq(rentries[2].result.ok, false, "classify: DNS failure is not a success")
  eq(rentries[2].result.diagnostics, true, "classify: DNS failure flags diagnostics")
  local lenient = runner.parse_report(real, "Real", { assertions = "lenient" }, loaded)
  eq(lenient[2].result.ok, false, "classify: DNS failure fails even under lenient")

  -- a 200 with a failed assertion is the configurable case
  local strict_a = runner.parse_report(afail, "A", { assertions = "strict" })
  eq(strict_a[1].result.ok, false, "classify: strict fails a 200 with a failed assertion")
  local lenient_a = runner.parse_report(afail, "A", { assertions = "lenient" })
  eq(lenient_a[1].result.ok, true, "classify: lenient passes a 200 with a failed assertion")
  eq(lenient_a[1].result.diagnostics, true, "classify: lenient still reports the assertion")

  -- HTTP status must NOT decide ok, or curl and CLI stop being comparable
  local notfound = vim.json.encode({ run = { stats = {}, executions = { {
    cursor = { position = 0, ref = "n1" }, item = { name = "NF" },
    request = { method = "GET", url = "https://x.test/nope" },
    response = { code = 404, status = "Not Found", header = {}, stream = { type = "Buffer", data = to_bytes("{}") } },
  } } } })
  local nf = runner.parse_report(notfound, "A", {})
  eq(nf[1].result.ok, true, "classify: a 404 is a response, not a failure (matches curl)")

  -- -- the DNS error actually renders ----------------------------------------
  local dns_lines = ui.format_lines(rentries[2].result, cm.cfg)
  ok(dns_lines[1]:find("REQUEST FAILED", 1, true) ~= nil, "render: DNS failure leads with REQUEST FAILED")
  local joined = table.concat(dns_lines, "\n")
  ok(joined:find("getaddrinfo ENOTFOUND nope.invalid", 1, true) ~= nil,
    "render: the actual DNS error text is shown")
  ok(joined:find("https://nope.invalid/x", 1, true) ~= nil, "render: the failing URL is shown")

  -- a failed assertion shows the detail AND keeps the body
  local a_lines = table.concat(ui.format_lines(strict_a[1].result, cm.cfg), "\n")
  ok(a_lines:find("1 of 1 assertions failed", 1, true) ~= nil, "render: assertion summary shown")
  ok(a_lines:find("expected 1 to deeply equal 2", 1, true) ~= nil, "render: assertion message shown")
  ok(a_lines:find("{}", 1, true) ~= nil, "render: the response body is still shown below the diagnostics")

  -- a clean execution renders as a pure body, exactly like curl
  local clean = table.concat(ui.format_lines(rentries[1].result, cm.cfg), "\n")
  eq(clean, "hello", "render: a clean execution is just the body, no header")

  -- name mismatch (file changed on disk since load) must fall back, not mislabel
  local drifted = runner.parse_report(real, "Real", {}, { { name = "Something Else", display = "X / Y", folder = "X" } })
  eq(drifted[1].request.display, "Get JSON", "runner(real): name mismatch falls back to the bare item name")

  eq(select(1, runner.parse_report("not json", "Demo", {})), nil, "runner: invalid JSON rejected")
  eq(select(1, runner.parse_report('{"foo":1}', "Demo", {})), nil, "runner: report without run section rejected")

  -- history integration: CLI entries land in normal buckets and are diffable
  local before = #history.cards()
  for _, e in ipairs(entries) do
    history.record(e.request, e.result, { "body" })
  end
  ok(#history.cards() == before + 2, "runner: CLI executions recorded as history cards")

  -- -- picker ordering -----------------------------------------------------
  -- stub vim.ui.select to capture the ordered items pick_request offers
  local offered
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _opts, _cb) offered = items end
  ui.pick_request(cm.state.requests, function() end)
  vim.ui.select = orig_select
  ok(offered ~= nil, "picker: pick_request invoked select")
  ok(offered[1] == r1, "picker: favourite endpoint floated to the top")
end

local okrun, err = pcall(run)
if not okrun then
  failed = failed + 1
  print("  FAIL - uncaught error: " .. tostring(err))
end
print(string.format("\n=== curlman smoke: %d passed, %d failed ===", passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
