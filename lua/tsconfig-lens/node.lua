-- Runs node/inspect.cjs (which uses the project's own `typescript`) and caches config results.
local config = require("tsconfig-lens.config")

local M = {}

local script = debug.getinfo(1, "S").source:sub(2):gsub("lua[/\\]tsconfig%-lens[/\\]node%.lua$", "node/inspect.cjs")

--- @param req table { mode = "project"|"config", file = string, tsconfig? = string }
--- @param cb fun(data: table|nil, err: string|nil, code: string|nil)
function M.run(req, cb)
  local node = config.options.node
  if vim.fn.executable(node) == 0 then
    return cb(nil, "node not found: set config.node", "no_node")
  end
  vim.system({ node, script, vim.json.encode(req) }, { text = true }, function(res)
    vim.schedule(function()
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(data) ~= "table" then
        config.log("inspect.cjs failed (exit " .. tostring(res.code) .. "): " .. (res.stderr or ""))
        return cb(nil, "inspect.cjs failed: see :TsconfigLens log", "internal")
      end
      if data.error then
        return cb(nil, data.error.message, data.error.code)
      end
      cb(data)
    end)
  end)
end

local cache = {}

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "missing"
end

local function fresh(entry)
  for path, m in pairs(entry.mtimes) do
    if mtime(path) ~= m then
      return false
    end
  end
  return true
end

function M.clear_cache()
  cache = {}
end

--- Effective config of `tsconfig`. Cached until any file of its extends chain changes.
function M.config(file, tsconfig, cb)
  local entry = cache[tsconfig]
  if entry and fresh(entry) then
    return cb(entry.data)
  end
  M.run({ mode = "config", file = file, tsconfig = tsconfig }, function(data, err, code)
    if not data then
      return cb(nil, err, code)
    end
    -- Without the chain (TypeScript 7) we cannot know which files to watch: never cache.
    if type(data.chain) == "table" then
      local mtimes = {}
      for _, path in ipairs(data.chain.files) do
        mtimes[path] = mtime(path)
      end
      cache[tsconfig] = { data = data, mtimes = mtimes }
    end
    cb(data)
  end)
end

return M
