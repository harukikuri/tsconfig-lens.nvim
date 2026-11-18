-- :checkhealth tsconfig-lens
local config = require("tsconfig-lens.config")
local node = require("tsconfig-lens.node")
local project = require("tsconfig-lens.project")

local M = {}

local function await(start)
  local res
  start(function(...)
    res = { ... }
  end)
  vim.wait(30000, function()
    return res ~= nil
  end, 10)
  return unpack(res or { nil, "timed out" })
end

local function is_ts(file)
  return file:match("%.[cm]?[jt]sx?$") ~= nil
end

-- :checkhealth opens its own buffer; check the file the user was looking at.
local function target_buf()
  local alt = vim.fn.bufnr("#")
  if alt > 0 and is_ts(vim.api.nvim_buf_get_name(alt)) then
    return alt
  end
  local prev = vim.fn.tabpagenr("#")
  if prev > 0 then
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(vim.api.nvim_list_tabpages()[prev]))
    if is_ts(vim.api.nvim_buf_get_name(buf)) then
      return buf
    end
  end
  local cur = vim.api.nvim_get_current_buf()
  return is_ts(vim.api.nvim_buf_get_name(cur)) and cur or nil
end

local function rel(path)
  return path and vim.fn.fnamemodify(path, ":~:.") or "none (inferred project)"
end

function M.check()
  local h = vim.health

  h.start("Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok(tostring(vim.version()))
  else
    h.error("Neovim >= 0.10 is required")
  end

  h.start("Node.js")
  local exe = config.options.node
  if vim.fn.executable(exe) == 0 then
    h.error("node not found: set config.node", { "Install Node.js, or point config.node at it." })
    return
  end
  local v = vim.system({ exe, "--version" }, { text = true }):wait()
  h.ok(("%s (%s)"):format(vim.trim(v.stdout or "?"), vim.fn.exepath(exe)))

  h.start("Config")
  for _, src in ipairs(config.options.sources) do
    if src ~= "tsserver" and src ~= "api" then
      h.error(("unknown source %q in config.sources"):format(src), { 'Use "tsserver" and/or "api".' })
    end
  end
  h.ok("sources: " .. table.concat(config.options.sources, ", "))

  local buf = target_buf()
  if not buf then
    h.start("Current file")
    h.info("Open a TypeScript/JavaScript file and run :checkhealth tsconfig-lens again to check its project.")
    return
  end
  local file = vim.api.nvim_buf_get_name(buf)
  h.start("Current file: " .. rel(file))

  -- The project's own TypeScript.
  local data, err = await(function(done)
    node.run({ mode = "project", file = file }, done)
  end)
  local api_tsconfig
  if not data then
    h.error(err)
  else
    h.ok("typescript " .. data.ts_version .. (data.native and " (TypeScript 7: no extends chain or origins)" or ""))
    api_tsconfig = data.project ~= vim.NIL and data.project or nil
    h.ok("tsconfig via typescript API: " .. rel(api_tsconfig))
  end

  -- The LSP, which is what your editor actually uses.
  local names, roots = {}, {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    table.insert(names, c.name)
    table.insert(roots, ("%s root_dir: %s"):format(c.name, c.config.root_dir and rel(c.config.root_dir) or "none"))
  end
  local lsp, lerr = await(function(done)
    project.resolve(buf, done, { "tsserver" })
  end)
  if not lsp then
    h.warn("no answer from an LSP" .. (#names > 0 and (" (attached: " .. table.concat(names, ", ") .. ")") or ""), {
      "tsconfig-lens asks ts_ls, vtsls or tsgo. Without one, it falls back to the TypeScript API,",
      "which can differ from what your editor uses.",
    })
    -- The specific reason was logged by project.resolve.
    for _, line in ipairs(config.logs) do
      lerr = line:match("project: tsserver: (.*)$") or lerr
    end
    h.info(lerr)
    return
  end
  h.ok(("tsconfig via %s: %s"):format(lsp.via, rel(lsp.tsconfig)))
  if data and lsp.tsconfig ~= api_tsconfig then
    h.warn("the LSP and the TypeScript API disagree", {
      "tsserver does not look for a tsconfig.json above the LSP client's root_dir.",
      unpack(roots),
    })
  end
end

return M
