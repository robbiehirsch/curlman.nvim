-- Telescope extension registration for curlman.
-- Enables:  :Telescope curlman  |  :Telescope curlman requests  |  :Telescope curlman history
-- Load it with:  require("telescope").load_extension("curlman")
local ok, telescope = pcall(require, "telescope")
if not ok then return {} end

local ct = require("curlman.telescope")

return telescope.register_extension({
  exports = {
    curlman = ct.requests, -- default action for :Telescope curlman
    requests = ct.requests,
    history = ct.history,
  },
})
