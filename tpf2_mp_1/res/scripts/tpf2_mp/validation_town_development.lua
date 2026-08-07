local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"

local M = {}
local ROUNDS = 3
local CALLS_PER_ROUND = 8
local SETTLE_TICKS = 90

function M.new(deps)
  assert(type(deps) == "table", "town validation dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local transition = assert(deps.transition, "transition dependency is required")
  local check = assert(deps.check, "check dependency is required")
  local submit = assert(deps.submit, "submit dependency is required")
  local checkpoint = assert(deps.checkpoint, "checkpoint dependency is required")
  local beginSoak = assert(deps.beginSoak, "beginSoak dependency is required")
  local structuralSnapshot = deps.structuralSnapshot or world.structuralSnapshot

  local function firstTownCid(state)
    for _, cid in ipairs(util.sortedKeys(state.canonical.byCanonical or {})) do
      local record = state.canonical.byCanonical[cid]
      if type(record) == "table" and record.kind == "town"
        and record.localId ~= nil then return cid end
    end
    return nil
  end

  local function townView(snapshot, townCid)
    for _, row in ipairs(snapshot and snapshot.towns or {}) do
      if row.cid == townCid then return util.deepCopy(row) end
    end
    return nil
  end

  local function submitRound(state, round)
    if state.bridge.peerId ~= "player1" then return end
    local townCid = state.validation.values.townDevelopmentCid
    local result = submit({
      type = "town.develop",
      batch = { [townCid] = CALLS_PER_ROUND },
    }, "town-development-round-" .. tostring(round) .. "-queued")
    state.validation.values.townDevelopmentLocalSeq = result and result.local_seq
  end

  local runtime = {}

  function runtime.begin(boundarySeq)
    local state = getState()
    local townCid = firstTownCid(state)
    check("town-development-manifest-binding", townCid ~= nil, {
      townCid = townCid,
      canonicalCount = util.tableCount(state.canonical.byCanonical),
    })
    local values = state.validation.values
    values.townDevelopmentCid = townCid
    values.townDevelopmentRound = 1
    values.townDevelopmentPreviousBoundary = boundarySeq
    values.townDevelopmentInitialDigest = state.probes.structural.digest
    values.townDevelopmentInitialTown = townView(state.probes.structural, townCid)
    values.townDevelopmentRounds = {}
    submitRound(state, 1)
    transition("wait-for-town-development-checkpoint")
  end

  function runtime.maintain(stage)
    local state = getState()
    local validation, values = state.validation, state.validation.values
    if stage == "wait-for-town-development-checkpoint" then
      local previousBoundary = tonumber(values.townDevelopmentPreviousBoundary) or 0
      local agreed = checkpoint(function(record)
        return record.reason == "town-development"
          and tonumber(record.boundarySeq or 0) > previousBoundary
      end)
      if not agreed then return true end
      local round = util.integer(values.townDevelopmentRound, 1)
      check("town-development-round-" .. tostring(round) .. "-checkpoint",
        agreed.success == true, agreed)
      local applied = state.probes.townDevelopment or {}
      check("town-development-round-" .. tostring(round) .. "-native-command",
        applied.towns == 1 and applied.calls == CALLS_PER_ROUND
          and applied.activated == 1 and applied.refrozen == 1
          and type(applied.errors) == "table" and #applied.errors == 0, applied)
      values.townDevelopmentPreviousBoundary = agreed.boundarySeq
      values.townDevelopmentSettleStartedTick = state.tick
      transition("wait-for-town-development-settle")
      return true
    end

    if stage == "wait-for-town-development-settle" then
      if state.tick - values.townDevelopmentSettleStartedTick < SETTLE_TICKS then return true end
      state.probes.structural = structuralSnapshot(
        state.canonical, state.world, state.companies)
      local round = util.integer(values.townDevelopmentRound, 1)
      values.townDevelopmentRounds[round] = {
        round = round,
        tick = state.tick,
        digest = state.probes.structural.digest,
        town = townView(state.probes.structural, values.townDevelopmentCid),
      }
      if round < ROUNDS then
        values.townDevelopmentRound = round + 1
        submitRound(state, round + 1)
        transition("wait-for-town-development-checkpoint")
      else
        if state.bridge.peerId == "player1" then
          local result = submit({ type = "probe.structural" },
            "post-town-structural-probe-queued")
          values.townStructuralProbeLocalSeq = result and result.local_seq
        end
        transition("wait-for-post-town-structural-checkpoint")
      end
      return true
    end

    if stage ~= "wait-for-post-town-structural-checkpoint" then return false end
    local previousBoundary = tonumber(values.townDevelopmentPreviousBoundary) or 0
    local agreed = checkpoint(function(record)
      return record.reason == "structural-probe"
        and tonumber(record.boundarySeq or 0) > previousBoundary
    end)
    if not agreed then return true end
    check("post-town-structural-checkpoint-consensus", agreed.success == true, agreed)
    state.probes.structural = structuralSnapshot(
      state.canonical, state.world, state.companies)
    values.townDevelopmentFinalDigest = state.probes.structural.digest
    values.townDevelopmentFinalTown = townView(
      state.probes.structural, values.townDevelopmentCid)
    check("ordered-town-development-changed-native-world",
      values.townDevelopmentFinalDigest ~= values.townDevelopmentInitialDigest, {
        townCid = values.townDevelopmentCid,
        initialDigest = values.townDevelopmentInitialDigest,
        finalDigest = values.townDevelopmentFinalDigest,
        initialTown = values.townDevelopmentInitialTown,
        finalTown = values.townDevelopmentFinalTown,
        rounds = values.townDevelopmentRounds,
      })
    values.townDevelopmentFinalBoundary = agreed.boundarySeq
    beginSoak(agreed.boundarySeq)
    return true
  end

  return runtime
end

return M
