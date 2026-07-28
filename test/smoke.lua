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
