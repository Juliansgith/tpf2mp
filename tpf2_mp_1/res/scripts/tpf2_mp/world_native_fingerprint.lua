local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

local M = { SCHEMA_VERSION = 3 }

local CATEGORY = {
  node = "edges", edge = "edges", edge_object = "edges",
  construction = "constructions", asset = "constructions",
  station = "constructions", station_group = "constructions", depot = "constructions",
  line = "vehicles", vehicle = "vehicles",
  town = "autonomous", industry = "autonomous",
}

function M.new(deps)
  local entityExists = assert(deps.entityExists, "entityExists dependency is required")
  local fingerprint = assert(deps.fingerprint, "fingerprint dependency is required")
  local topologyFingerprint = assert(deps.topologyFingerprint,
    "topologyFingerprint dependency is required")
  local listTowns = assert(deps.listTowns, "listTowns dependency is required")
  local listIndustries = assert(deps.listIndustries, "listIndustries dependency is required")
  local townCapacity = assert(deps.townCapacity, "townCapacity dependency is required")
  local listKind = deps.listKind
  local kindOf = deps.kindOf
  local ownerOf = deps.ownerOf
  local resolveCanonical = deps.resolveCanonical
  local vehicleLine = deps.vehicleLine
  local lineDescriptor = assert(deps.lineDescriptor,
    "lineDescriptor dependency is required")

  local inventoryKinds = {
    edges = { "node", "edge", "edge_object" },
    constructions = { "construction", "asset", "station", "station_group", "depot" },
    vehicles = { "line", "vehicle" },
  }

  local function nativeOwnerCid(registry, companies, localId)
    if type(ownerOf) ~= "function" then return nil end
    local nativeOwner = ownerOf(localId)
    if nativeOwner == nil then return nil end
    if type(resolveCanonical) == "function" then
      local cid = resolveCanonical(registry, "company", nativeOwner)
      if cid then return cid end
    end
    for companyCid, company in pairs(companies or {}) do
      if tonumber(company and company.playerId) == tonumber(nativeOwner) then return companyCid end
    end
    return "unbound-native-owner"
  end

  local function sampleInventory()
    if type(listKind) ~= "function" then return nil end
    local inventory = { counts = {}, geometry = {} }
    local edgeIds = listKind("edge")
    if type(edgeIds) ~= "table" then return nil end
    for category, kinds in pairs(inventoryKinds) do
      inventory.counts[category] = {}
      for _, kind in ipairs(kinds) do
        local ids
        if kind == "edge_object" and type(deps.listInventoryEdgeObjects) == "function" then
          ids = deps.listInventoryEdgeObjects(edgeIds)
        elseif kind == "edge" then
          ids = edgeIds
        else
          ids = listKind(kind)
        end
        -- An unavailable/partial read is not an empty, complete inventory.
        if type(ids) ~= "table" then return nil end
        inventory.counts[category][kind] = #ids
        if kind == "node" or kind == "edge" then
          local values = {}
          for _, localId in ipairs(ids) do
            values[#values + 1] = tostring(fingerprint(
              localId, kind, { componentOnly = true }) or "unavailable")
          end
          table.sort(values)
          inventory.geometry[kind] = hash.value(values)
        end
      end
    end
    return inventory
  end

  local function sample(registry, worldState, companies, options)
    options = options or {}
    local categories = {
      edges = {}, constructions = {}, vehicles = {}, autonomous = {}, other = {},
    }
    local counts = { edges = 0, constructions = 0, vehicles = 0, autonomous = 0, other = 0 }
    for _, cid in ipairs(util.sortedKeys(registry.byCanonical or {})) do
      local binding = registry.byCanonical[cid]
      local kind = tostring(binding.kind or "other")
      local category = CATEGORY[kind] or "other"
      local metadata = binding.metadata or {}
      local exists = entityExists(binding.localId)
      local nativeFingerprint, attestedFingerprint
      if exists then
        if metadata.nativeReadUnsafe == true then
          -- proposalOutputFingerprint is an ordering token
          -- (proposalDigest:kind:slot), not an observable world identity. It
          -- must never masquerade as an attested native fingerprint: no live
          -- candidate can reproduce it and topology fallback cannot rebind by
          -- it. Exact construction capture supplies a real ordinary/topology
          -- fingerprint when safe; otherwise the binding remains explicitly
          -- non-portable and the full inventory tier still detects residue.
          attestedFingerprint = metadata.topologyFingerprint
            or metadata.fingerprint
        elseif kind == "line" then
          -- A LINE component stores engine-local station-group ids. The
          -- generic fingerprint replaces those ids with station names and
          -- positions, but native auto-naming/position projection is cosmetic
          -- and can differ across otherwise equivalent peers. Hash the actual
          -- native stop order after translating each group through the
          -- canonical registry instead. This still detects missing, reordered,
          -- or wrongly targeted stops and terminals without making generated
          -- presentation text part of consensus.
          nativeFingerprint = hash.value({
            kind = "line",
            descriptor = lineDescriptor(binding.localId, registry),
          })
        elseif category == "edges" or category == "constructions" then
          nativeFingerprint = topologyFingerprint(binding.localId, kind, {
            registry = registry, worldState = worldState, ownerCid = metadata.owner,
          }) or fingerprint(binding.localId, kind, { componentOnly = true })
        else
          nativeFingerprint = fingerprint(binding.localId, kind, { componentOnly = true })
        end
      end
      categories[category][#categories[category] + 1] = {
        cid = cid, kind = kind, exists = exists and true or false,
        fingerprint = nativeFingerprint,
        attestedFingerprint = attestedFingerprint,
        nativeReadUnsafe = metadata.nativeReadUnsafe == true,
        observedKind = exists and type(kindOf) == "function"
          and kindOf(binding.localId, { componentOnly = true }) or nil,
        logicalOwner = worldState and worldState.logicalOwners
          and worldState.logicalOwners[tostring(binding.localId)] or metadata.owner,
        nativeOwner = exists and nativeOwnerCid(registry, companies, binding.localId) or nil,
        lineCid = exists and kind == "vehicle" and type(vehicleLine) == "function"
          and vehicleLine(binding.localId, registry) or nil,
      }
      counts[category] = counts[category] + 1
    end

    -- Autonomous entities need not be operationally bound yet. Include a
    -- stable multiset so silent town/industry creation, removal, or capacity
    -- drift appears in the cheap tier without mutating the canonical registry.
    local towns = {}
    for _, townId in ipairs(listTowns()) do
      local total, capacities = townCapacity(townId)
      towns[#towns + 1] = {
        fingerprint = fingerprint(townId, "town", { componentOnly = true }),
        total = util.integer(total, 0),
        capacities = {
          util.integer(capacities and capacities[1], 0),
          util.integer(capacities and capacities[2], 0),
          util.integer(capacities and capacities[3], 0),
        },
      }
    end
    table.sort(towns, function(a, b) return hash.value(a) < hash.value(b) end)
    local industries = {}
    for _, industryId in ipairs(listIndustries()) do
      industries[#industries + 1] = tostring(fingerprint(
        industryId, "industry", { componentOnly = true }) or "unavailable")
    end
    table.sort(industries)
    categories.autonomous[#categories.autonomous + 1] = {
      inventory = true, towns = towns, industries = industries,
    }
    counts.autonomous = counts.autonomous + #towns + #industries

    -- The ordinary checkpoint tier stays binding-focused and cheap. Ordered
    -- native/full probes periodically enumerate the whole native inventory.
    -- Never carry an old inventory forward as if it had just been observed:
    -- stale evidence could conceal new unbound residue between full probes.
    local inventory = options.fullInventory == true and sampleInventory() or nil
    if inventory then
      for category, values in pairs(inventory.counts or {}) do
        categories[category][#categories[category] + 1] = {
          inventory = true,
          counts = util.deepCopy(values),
          geometry = category == "edges" and util.deepCopy(inventory.geometry) or nil,
        }
      end
    end

    local categoryDigests = {}
    for _, category in ipairs({ "edges", "constructions", "vehicles", "autonomous", "other" }) do
      categoryDigests[category] = hash.value(categories[category])
    end
    local result = {
      schemaVersion = M.SCHEMA_VERSION,
      categories = categoryDigests,
      counts = counts,
      inventory = inventory,
      inventoryComplete = inventory ~= nil,
    }
    result.digest = hash.value(result)
    return result
  end

  return { sample = sample }
end

return M
