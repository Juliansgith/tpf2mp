local M = {}

function M.new(deps)
  local canonical = assert(deps.canonical, "canonical dependency is required")
  local world = assert(deps.world, "world dependency is required")
  local getState = assert(deps.getState, "state provider is required")

  return function(localId, expectedKind, companyCid)
    local state = getState()
    localId = tonumber(localId)
    if not localId then
      return nil, "operation capture is missing a local " .. expectedKind
    end
    local actualKind = world.kindOf(localId)
    if expectedKind ~= "entity" and actualKind ~= expectedKind then
      return nil, "selected object is " .. tostring(actualKind)
        .. ", expected " .. expectedKind
    end

    -- Network captures are peer-local until ordered. Resolve without binding
    -- first so rejection leaves the canonical digest unchanged.
    local cid = canonical.resolveCanonical(state.canonical, actualKind, localId)
    local bindError
    -- Standalone/hot-seat has no peer-local divergence and retains the former
    -- duplicate-decoration behavior. The purity fence is a network boundary.
    if not cid and state.networkMode ~= "network" then
      cid, bindError = world.bindExisting(state.canonical, localId, actualKind)
    end
    if not cid then
      cid, bindError = world.identifyExisting(state.canonical, localId, actualKind)
    end
    if not cid then return nil, bindError end

    local binding = state.canonical.byCanonical[cid]
    if state.networkMode == "network" and cid:find(":pre:", 1, true)
      and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
      return nil, "selected pre-existing object is ambiguous across peers"
    end
    local owner = world.logicalOwnerOf(state.world, state.companies, localId)
      or (binding and binding.metadata and binding.metadata.owner or nil)
    if owner and owner ~= companyCid then
      return nil, "operation cannot mutate rival-owned "
        .. tostring(expectedKind) .. " " .. tostring(cid)
    end

    if not binding then
      cid, bindError = world.bindExisting(state.canonical, localId, actualKind)
      if not cid then return nil, bindError end
    end
    return cid
  end
end

return M
