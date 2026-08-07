local util = require "tpf2_mp/util"

local M = {}

local PROJECTABLE = {
  construction = true,
  station_group = true,
  station = true,
  depot = true,
  asset = true,
  line = true,
  vehicle = true,
}

local PRIORITY = {
  construction = 1,
  station_group = 2,
  station = 3,
  depot = 4,
  asset = 5,
  edge_object = 6,
  line = 7,
  vehicle = 8,
  edge = 9,
}

local function companyTargets(playerIds)
  local targets, seen = {}, {}
  for index, rawPlayerId in ipairs(playerIds or {}) do
    local playerId = tonumber(rawPlayerId)
    if not playerId or playerId < 0 or playerId ~= math.floor(playerId)
      or seen[playerId] then
      return nil, "native company projection requires distinct integer player ids"
    end
    seen[playerId] = true
    targets["company:" .. tostring(index)] = playerId
  end
  return targets
end

local function bucket(report, companyCid)
  local value = report.byCompany[companyCid]
  if value then return value end
  value = { required = 0, retainedEdges = 0, projected = 0, unchanged = 0 }
  report.byCompany[companyCid] = value
  return value
end

function M.apply(worldState, playerIds, context)
  context = context or {}
  local listOwned = assert(context.listOwned, "player-owned enumerator is required")
  local ownerOf = assert(context.ownerOf, "native owner reader is required")
  local kindOf = assert(context.kindOf, "entity-kind reader is required")
  local setPlayer = assert(context.setPlayer, "native owner setter is required")
  local targets, targetError = companyTargets(playerIds)
  if not targets then return false, targetError end

  local entities, enumerationError = listOwned()
  if enumerationError then return false, tostring(enumerationError) end
  local ordered = {}
  for _, rawId in pairs(entities or {}) do
    local id = tonumber(type(rawId) == "table" and (rawId.id or rawId[1]) or rawId)
    if id and id >= 0 and id == math.floor(id) then
      ordered[#ordered + 1] = { id = id, kind = tostring(kindOf(id) or "entity") }
    end
  end
  table.sort(ordered, function(left, right)
    local leftPriority = PRIORITY[left.kind] or 50
    local rightPriority = PRIORITY[right.kind] or 50
    if leftPriority ~= rightPriority then return leftPriority < rightPriority end
    return left.id < right.id
  end)

  local report = {
    schemaVersion = 1,
    required = 0,
    retainedEdges = 0,
    projected = 0,
    unchanged = 0,
    unsupported = 0,
    failures = {},
    byCompany = {},
  }
  for _, entity in ipairs(ordered) do
    local companyCid = worldState.logicalOwners
      and worldState.logicalOwners[tostring(entity.id)] or nil
    local targetPlayerId = companyCid and targets[companyCid] or nil
    if targetPlayerId then
      local company = bucket(report, companyCid)
      report.required = report.required + 1
      company.required = company.required + 1
      if entity.kind == "edge" or entity.kind == "edge_object" then
        -- Build 35924 asserts on game.interface.setPlayer for BASE_EDGE and
        -- for edge objects such as signals. Logical custody remains
        -- authoritative and proposal replay chooses a safe native owner for
        -- later replacements.
        report.retainedEdges = report.retainedEdges + 1
        company.retainedEdges = company.retainedEdges + 1
      elseif PROJECTABLE[entity.kind] then
        local before = tonumber(ownerOf(entity.id))
        if before ~= targetPlayerId then
          local ok, value = pcall(setPlayer, entity.id, targetPlayerId)
          local after = tonumber(ownerOf(entity.id))
          if not ok or after ~= targetPlayerId then
            report.failures[#report.failures + 1] = {
              companyCid = companyCid,
              kind = entity.kind,
              error = not ok and tostring(value) or "native owner did not change",
            }
          else
            report.projected = report.projected + 1
            company.projected = company.projected + 1
          end
        else
          report.unchanged = report.unchanged + 1
          company.unchanged = company.unchanged + 1
        end
      else
        report.unsupported = report.unsupported + 1
      end
    end
  end
  if #report.failures > 0 then
    return false, report
  end
  return true, util.deepCopy(report)
end

return M
