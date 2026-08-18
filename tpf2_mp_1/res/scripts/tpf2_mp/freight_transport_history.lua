local util = require "tpf2_mp/util"

local M = {}

function M.reconcile(schema, saved, activeTransported, activeDelivered, deps)
  local totalTransported, transportedError = deps.counterMap(
    saved.totalTransported, "saved total transported")
  if not totalTransported then return nil, transportedError end
  local totalDelivered, deliveredError = deps.counterMap(
    saved.totalDelivered, "saved total delivered")
  if not totalDelivered then return nil, deliveredError end
  local retiredTransported, retiredDelivered = {}, {}
  if schema >= 3 then
    local retiredError
    retiredTransported, retiredError = deps.counterMap(
      saved.retiredTransported, "saved retired transported")
    if not retiredTransported then return nil, retiredError end
    retiredDelivered, retiredError = deps.counterMap(
      saved.retiredDelivered, "saved retired delivered")
    if not retiredDelivered then return nil, retiredError end
  else
    for cargo, count in pairs(totalTransported) do
      if count < (activeTransported[cargo] or 0) then
        return nil, "saved transported totals are below active cursors"
      end
      if count > (activeTransported[cargo] or 0) then
        retiredTransported[cargo] = count - (activeTransported[cargo] or 0)
      end
    end
    for cargo, count in pairs(totalDelivered) do
      if count < (activeDelivered[cargo] or 0) then
        return nil, "saved delivered totals are below active cursors"
      end
      if count > (activeDelivered[cargo] or 0) then
        retiredDelivered[cargo] = count - (activeDelivered[cargo] or 0)
      end
    end
  end
  local reconstructedTransported, reconstructedDelivered =
    util.deepCopy(activeTransported), util.deepCopy(activeDelivered)
  for cargo, count in pairs(retiredTransported) do
    deps.add(reconstructedTransported, cargo, count)
  end
  for cargo, count in pairs(retiredDelivered) do
    deps.add(reconstructedDelivered, cargo, count)
  end
  if not deps.same(reconstructedTransported, totalTransported)
      or not deps.same(reconstructedDelivered, totalDelivered) then
    return nil, "saved freight transport totals disagree with cursors"
  end
  return { totalTransported = totalTransported, totalDelivered = totalDelivered,
    retiredTransported = retiredTransported, retiredDelivered = retiredDelivered }
end

return M
