-- nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local tests_dir = root .. "/tests"
local fx = tests_dir .. "/fixtures"
vim.opt.rtp:prepend(root)
vim.cmd.cd(root)
vim.cmd.runtime("plugin/tsconfig-lens.lua")
vim.cmd("filetype on")

local lens = require("tsconfig-lens")
local config = require("tsconfig-lens.config")
local node = require("tsconfig-lens.node")
local origin = require("tsconfig-lens.origin")
local project = require("tsconfig-lens.project")
local ui = require("tsconfig-lens.ui")

local failures, total = 0, 0
local function out(s)
  io.stdout:write(s .. "\n")
end

local function reset()
  config.setup({ sources = { "api" } })
  config.logs = {}
  node.clear_cache()
  vim.cmd("silent! %bwipeout!")
end

local function test(name, fn)
  total = total + 1
  reset()
  local ok, e = xpcall(fn, debug.traceback)
  out((ok and "ok    " or "FAIL  ") .. name)
  if not ok then
    failures = failures + 1
    out(e)
  end
end

local function eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(("%s\nexpected: %s\nactual:   %s"):format(msg or "not equal", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

--- Runs an async function `start(done)` and returns what was passed to `done`.
local function await(start)
  local res
  start(function(...)
    res = { ... }
  end)
  assert(vim.wait(30000, function()
    return res ~= nil
  end, 20), "timeout")
  return unpack(res)
end

local function buf_for(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function resolve(path)
  return await(function(done)
    project.resolve(buf_for(path), done)
  end)
end

local function inspect_config(file, tsconfig)
  return await(function(done)
    node.config(file, tsconfig, done)
  end)
end

-- Files and the tsconfig TypeScript should report for them (nil = inferred project).
local cases = {
  { "simple/src/index.ts", "simple/tsconfig.json" },
  { "chain3/src/page.tsx", "chain3/tsconfig.json" },
  { "chain3/scripts/seed.ts", nil },
  { "pkgext/src/index.ts", "pkgext/tsconfig.json" },
  { "array/src/index.ts", "array/tsconfig.json" },
  { "configdir/app/src/index.ts", "configdir/app/tsconfig.json" },
  { "solution/packages/lib/src/index.ts", "solution/packages/lib/tsconfig.json" },
  { "solution/app/main.ts", "solution/tsconfig.app.json" },
  { "ts7/src/index.ts", "ts7/tsconfig.json" },
  -- "typescript": "npm:@typescript/typescript6": the tsc bin is named tsc6.
  { "alias/src/index.ts", "alias/tsconfig.json" },
}
local configs = { "simple", "chain3", "pkgext", "array", "configdir/app", "solution/packages/lib", "alias" }

---------------------------------------------------------------- project (API)

test("api: each fixture resolves to the right tsconfig", function()
  for _, c in ipairs(cases) do
    local res, err = resolve(fx .. "/" .. c[1])
    assert(res, err)
    eq(res.tsconfig, c[2] and (fx .. "/" .. c[2]) or nil, c[1])
    eq(res.via, "typescript API")
  end
end)

---------------------------------------------------------------- project (LSP)

local function with_lsp(name, cmd, init_options, files)
  config.setup({ sources = { "tsserver" } })
  for _, c in ipairs(files) do
    local path = fx .. "/" .. c[1]
    local buf = buf_for(path)
    local id = vim.lsp.start({ name = name, cmd = cmd, root_dir = fx .. "/" .. c[1]:match("^[^/]+"), init_options = init_options }, { bufnr = buf })
    assert(vim.wait(20000, function()
      local client = vim.lsp.get_client_by_id(id)
      return client and client.initialized
    end, 50), name .. " did not start")
    local res, err
    -- The server may need a moment to load the project after didOpen.
    vim.wait(20000, function()
      res, err = await(function(done)
        project.resolve(buf, done)
      end)
      return res ~= nil
    end, 200)
    assert(res, err)
    local api = await(function(done)
      config.setup({ sources = { "api" } })
      project.resolve(buf, done)
      config.setup({ sources = { "tsserver" } })
    end)
    eq(res.tsconfig, api.tsconfig, name .. " vs api: " .. c[1])
    eq(res.tsconfig, c[2] and (fx .. "/" .. c[2]) or nil, c[1])
  end
  for _, client in ipairs(vim.lsp.get_clients()) do
    client:stop(true)
  end
end

test("tsserver (typescript-language-server) agrees with the API", function()
  with_lsp("ts_ls", { tests_dir .. "/node_modules/.bin/typescript-language-server", "--stdio" }, {
    tsserver = { path = tests_dir .. "/node_modules/typescript/lib" },
  }, { cases[2], cases[3], cases[8] })
end)

test("tsgo (TypeScript 7 LSP) agrees with the API", function()
  with_lsp("tsgo", { fx .. "/ts7/node_modules/.bin/tsc", "--lsp", "--stdio" }, nil, { cases[9] })
end)

---------------------------------------------------------------- effective config

test("config: values are exactly tsc --showConfig", function()
  for _, dir in ipairs(configs) do
    local tsconfig = fx .. "/" .. dir .. "/tsconfig.json"
    local data, err = inspect_config(tsconfig, tsconfig)
    assert(data, err)
    local tsc = tests_dir .. "/node_modules/typescript/bin/tsc"
    local r = vim.system({ "node", tsc, "--showConfig", "-p", tsconfig }, { text = true }):wait()
    local expected = vim.json.decode(r.stdout).compilerOptions
    local got = {}
    for _, opt in ipairs(data.options) do
      got[opt[1]] = vim.json.decode(opt[2])
    end
    eq(got, expected, dir)
  end
end)

---------------------------------------------------------------- origins

test("origin: self-check passes on every fixture", function()
  for _, dir in ipairs(configs) do
    local tsconfig = fx .. "/" .. dir .. "/tsconfig.json"
    local data = assert(inspect_config(tsconfig, tsconfig))
    local o, bad = origin.compute(data)
    assert(o, dir .. ": mismatch " .. vim.inspect(bad))
  end
end)

test("origin: last writer wins along the chain", function()
  local c3 = fx .. "/chain3"
  local o = origin.compute(assert(inspect_config(c3 .. "/tsconfig.json", c3 .. "/tsconfig.json")))
  eq(o.strict, { path = c3 .. "/configs/base.json", line = 3 })
  eq(o.moduleResolution, { path = c3 .. "/configs/base.json", line = 5 })
  eq(o.jsx, { path = c3 .. "/configs/react.json", line = 4 })
  eq(o.paths, { path = c3 .. "/tsconfig.json", line = 5 })
  eq(o.noUncheckedIndexedAccess, { path = c3 .. "/tsconfig.json", line = 6 })

  local arr = fx .. "/array"
  o = origin.compute(assert(inspect_config(arr .. "/tsconfig.json", arr .. "/tsconfig.json")))
  eq(o.strict, { path = arr .. "/b.json", line = 3 }, "later array entry wins")
  eq(o.target, { path = arr .. "/a.json", line = 4 })

  local pkg = fx .. "/pkgext"
  o = origin.compute(assert(inspect_config(pkg .. "/tsconfig.json", pkg .. "/tsconfig.json")))
  eq(o.declaration, { path = pkg .. "/tsconfig.json", line = 4 })
  eq(o.strict, { path = pkg .. "/node_modules/@acme/tsconfig/base.json", line = 3 })
end)

test("origin: a mismatch makes every origin unknown and is logged", function()
  local c3 = fx .. "/chain3/tsconfig.json"
  local data = vim.deepcopy(assert(inspect_config(c3, c3)))
  data.final.jsx = 1 -- pretend TypeScript reported something else
  local o, bad = origin.compute(data)
  eq(o, nil)
  eq(bad, { "jsx" })
  assert(config.logs[#config.logs]:find("jsx"), "mismatch not logged")
  local lines = ui.render({ file = c3, project = { tsconfig = c3, via = "typescript API" }, data = data, origins = o })
  assert(lines[4]:match("origins unknown · see :TsconfigLens log$"), lines[4])
  assert(vim.tbl_contains(lines, "   strict                    true"), vim.inspect(lines))
end)

test("chain: tree for 3 levels, flat siblings for an array", function()
  local c3 = fx .. "/chain3/tsconfig.json"
  local data = assert(inspect_config(c3, c3))
  eq(data.chain.tree, {
    path = c3,
    children = {
      {
        path = fx .. "/chain3/configs/react.json",
        children = { { path = fx .. "/chain3/configs/base.json", children = {} } },
      },
    },
  })
  local arr = fx .. "/array/tsconfig.json"
  data = assert(inspect_config(arr, arr))
  eq(#data.chain.tree.children, 2)
end)

---------------------------------------------------------------- cache

test("cache: saving a file in the chain gives the new value", function()
  local tmp = tests_dir .. "/.tmp-cache"
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.writefile({ '{ "compilerOptions": { "target": "es2020" } }' }, tmp .. "/base.json")
  vim.fn.writefile({ '{ "extends": "./base.json" }' }, tmp .. "/tsconfig.json")
  vim.fn.writefile({ "export {}" }, tmp .. "/src/a.ts")
  local ok, e = pcall(function()
    local tsconfig = tmp .. "/tsconfig.json"
    local function target()
      for _, opt in ipairs(assert(inspect_config(tsconfig, tsconfig)).options) do
        if opt[1] == "target" then
          return opt[2]
        end
      end
    end
    eq(target(), '"es2020"')
    eq(target(), '"es2020"') -- served from cache
    vim.fn.writefile({ '{ "compilerOptions": { "target": "es2022" } }' }, tmp .. "/base.json")
    local t = os.time() + 5
    vim.uv.fs_utime(tmp .. "/base.json", t, t)
    eq(target(), '"es2022"')
  end)
  vim.fn.delete(tmp, "rf")
  assert(ok, e)
end)

---------------------------------------------------------------- errors

local function open_error(path, opts)
  if opts then
    config.setup(opts)
  end
  local msg
  local notify = vim.notify
  vim.notify = function(m)
    msg = m
  end
  buf_for(path)
  lens.open()
  vim.wait(30000, function()
    return msg ~= nil
  end, 20)
  vim.notify = notify
  return msg
end

test("error: node not found", function()
  eq(open_error(fx .. "/simple/src/index.ts", { node = "no-such-node-binary" }), "tsconfig-lens: node not found: set config.node")
end)

test("error: typescript is not installed", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "export {}" }, dir .. "/a.ts")
  eq(open_error(dir .. "/a.ts"), "tsconfig-lens: typescript is not installed in this project")
  vim.fn.delete(dir, "rf")
end)

test("error: tsconfig syntax error is TypeScript's message", function()
  local msg = open_error(fx .. "/broken/src/index.ts")
  assert(msg and msg:find("error TS5024: Compiler option 'strict' requires a value of type boolean.", 1, true), msg)
end)

test("error: not a TypeScript/JavaScript file", function()
  eq(open_error(root .. "/README.md"), "tsconfig-lens: not a TypeScript/JavaScript file")
end)

test("error: could not determine the project", function()
  eq(open_error(fx .. "/simple/src/index.ts", { sources = { "tsserver" } }), "tsconfig-lens: could not determine the project")
  assert(config.logs[1]:find("no ts_ls"), "reason not logged")
end)

---------------------------------------------------------------- UI

local function open_lens(path, view)
  buf_for(path)
  lens.open(view)
  assert(vim.wait(30000, function()
    return vim.bo.filetype == "tsconfig-lens"
  end, 20), "lens did not open")
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

test("ui: <CR> on an option jumps to where it was set", function()
  local lines = open_lens(fx .. "/chain3/src/page.tsx")
  for i, l in ipairs(lines) do
    if l:match("^   jsx ") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
  -- The footer says what <CR> does on this row.
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
  local footer = vim.api.nvim_win_get_config(0).footer
  footer = type(footer) == "table" and table.concat(vim.tbl_map(function(c)
    return c[1]
  end, footer)) or footer
  eq(footer, " <CR> open tests/fixtures/chain3/configs/react.json:4  ·  y copy  ·  q close ")
  vim.cmd('exe "normal \\<CR>"')
  eq(vim.api.nvim_buf_get_name(0), fx .. "/chain3/configs/react.json")
  eq(vim.api.nvim_win_get_cursor(0)[1], 4)
end)

test("ui: inferred project, chain view and TypeScript 7", function()
  local lines = open_lens(fx .. "/chain3/scripts/seed.ts")
  assert(lines[2]:match("^ ╰─ none · inferred project  +via typescript API$"), lines[2])
  eq(lines[4], "   This file is not included by any tsconfig.json.")

  vim.cmd("close")
  lines = open_lens(fx .. "/chain3/src/page.tsx", "chain")
  eq(vim.list_slice(lines, 4), {
    "   tests/fixtures/chain3/tsconfig.json",
    "   └ tests/fixtures/chain3/configs/react.json",
    "     └ tests/fixtures/chain3/configs/base.json",
  })

  vim.cmd("close")
  lines = open_lens(fx .. "/ts7/src/index.ts")
  assert(lines[4]:match("origins unavailable on TypeScript 7$"), vim.inspect(lines))
end)

test("ui: sections per file, overridden values, implied options fold", function()
  local lines = open_lens(fx .. "/array/src/index.ts")
  local function find(pattern)
    for i, l in ipairs(lines) do
      if l:match(pattern) then
        return i
      end
    end
  end
  local b, a = find("^ ▾ tests/fixtures/array/b.json +1 set$"), find("^ ▾ tests/fixtures/array/a.json +2 set$")
  assert(b and a and b < a, "closest file first: " .. vim.inspect(lines))
  assert(lines[b + 1]:match("^   strict +false +3$"), lines[b + 1])
  assert(lines[a + 1]:match("^   strict +true  ↑ overridden +3$"), lines[a + 1])

  local fold = find("^ ▸ 10 implied by other options")
  assert(fold, vim.inspect(lines))
  eq(#lines, fold)
  vim.api.nvim_win_set_cursor(0, { fold, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(lines[fold]:match("^ ▾ 10 implied"), lines[fold])
  eq(#lines, fold + 10)
  assert(lines[fold + 1]:match("^   module +es2020$"), lines[fold + 1])

  -- <Tab> on an option row folds its file section; again on the header opens it.
  vim.api.nvim_win_set_cursor(0, { a + 2, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(lines[a]:match("^ ▸ tests/fixtures/array/a.json +2 set$"), lines[a])
  eq(lines[a + 1], "")
  eq(vim.api.nvim_win_get_cursor(0)[1], a)
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(lines[a + 2]:match("^   target +es2020 +4$"), lines[a + 2])
end)

test("ui: pretty values stay lossless", function()
  eq(ui.pretty('"es2022"'), "es2022")
  eq(ui.pretty('["dom","es2022"]'), "dom · es2022")
  eq(ui.pretty('{"@/*":["./src/*"],"~/*":["./a/*","./b/*"]}'), "@/* → ./src/*   ~/* → ./a/*, ./b/*")
  eq(ui.pretty("true"), "true")
  eq(ui.pretty("[]"), "[]")
  eq(ui.pretty('[1,"a"]'), '[1,"a"]')
end)

test("status: tsconfig, inferred, or empty", function()
  lens.setup({ sources = { "api" } })
  local buf = buf_for(fx .. "/chain3/src/page.tsx")
  vim.wait(30000, function()
    return lens.status(buf) ~= ""
  end, 20)
  eq(lens.status(buf), "tests/fixtures/chain3/tsconfig.json")
  buf = buf_for(fx .. "/chain3/scripts/seed.ts")
  vim.wait(30000, function()
    return lens.status(buf) ~= ""
  end, 20)
  eq(lens.status(buf), "inferred")
  eq(lens.status(buf_for(root .. "/README.md")), "")
  vim.api.nvim_clear_autocmds({ group = "tsconfig-lens" })
end)

out(("\n%d/%d passed"):format(total - failures, total))
os.exit(failures > 0 and 1 or 0)
