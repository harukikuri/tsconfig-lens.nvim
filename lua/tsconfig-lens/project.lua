-- Which tsconfig does the file belong to? Answered by TypeScript only.
local config = require("tsconfig-lens.config")
local node = require("tsconfig-lens.node")

local M = {}

-- LSP servers that wrap tsserver (TypeScript <= 6).
local TSSERVER = { ts_ls = true, tsserver = true, vtsls = true }
-- TypeScript 7's own language server (`tsc --lsp`).
local NATIVE = { tsgo = true }

local function request(client, method, params, bufnr, cb)
  if vim.fn.has("nvim-0.11") == 1 then
    return client:request(method, params, cb, bufnr)
  end
  return client.request(method, params, cb, bufnr)
end

local function via_lsp(bufnr, file, cb)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    local method, params, extract
    if TSSERVER[client.name] then
      method, params = "workspace/executeCommand", {
        command = "typescript.tsserverRequest",
        arguments = { "projectInfo", { file = file, needFileNameList = false } },
      }
      extract = function(res)
        local name = type(res) == "table" and type(res.body) == "table" and res.body.configFileName
        if type(name) == "string" then
          -- tsserver names inferred projects "/dev/null/inferredProjectN*".
          return { tsconfig = not vim.startswith(name, "/dev/null/") and name or nil, via = "tsserver" }
        end
      end
    elseif NATIVE[client.name] then
      method, params = "custom/projectInfo", { textDocument = { uri = vim.uri_from_fname(file) } }
      extract = function(res)
        local name = type(res) == "table" and res.configFilePath
        if type(name) == "string" then
          return { tsconfig = name ~= "" and name or nil, via = "tsgo" }
        end
      end
    end
    if method then
      local ok = request(client, method, params, bufnr, function(err, res)
        local out = not err and extract(res)
        if out then
          return cb(out)
        end
        cb(nil, client.name .. ": " .. (err and err.message or ("unexpected response " .. vim.inspect(res))))
      end)
      if not ok then
        cb(nil, client.name .. ": request failed")
      end
      return
    end
  end
  cb(nil, "no ts_ls / vtsls / tsgo client attached")
end

local function via_api(file, cb)
  node.run({ mode = "project", file = file }, function(data, err, code)
    if not data then
      return cb(nil, err, code)
    end
    cb({ tsconfig = data.project ~= vim.NIL and data.project or nil, via = "typescript API" })
  end)
end

-- Errors that tell the user what is missing; shown as-is instead of the generic message.
local SPECIFIC = { no_node = true, no_typescript = true, tsconfig_error = true }

--- @param cb fun(res: {tsconfig: string|nil, via: string}|nil, err: string|nil)
--- @param sources? string[] defaults to config.options.sources
function M.resolve(bufnr, cb, sources)
  local file = vim.api.nvim_buf_get_name(bufnr)
  sources = sources or config.options.sources
  local reasons, specific = {}, nil

  local function try(i)
    local src = sources[i]
    if not src then
      for _, r in ipairs(reasons) do
        config.log("project: " .. r)
      end
      return cb(nil, specific or "could not determine the project")
    end
    local function next_source(res, err, code)
      if res then
        return cb(res)
      end
      table.insert(reasons, src .. ": " .. err)
      if SPECIFIC[code] then
        specific = err
      end
      try(i + 1)
    end
    if src == "tsserver" then
      via_lsp(bufnr, file, next_source)
    elseif src == "api" then
      via_api(file, next_source)
    else
      next_source(nil, "unknown source")
    end
  end

  try(1)
end

return M
