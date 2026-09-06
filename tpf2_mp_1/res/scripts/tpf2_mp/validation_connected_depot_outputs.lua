local M = {}

function M.complete(outputs, compoundTownRoad)
  local wanted = {
    ["construction:construction:1"] = true, ["depot:depot:1"] = true,
    ["edge:edge:1"] = true, ["node:node:1"] = true,
    ["edge:edge:helper:1"] = true, ["node:node:helper:1"] = true,
  }
  if compoundTownRoad then
    for _, key in ipairs({ "edge:edge:2", "edge:edge:3", "node:node:2" }) do
      wanted[key] = true
    end
    wanted["edge:edge:helper:1"] = nil
    wanted["node:node:helper:1"] = nil
  end
  for _, item in ipairs(outputs or {}) do
    wanted[tostring(item.kind) .. ":" .. tostring(item.slot)] = nil
  end
  return #(outputs or {}) == (compoundTownRoad and 7 or 6)
    and next(wanted) == nil
end

return M
