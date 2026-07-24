-- curlman.telescope — a first-class Telescope extension for curlman. Loaded
-- only when Telescope is present (guarded), so curlman keeps working without it.
-- Provides `:Telescope curlman requests` and `:Telescope curlman history`.

local M = {}

local ok_pickers, pickers = pcall(require, "telescope.pickers")
if not ok_pickers then return M end -- Telescope absent: expose a no-op module
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local function core() return require("curlman") end
local util = require("curlman.util")
local uimod = require("curlman.ui")
local history = require("curlman.history")

--- Fuzzy-find a request across loaded collections; ⏎ runs it, <C-y> copies curl.
function M.requests(opts)
  opts = opts or {}
  local reqs = core().state.requests or {}
  pickers.new(opts, {
    prompt_title = "curlman · requests",
    finder = finders.new_table({
      results = reqs,
      entry_maker = function(r)
        local display = string.format("%-6s %s  (%s)", r.method or "?", r.display or r.name or "", r.collection or "")
        return { value = r, display = display, ordinal = display }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "request (resolved curl)",
      define_preview = function(self, entry)
        local lines = core().preview_request_lines(entry.value)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        pcall(function() vim.bo[self.state.bufnr].filetype = "sh" end)
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then core().send(entry.value) end
      end)
      map({ "i", "n" }, "<C-y>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local r = entry.value
          core().copy_request_named(r.collection, r.method, r.display or r.name)
        end
      end)
      return true
    end,
  }):find()
end

--- Browse the whole response history; preview shows the body. ⏎ opens it big,
--- <C-y> copies the transcript to a buffer.
function M.history(opts)
  opts = opts or {}
  local flat = {}
  for _, key in ipairs(history.order) do
    local rec = history.store[key]
    if rec then for _, e in ipairs(rec.entries) do flat[#flat + 1] = e end end
  end
  pickers.new(opts, {
    prompt_title = "curlman · history",
    finder = finders.new_table({
      results = flat,
      entry_maker = function(e)
        local display = string.format("%-6s %-26s %-4s %-8s (%s) %s",
          e.method or "?", e.name or "", tostring(e.status or "ERR"),
          util.human_time(e.time_total), e.config or "", e.time_str or "")
        return { value = e, display = display, ordinal = display }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "response body",
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, entry.value.lines or {})
        pcall(function() vim.bo[self.state.bufnr].filetype = entry.value.filetype or "text" end)
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then uimod.show_body(entry.value, core().cfg) end
      end)
      map({ "i", "n" }, "<C-y>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then uimod.to_buffer("both", entry.value, core().cfg) end
      end)
      return true
    end,
  }):find()
end

return M
