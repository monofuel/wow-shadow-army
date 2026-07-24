-- Tool registry: the LLM-facing surface is named intents, never raw
-- protocol. Each tool declares its name, a one-line when-to-use, and a
-- decide(frame, args) function that returns an intent table the brain
-- translates into a typed nim_control request (or nil for "no action").
--
-- Tools may loop and react internally; goal *selection* stays in the plan
-- layer (architecture.md granularity rule).

local M = { tools = {} }

function M.register(tool)
  assert(type(tool.name) == "string" and tool.name ~= "", "tool needs a name")
  assert(type(tool.when) == "string" and tool.when ~= "", "tool needs a when-to-use line")
  assert(type(tool.decide) == "function", "tool needs decide(frame, args)")
  assert(M.tools[tool.name] == nil, "duplicate tool: " .. tool.name)
  M.tools[tool.name] = tool
  return tool
end

function M.get(name)
  return M.tools[name]
end

-- Deterministic listing for prompts and tests.
function M.names()
  local out = {}
  for name in pairs(M.tools) do out[#out + 1] = name end
  table.sort(out)
  return out
end

return M
