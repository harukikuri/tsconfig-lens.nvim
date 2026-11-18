-- Where was each option set? This is the plugin's only own computation, so it is
-- checked against TypeScript's final options every time and dropped on any mismatch.
local config = require("tsconfig-lens.config")

local M = {}

--- @param data table result of inspect.cjs `config` mode
--- @return table<string, {path: string, line: integer|nil}>|nil origins, string[]|nil mismatched keys
function M.compute(data)
  if type(data.layers) ~= "table" then
    return nil
  end
  local stacked, from = {}, {}
  for _, layer in ipairs(data.layers) do
    for key, value in pairs(layer.options) do
      stacked[key] = value
      from[key] = layer
    end
  end

  local bad = {}
  for key, value in pairs(stacked) do
    if not vim.deep_equal(value, data.final[key]) then
      table.insert(bad, key)
    end
  end
  if #bad > 0 then
    table.sort(bad)
    config.log("origin self-check failed for " .. data.tsconfig .. ": " .. table.concat(bad, ", "))
    return nil, bad
  end

  local origins = {}
  for key, layer in pairs(from) do
    origins[key] = { path = layer.path, line = layer.lines[key] }
  end
  return origins
end

return M
