local util = require "tpf2_mp/util"

local M = {}

function M.new()
  local cache = { keys = {}, one = {} }

  local function candidates(container, issued, accepts)
    container = container or {}
    local byId, generation = container.byId or {}, tonumber(container.queued)
    -- Current saves expose the monotonic queued generation. Unversioned test
    -- fixtures and legacy states must remain correct, so they take the old
    -- scan-on-call fallback rather than pretending an absent generation is a
    -- stable cache key.
    if cache.byId ~= byId or cache.generation ~= generation or generation == nil then
      cache.byId, cache.generation = byId, generation
      cache.keys, cache.index = util.sortedKeys(byId), 1
      cache.rebuilds = (cache.rebuilds or 0) + 1
    end
    while cache.index <= #cache.keys do
      local id = cache.keys[cache.index]
      local record = byId[id]
      if type(record) == "table" and record.status == "queued" and not issued[id]
        and (type(accepts) ~= "function" or accepts(record)) then
        cache.one[1] = id
        return cache.one
      end
      cache.index = cache.index + 1
    end
    cache.one[1] = nil
    return cache.one
  end

  return {
    candidates = candidates,
    reset = function() cache = { keys = {}, one = {} } end,
    status = function() return { rebuilds = cache.rebuilds or 0, index = cache.index or 1 } end,
  }
end

return M
