local util = require "tpf2_mp/util"

local M = {}

function M.new(predicate)
  assert(type(predicate) == "function", "active-record predicate is required")
  local cache = { keys = {}, result = {}, rebuilds = 0, scans = 0 }

  local function candidates(container)
    container = container or {}
    local byId, generation = container.byId or {}, tonumber(container.queued)
    if cache.byId ~= byId or cache.generation ~= generation
      or (generation == nil and cache.exhausted) then
      cache.byId, cache.generation = byId, generation
      cache.keys, cache.exhausted = util.sortedKeys(byId), false
      cache.rebuilds = cache.rebuilds + 1
    end
    if cache.exhausted then return cache.result end
    for index = #cache.result, 1, -1 do cache.result[index] = nil end
    cache.scans = cache.scans + 1
    for _, id in ipairs(cache.keys) do
      if predicate(byId[id]) then cache.result[#cache.result + 1] = id end
    end
    cache.exhausted = #cache.result == 0
    return cache.result
  end

  return {
    candidates = candidates,
    invalidate = function() cache.exhausted = false end,
    status = function() return { rebuilds = cache.rebuilds, scans = cache.scans } end,
  }
end

return M
