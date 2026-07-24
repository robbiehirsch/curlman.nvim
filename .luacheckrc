-- luacheck configuration for curlman.nvim
std = "lua51"
globals = { "vim" }
read_globals = { "vim" }
-- Telescope extension files intentionally use a runtime `arg`-free style
ignore = {
  "212", -- unused argument (opts, self, etc. in callbacks)
  "122", -- setting a read-only field of vim (we never do, but be lenient)
}
max_line_length = 140
exclude_files = { "lua/curlman/sample/" }
