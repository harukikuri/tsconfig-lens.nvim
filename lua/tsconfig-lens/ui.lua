local config = require("tsconfig-lens.config")

local M = {}

local ns = vim.api.nvim_create_namespace("tsconfig-lens")

function M.set_highlights()
  for group, link in pairs({
    TsconfigLensHeader = "Title",
    TsconfigLensPath = "Directory",
    TsconfigLensKey = "Identifier",
    TsconfigLensValue = "String",
    TsconfigLensBoolean = "Boolean",
    TsconfigLensOrigin = "Comment",
    TsconfigLensLine = "LineNr",
    TsconfigLensWarning = "DiagnosticWarn",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  -- A link cannot add attributes, so take Comment's colors and strike them through.
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "TsconfigLensOverridden", {
    fg = comment.fg,
    ctermfg = comment.ctermfg,
    strikethrough = true,
    default = true,
  })
end
M.set_highlights()

local function rel(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function width(s)
  return vim.fn.strdisplaywidth(s)
end

local function pad(s, w)
  return s .. string.rep(" ", math.max(w - width(s), 0))
end

local function all_strings(list)
  for _, x in ipairs(list) do
    if type(x) ~= "string" then
      return false
    end
  end
  return true
end

--- Lossless, lighter rendering of a JSON value. `y` still yanks the exact JSON.
function M.pretty(json)
  local ok, v = pcall(vim.json.decode, json)
  if not ok then
    return json
  end
  if type(v) == "string" then
    return v
  end
  if type(v) == "table" and next(v) ~= nil then
    if vim.islist(v) and all_strings(v) then
      return table.concat(v, " · ")
    end
    if not vim.islist(v) then
      local keys = vim.tbl_keys(v)
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        if type(v[k]) ~= "table" or not vim.islist(v[k]) or not all_strings(v[k]) then
          return json
        end
        table.insert(parts, k .. " → " .. table.concat(v[k], ", "))
      end
      return table.concat(parts, "   ")
    end
  end
  return json
end

--- Builds the lens text. Pure: no buffers or windows are touched.
--- @param s table { file, project = {tsconfig, via}, data?, origins?, view?, expanded? }
--- @return string[] lines, table[] highlights {row, col_start, col_end, group}, table<integer, table> actions by row (1-based)
function M.render(s)
  local lines, hls, actions = {}, {}, {}
  local function add(text, action)
    text = text:gsub("%s+$", "")
    table.insert(lines, text)
    actions[#lines] = action
    return #lines - 1
  end
  local function hl(row, from, to, group)
    table.insert(hls, { row, from, to, group })
  end
  local data = s.data

  -- Rows of options, measured first so every column lines up.
  local final = {} -- key -> exact JSON from tsc --showConfig
  for _, opt in ipairs(data and data.options or {}) do
    final[opt[1]] = opt[2]
  end
  local kw, vw = 0, 0
  local function measure(key, value)
    kw = math.max(kw, #key)
    vw = math.max(vw, math.min(width(value), 40))
  end
  for key, json in pairs(final) do
    measure(key, M.pretty(json))
  end
  for _, layer in ipairs(type(data and data.layers) == "table" and data.layers or {}) do
    for key, json in pairs(layer.raw) do
      measure(key, M.pretty(json))
    end
  end
  local W = math.max(56, 3 + kw + 2 + vw + 2 + 4)

  local function right(text, note)
    return pad(text .. "  ", W - width(note)) .. note
  end

  local function option_row(key, json, opts, id)
    local value = M.pretty(json)
    local left = "   " .. pad(key, kw) .. "  "
    local mid = pad(value, vw)
    local tail = opts.line and tostring(opts.line) or ""
    local text = opts.struck and (left .. value .. "  ↑ overridden") or left .. mid
    text = tail ~= "" and right(text, tail) or text
    local row = add(text, { yank = ('"%s": %s'):format(key, json), path = opts.path, line = opts.line, section = id })
    hl(row, 3, 3 + #key, "TsconfigLensKey")
    local group = opts.struck and "TsconfigLensOverridden"
      or ((json == "true" or json == "false") and "TsconfigLensBoolean" or "TsconfigLensValue")
    hl(row, #left, #left + #value, group)
    if opts.struck then
      hl(row, #left + #value, #left + #value + #"  ↑ overridden", "TsconfigLensOrigin")
    end
    if tail ~= "" then
      hl(row, #text - #tail, -1, "TsconfigLensLine")
    end
  end

  -- Sections fold like the implied line. Files start open, implied options closed.
  s.folded = s.folded or {}
  local function folded(id)
    if s.folded[id] == nil then
      return id == "implied"
    end
    return s.folded[id]
  end

  --- Adds a foldable header; returns whether its rows should be drawn.
  local function section(id, title, note, title_group)
    local mark = folded(id) and " ▸ " or " ▾ "
    local text = right(mark .. title, note)
    local row = add(text, { toggle = id, folded = folded(id) })
    hl(row, 0, #mark, "TsconfigLensHeader")
    hl(row, #mark, #mark + #title, title_group or "TsconfigLensPath")
    hl(row, #text - #note, -1, note == config.options.keymaps.toggle and "TsconfigLensLine" or "TsconfigLensOrigin")
    return not folded(id)
  end

  -- Header: the file, and where TypeScript put it.
  hl(add(" " .. rel(s.file)), 1, -1, "TsconfigLensHeader")
  local tsconfig = s.project.tsconfig
  local via = "via " .. s.project.via
  local head = " ╰─ " .. (tsconfig and rel(tsconfig) or "none · inferred project")
  local row = add(right(head, via), tsconfig and { path = tsconfig } or nil)
  hl(row, #" ╰─ ", #head, tsconfig and "TsconfigLensPath" or "TsconfigLensWarning")
  hl(row, #lines[row + 1] - #via, -1, "TsconfigLensOrigin")

  if not tsconfig then
    add("")
    hl(add("   This file is not included by any tsconfig.json."), 0, -1, "TsconfigLensWarning")
    hl(add("   TypeScript checks it with default options."), 0, -1, "TsconfigLensWarning")
    return lines, hls, actions
  end

  if s.view == "chain" then
    add("")
    local function path_line(prefix, path)
      hl(add(prefix .. rel(path), { path = path }), #prefix, -1, "TsconfigLensPath")
    end
    if data.native then
      path_line("   ", data.tsconfig)
      hl(add("   extends chain unavailable on TypeScript 7"), 0, -1, "TsconfigLensOrigin")
    elseif type(data.chain.tree) == "table" then
      local function walk(node, prefix, branch)
        path_line(prefix .. branch, node.path)
        for i, child in ipairs(node.children) do
          walk(child, branch == "" and prefix or prefix .. "  ", i == #node.children and "└ " or "├ ")
        end
      end
      walk(data.chain.tree, "   ", "")
    else
      -- TypeScript's lists did not form a tree: show what was loaded, without structure.
      for _, path in ipairs(data.chain.files) do
        path_line("   ", path)
      end
    end
    return lines, hls, actions
  end

  local origins = config.options.show_origin and s.origins or nil
  if not origins then
    -- No verified origins: one flat list, straight from tsc --showConfig.
    add("")
    local why = not config.options.show_origin and ""
      or data.native and "origins unavailable on TypeScript 7"
      or "origins unknown · see :TsconfigLens log"
    if section(data.tsconfig, rel(data.tsconfig), why) then
      for _, opt in ipairs(data.options) do
        option_row(opt[1], opt[2], {}, data.tsconfig)
      end
    end
    return lines, hls, actions
  end

  -- One section per file, closest to the file first. Each lists what that file set:
  -- the values that won, and struck out, the ones a later file overrode.
  local seen = {}
  for i = #data.layers, 1, -1 do
    local layer = data.layers[i]
    if not seen[layer.path] then
      seen[layer.path] = true
      local keys = vim.tbl_keys(layer.options)
      table.sort(keys, function(a, b)
        return (layer.lines[a] or math.huge) < (layer.lines[b] or math.huge)
      end)
      if #keys > 0 or i == #data.layers then
        add("")
        if section(layer.path, rel(layer.path), #keys .. " set") then
          for _, key in ipairs(keys) do
            local won = origins[key].path == layer.path
            local json = won and final[key] or layer.raw[key] or vim.json.encode(layer.options[key])
            option_row(key, json, { path = layer.path, line = layer.lines[key], struck = not won }, layer.path)
          end
        end
      end
    end
  end

  -- Options TypeScript reports although no file sets them.
  local implied = {}
  for _, opt in ipairs(data.options) do
    if not origins[opt[1]] then
      table.insert(implied, opt)
    end
  end
  if #implied > 0 then
    add("")
    if section("implied", #implied .. " implied by other options", config.options.keymaps.toggle, "TsconfigLensOrigin") then
      for _, opt in ipairs(implied) do
        option_row(opt[1], opt[2], {}, "implied")
      end
    end
  end
  return lines, hls, actions
end

local function open_window(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "tsconfig-lens"
  local win
  if config.options.open == "float" then
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = 1,
      height = 1,
      row = 0,
      col = 0,
      style = "minimal",
      border = "rounded",
      title = " tsconfig-lens ",
    })
  else
    vim.cmd(config.options.open == "vsplit" and "botright vsplit" or "botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  return buf, win
end

local function fit_float(win, lines)
  if config.options.open ~= "float" then
    return
  end
  local w = 20
  for _, l in ipairs(lines) do
    w = math.max(w, width(l) + 1)
  end
  w = math.min(w, vim.o.columns - 4)
  local h = math.min(#lines, vim.o.lines - 6)
  vim.api.nvim_win_set_config(win, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
  })
end

local function close(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

--- Shows plain lines (used for `:TsconfigLens log`).
function M.show_text(lines)
  lines = #lines > 0 and lines or { "(empty)" }
  local buf, win = open_window(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  fit_float(win, lines)
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", config.options.keymaps.close, function()
    close(win)
  end, { buffer = buf, nowait = true })
end

--- What the keys do on this row; shown at the bottom of the window.
function M.hint(a)
  local k = config.options.keymaps
  local parts = {}
  if a and a.toggle then
    table.insert(parts, k.jump .. (a.folded and " unfold" or " fold"))
  elseif a and a.path then
    table.insert(parts, k.jump .. " open " .. rel(a.path) .. (a.line and (":" .. a.line) or ""))
  end
  if a and a.yank then
    table.insert(parts, k.yank .. " copy")
  end
  table.insert(parts, k.close .. " close")
  return " " .. table.concat(parts, "  ·  ") .. " "
end

--- @param s table see M.render
--- @param refresh fun() re-run the lens without cache
function M.show(s, refresh)
  local buf, win = open_window({})
  local actions

  local function draw()
    local lines, hls
    lines, hls, actions = M.render(s)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      local line = lines[h[1] + 1]
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], {
        end_col = h[3] == -1 and #line or h[3],
        hl_group = h[4],
      })
    end
    vim.bo[buf].modifiable = false
    fit_float(win, lines)
  end

  local function current()
    return actions[vim.api.nvim_win_get_cursor(win)[1]]
  end

  -- Say what <CR> will do on the current row, so the jump is discoverable.
  vim.wo[win].cursorline = true
  local function update_hint()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local text = M.hint(current())
    if config.options.open == "float" then
      vim.api.nvim_win_set_config(win, { footer = text, footer_pos = "center" })
    else
      vim.wo[win].winbar = text:gsub("%%", "%%%%")
    end
  end
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = update_hint })

  draw()
  update_hint()
  -- Folds the section under the cursor (its header, or any of its rows).
  local function toggle()
    local a = current()
    local id = a and (a.toggle or a.section)
    if not id then
      return
    end
    local was_folded = s.folded[id]
    if was_folded == nil then
      was_folded = id == "implied"
    end
    s.folded[id] = not was_folded
    draw()
    -- Keep the cursor on the header that was toggled.
    for r, act in pairs(actions) do
      if act.toggle == id then
        vim.api.nvim_win_set_cursor(win, { r, 0 })
      end
    end
    update_hint()
  end

  local keys = config.options.keymaps
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map(keys.jump, function()
    local a = current()
    if a and a.toggle then
      return toggle()
    end
    if not (a and a.path) then
      return
    end
    close(win)
    vim.cmd.edit(vim.fn.fnameescape(a.path))
    if a.line then
      vim.api.nvim_win_set_cursor(0, { math.min(a.line, vim.api.nvim_buf_line_count(0)), 0 })
    end
  end)
  map(keys.toggle, toggle)
  map(keys.yank, function()
    local a = current()
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
