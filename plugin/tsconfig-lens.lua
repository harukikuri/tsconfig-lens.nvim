if vim.g.loaded_tsconfig_lens then
  return
end
vim.g.loaded_tsconfig_lens = true

vim.api.nvim_create_user_command("TsconfigLens", function(o)
  require("tsconfig-lens").command(o.args)
end, {
  nargs = "?",
  complete = function()
    return { "chain", "log" }
  end,
  desc = "Show the tsconfig that applies to the current file",
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("tsconfig-lens-hl", { clear = true }),
  callback = function()
    if package.loaded["tsconfig-lens.ui"] then
      require("tsconfig-lens.ui").set_highlights()
    end
  end,
})
