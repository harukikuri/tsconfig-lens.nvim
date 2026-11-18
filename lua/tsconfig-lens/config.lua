local M = {}

M.defaults = {
  open = "float", -- "float" | "split" | "vsplit"
  node = "node", -- Node.js executable
  sources = { "tsserver", "api" }, -- how to find the file's tsconfig, in order
  show_origin = true,
  warn_inferred = false,
  keymaps = { jump = "<CR>", toggle = "<Tab>", yank = "y", refresh = "r", close = "q" },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists are replaced, not merged index by index.
  if opts.sources then
    M.options.sources = opts.sources
  end
end

--- Messages shown by `:TsconfigLens log`.
M.logs = {}

function M.log(msg)
  table.insert(M.logs, os.date("%H:%M:%S ") .. msg)
end

return M
