local config = require("tsconfig-lens.config")
local node = require("tsconfig-lens.node")
local origin = require("tsconfig-lens.origin")
local project = require("tsconfig-lens.project")
local ui = require("tsconfig-lens.ui")

local M = {}

local diag_ns = vim.api.nvim_create_namespace("tsconfig-lens.inferred")

local function is_ts(file)
  return file:match("%.[cm]?[jt]sx?$") ~= nil
end

local function err(msg)
  config.log(msg)
  vim.notify("tsconfig-lens: " .. msg, vim.log.levels.ERROR)
end

--- Opens the lens for a buffer.
--- @param view? "chain" show only the extends chain
function M.open(view, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if not is_ts(file) then
    return err("not a TypeScript/JavaScript file")
  end
  local function refresh()
    node.clear_cache()
    M.open(view, bufnr)
  end
  project.resolve(bufnr, function(proj, perr)
    if not proj then
      return err(perr)
    end
    local state = { file = file, project = proj, view = view }
    if not proj.tsconfig then
      return ui.show(state, refresh)
    end
    node.config(file, proj.tsconfig, function(data, cerr)
      if not data then
        return err(cerr)
      end
      state.data = data
      state.origins = origin.compute(data)
      ui.show(state, refresh)
    end)
  end)
end

function M.command(args)
  if args == "log" then
    return ui.show_text(config.logs)
  end
  if args ~= "" and args ~= "chain" then
    return err("unknown argument: " .. args)
  end
  M.open(args == "chain" and "chain" or nil)
end

--- For statuslines: the file's tsconfig, "inferred", or "" (not a TS/JS file, or not known yet).
function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr].tsconfig_lens_status or ""
end

local function update_status(bufnr)
  if not is_ts(vim.api.nvim_buf_get_name(bufnr)) then
    return
  end
  project.resolve(bufnr, function(proj, perr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not proj then
      config.log("status: " .. perr)
      vim.b[bufnr].tsconfig_lens_status = ""
      return
    end
    vim.b[bufnr].tsconfig_lens_status = proj.tsconfig and vim.fn.fnamemodify(proj.tsconfig, ":~:.") or "inferred"
    if config.options.warn_inferred and not proj.tsconfig then
      vim.diagnostic.set(diag_ns, bufnr, {
        {
          lnum = 0,
          col = 0,
          severity = vim.diagnostic.severity.HINT,
          source = "tsconfig-lens",
          message = "This file is not included by any tsconfig.json. TypeScript checks it with default options.",
        },
      })
    else
      vim.diagnostic.reset(diag_ns, bufnr)
    end
  end)
end

function M.setup(opts)
  config.setup(opts)
  local group = vim.api.nvim_create_augroup("tsconfig-lens", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].tsconfig_lens_status == nil then
        update_status(ev.buf)
      end
    end,
  })
  -- The LSP answer is preferred over the API one, so ask again once it attaches.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      update_status(ev.buf)
    end,
  })
  -- A saved tsconfig can move files between projects.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.json",
    callback = function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          vim.b[b].tsconfig_lens_status = nil
        end
      end
      update_status(vim.api.nvim_get_current_buf())
    end,
  })
end

return M
