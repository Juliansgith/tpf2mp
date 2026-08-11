local M = {}

function M.new(deps)
  local componentEntitySet = assert(deps.componentEntitySet, "component-set reader is required")
  local balanceOf = assert(deps.balanceOf, "balance reader is required")

  local function sameEntitySet(first, second)
    for entity in pairs(first or {}) do
      if not (second or {})[entity] then return false end
    end
    for entity in pairs(second or {}) do
      if not (first or {})[entity] then return false end
    end
    return true
  end

  local function capture(types, issuerPlayerId, nativeOwnerPlayerId)
    local sets = {}
    for _, descriptor in ipairs({
      { name = "edges", component = types.BASE_EDGE, required = true },
      { name = "nodes", component = types.BASE_NODE, required = true },
      { name = "constructions", component = types.CONSTRUCTION, required = false },
      { name = "assets", component = types.ASSET_GROUP, required = false },
    }) do
      if descriptor.component ~= nil then
        local values, captureError = componentEntitySet(descriptor.component)
        if not values then return nil, captureError end
        sets[descriptor.name] = values
      elseif descriptor.required then
        return nil, descriptor.name .. " component type is unavailable"
      else
        sets[descriptor.name] = {}
      end
    end
    return {
      sets = sets,
      issuerBalance = balanceOf(issuerPlayerId),
      nativeOwnerBalance = balanceOf(nativeOwnerPlayerId),
    }
  end

  local function unchanged(before, types, issuerPlayerId, nativeOwnerPlayerId)
    local after = capture(types, issuerPlayerId, nativeOwnerPlayerId)
    if not after or before.issuerBalance ~= after.issuerBalance
      or before.nativeOwnerBalance ~= after.nativeOwnerBalance then return false end
    for _, name in ipairs({ "edges", "nodes", "constructions", "assets" }) do
      if not sameEntitySet(before.sets[name], after.sets[name]) then return false end
    end
    return true
  end

  return { capture = capture, unchanged = unchanged }
end

return M
