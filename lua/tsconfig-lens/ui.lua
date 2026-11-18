local config = require("tsconfig-lens.config")

local M = {}

local ns = vim.api.nvim_create_namespace("tsconfig-lens")

function M.set_highlights()
  for group, link in pairs({
    TsconfigLensHeader = "Title",
    TsconfigLensPath = "Directory",
    TsconfigLensKey = "Identifier",
    TsconfigLensValue = "String",
    TsconfigLensOrigin = "Comment",
    TsconfigLensWarning = "DiagnosticWarn",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end
M.set_highlights()

local function rel(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function pad(s, width)
  return s .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(s), 0))
end

--- Builds the lens text. Pure: no buffers or windows are touched.
--- @param s table { file, project = {tsconfig, via}, data?, origins?, mismatch?, view? }
--- @return string[] lines, table[] highlights {row, col_start, col_end, group}, table<integer, table> actions by row (1-based)
function M.render(s)
  local lines, hls, actions = {}, {}, {}
  local function add(text, action)
    table.insert(lines, text)
    actions[#lines] = action
    return #lines - 1
  end
  local function hl(row, from, to, group)
    table.insert(hls, { row, from, to, group })
  end
  local right = 53

  hl(add(rel(s.file)), 0, -1, "TsconfigLensHeader")

  local tsconfig = s.project.tsconfig
  local head = "project: " .. (tsconfig and rel(tsconfig) or "none (inferred project)")
  local row = add(pad(head, right) .. "  (via " .. s.project.via .. ")", tsconfig and { path = tsconfig } or nil)
  hl(row, 9, #head, tsconfig and "TsconfigLensPath" or "TsconfigLensWarning")
  hl(row, #pad(head, right), -1, "TsconfigLensOrigin")

  if not tsconfig then
    hl(add("  This file is not included by any tsconfig.json."), 0, -1, "TsconfigLensWarning")
    hl(add("  TypeScript checks it with default options."), 0, -1, "TsconfigLensWarning")
    return lines, hls, actions
  end

  local data = s.data
  add("")
  hl(add("Extends"), 0, -1, "TsconfigLensHeader")
  local function path_line(prefix, path)
    local r = add(prefix .. rel(path), { path = path })
    hl(r, #prefix, -1, "TsconfigLensPath")
  end
  if data.native then
    path_line("  ", data.tsconfig)
    hl(add("  (extends chain unavailable on TypeScript 7)"), 0, -1, "TsconfigLensOrigin")
  elseif type(data.chain.tree) == "table" then
    local function walk(node, prefix, branch)
      path_line(prefix .. branch, node.path)
      local kids = node.children
      for i, child in ipairs(kids) do
        local indent = branch == "" and prefix or prefix .. "  "
        walk(child, indent, i == #kids and "└ " or "├ ")
      end
    end
    walk(data.chain.tree, "  ", "")
  else
    -- TypeScript's lists did not form a tree: show what was loaded, without structure.
    for _, path in ipairs(data.chain.files) do
      path_line("  ", path)
    end
  end

  if s.view == "chain" then
    return lines, hls, actions
  end

  add("")
  row = add(pad("Effective compilerOptions", right) .. "  (tsc --showConfig)")
  hl(row, 0, #"Effective compilerOptions", "TsconfigLensHeader")
  hl(row, right + 2, -1, "TsconfigLensOrigin")

  local show_origin = config.options.show_origin
  if show_origin and data.native then
    hl(add("  (origins unavailable on TypeScript 7)"), 0, -1, "TsconfigLensOrigin")
    show_origin = false
  end

  local kw, vw = 0, 0
  for _, opt in ipairs(data.options) do
    kw = math.max(kw, #opt[1])
    vw = math.max(vw, math.min(vim.fn.strdisplaywidth(opt[2]), 40))
  end
  for _, opt in ipairs(data.options) do
    local key, value = opt[1], opt[2]
    local action = { yank = ('"%s": %s'):format(key, value) }
    local text = "  " .. pad(key, kw) .. "  " .. value
    local origin_text
    if show_origin then
      local o = s.origins and s.origins[key]
      if not s.origins then
        origin_text = "unknown"
      elseif o then
        origin_text = rel(o.path) .. (o.line and (":" .. o.line) or "")
        action.path, action.line = o.path, o.line
      else
        origin_text = "not set in any file"
      end
      text = "  " .. pad(key, kw) .. "  " .. pad(value, vw) .. "  " .. origin_text
    end
    row = add(text, action)
    hl(row, 2, 2 + #key, "TsconfigLensKey")
    hl(row, 4 + kw, 4 + kw + #value, "TsconfigLensValue")
    if origin_text then
      hl(row, #text - #origin_text, -1, "TsconfigLensOrigin")
    end
  end
  return lines, hls, actions
end

local function open_window(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "tsconfig-lens"
  local mode = config.options.open
  local win
  if mode == "float" then
    local width = 20
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
    end
    width = math.min(width, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 6)
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = "rounded",
      title = " tsconfig-lens ",
    })
  else
    vim.cmd(mode == "vsplit" and "botright vsplit" or "botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  return buf, win
end

local function close(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

--- Shows plain lines (used for `:TsconfigLens log`).
function M.show_text(lines)
  local buf, win = open_window(#lines > 0 and lines or { "(empty)" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "(empty)" })
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", config.options.keymaps.close, function()
    close(win)
  end, { buffer = buf, nowait = true })
end

--- @param s table see M.render
--- @param refresh fun() re-run the lens without cache
function M.show(s, refresh)
  local lines, hls, actions = M.render(s)
  local buf, win = open_window(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    local line = lines[h[1] + 1]
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], {
      end_col = h[3] == -1 and #line or h[3],
      hl_group = h[4],
    })
  end
  vim.bo[buf].modifiable = false

  local keys = config.options.keymaps
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map(keys.jump, function()
    local a = actions[vim.api.nvim_win_get_cursor(win)[1]]
    if not (a and a.path) then
      return
    end
    close(win)
    vim.cmd.edit(vim.fn.fnameescape(a.path))
    if a.line then
      vim.api.nvim_win_set_cursor(0, { math.min(a.line, vim.api.nvim_buf_line_count(0)), 0 })
    end
  end)
  map(keys.yank, function()
    local a = actions[vim.api.nvim_win_get_cursor(win)[1]]
    if a and a.yank then
      vim.fn.setreg(vim.v.register, a.yank)
    end
  end)
  map(keys.refresh, function()
    close(win)
    refresh()
  end)
  map(keys.close, function()
    close(win)
  end)
end

return M
