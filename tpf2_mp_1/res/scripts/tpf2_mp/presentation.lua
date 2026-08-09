local util = require "tpf2_mp/util"
local nativeCommandAuthority = require "tpf2_mp/native_command_authority"

-- Agent presentation policy.
--
-- The competitive model owns demand, allocation, revenue, and score. Native
-- sim agents are decoration: they are never read as market truth and never
-- scored. This module decides how much of that decoration each match keeps.
--
-- Vanilla simulates the entire region population continuously, and community
-- measurement puts lag onset near 30k sims and unplayability near 75-150k,
-- single-thread bound. Scaling town-building person capacity is the lever the
-- ecosystem already uses (the public Capacity Factor mod applies the same
-- multiplier through a loadConstruction modifier).
--
-- Every value here is match content: it changes building data and therefore
-- the structural digest, so peers must run identical policy. The fingerprint
-- helper below is what the match pack compares.
local M = {}

M.MODES = {
  -- Full vanilla population. Highest fidelity, highest cost, and the only
  -- mode where native dwell varies with real boarding.
  vanilla = {
    label = "vanilla",
    capacityNumerator = 1,
    capacityDenominator = 1,
    capacityFloor = 1,
    pinLoadSpeed = false,
    simulateCargoWeight = true,
    destinationRecomputationPermille = 1000,
  },
  -- Recommended. One inhabitant per town building keeps platforms, streets
  -- and vehicles visibly alive at roughly a tenth of the simulation cost,
  -- while the model carries the real passenger volumes.
  skeleton = {
    label = "skeleton",
    capacityNumerator = 1,
    capacityDenominator = 64,
    capacityFloor = 1,
    pinLoadSpeed = true,
    simulateCargoWeight = false,
    destinationRecomputationPermille = 250,
  },
  -- Minimum safe crowd. Build 35924 fatally asserts while generating a town
  -- building whose PersonCapacity component is removed by a literal zero.
  -- Keep one capacity slot on every otherwise populated building instead;
  -- disabling destination recomputation still makes this the cheapest mode.
  empty = {
    label = "empty",
    capacityNumerator = 1,
    capacityDenominator = 1000000000,
    capacityFloor = 1,
    pinLoadSpeed = true,
    simulateCargoWeight = false,
    destinationRecomputationPermille = 0,
  },
}

M.DEFAULT_MODE = "skeleton"

-- Pinned load speed for every transport vehicle when the mode asks for it.
-- Dwell then stops depending on how many agents happen to board, which is
-- what makes the model's fixed per-stop dwell an exact statement about the
-- world rather than an approximation of it.
M.PINNED_LOAD_SPEED = 1000

function M.mode(name)
  return M.MODES[tostring(name or "")] or M.MODES[M.DEFAULT_MODE]
end

-- Deterministic integer scaling shared by the data modifier and any runtime
-- application, so both produce the same number for the same input.
function M.scaledCapacity(capacity, policy)
  policy = policy or M.mode(M.DEFAULT_MODE)
  local base = math.max(0, util.integer(capacity, 0))
  if policy.capacityDenominator <= 1 and policy.capacityNumerator == 1 then return base end
  local scaled = math.floor(base * policy.capacityNumerator / policy.capacityDenominator)
  if base > 0 and scaled < policy.capacityFloor then scaled = policy.capacityFloor end
  return math.max(0, scaled)
end

-- Match content identity. Two peers whose agent policy differs would build
-- different worlds from the same commands, so this belongs in the pinned
-- match fingerprint next to the mod set.
-- Applies the policy to a world that already exists.
--
-- The data modifier only reaches buildings created after it loads, so a
-- pre-existing save keeps its original population. `setTownInfo` is the
-- runtime lever for those towns; its exact effect on Build 35924 is
-- unestablished, so this applies, reads back, and records what actually
-- happened rather than assuming. The readback is the probe.
function M.applyToWorld(worldState, policy, deps)
  local outcome = {
    mode = policy.label,
    fingerprint = M.fingerprint(policy),
    towns = 0, applied = 0, verified = 0, unchanged = 0, errors = {},
    before = {}, after = {},
  }
  if policy.capacityDenominator <= 1 and policy.capacityNumerator == 1 then
    outcome.skipped = "policy keeps the vanilla population"
    return outcome
  end
  local factory = util.commandFactory("setTownInfo")
  if not factory then
    outcome.errors[#outcome.errors + 1] = "setTownInfo command factory is unavailable"
    return outcome
  end
  for _, townId in ipairs(deps.listTowns()) do
    outcome.towns = outcome.towns + 1
    local total, capacities = deps.townCapacity(townId)
    local target = {
      M.scaledCapacity(capacities[1], policy),
      M.scaledCapacity(capacities[2], policy),
      M.scaledCapacity(capacities[3], policy),
    }
    outcome.before[#outcome.before + 1] = total
    if target[1] == capacities[1] and target[2] == capacities[2]
      and target[3] == capacities[3] then
      outcome.unchanged = outcome.unchanged + 1
    else
      local made, commandOrError = pcall(factory, townId, target)
      local ok, err = false, commandOrError
      if made then
        ok, err = nativeCommandAuthority.send(
          20, commandOrError, nil, "mod.world.agent-policy")
      end
      if ok then
        outcome.applied = outcome.applied + 1
        -- Readback is what turns this from a hope into evidence.
        local _, readback = deps.townCapacity(townId)
        outcome.after[#outcome.after + 1] =
          (readback[1] or 0) + (readback[2] or 0) + (readback[3] or 0)
        if readback[1] == target[1] and readback[2] == target[2]
          and readback[3] == target[3] then
          outcome.verified = outcome.verified + 1
        end
      else
        outcome.errors[#outcome.errors + 1] = tostring(err)
      end
    end
  end
  outcome.runtimeScalingWorks = outcome.applied > 0 and outcome.verified == outcome.applied
  if worldState then worldState.agentPolicy = util.deepCopy(outcome) end
  return outcome
end

-- Records the configured policy at match initialisation without mutating an
-- already-running town.  The live Build 35924 experiment on 2026-08-06 proved
-- that setTownInfo is not a capacity-scaling surface: the host accepted the
-- command but read back unchanged capacities.  (The client's simultaneous
-- native assertion was later isolated to saved-company ownership projection.)
-- The loadConstruction modifier remains the supported path for freshly
-- loaded/generated town buildings.
function M.applyConfiguredPolicy(state, cfg, deps, log)
  local policy = M.mode(cfg.agentMode)
  local outcome = {
    mode = policy.label,
    fingerprint = M.fingerprint(policy),
    towns = 0, applied = 0, verified = 0, unchanged = 0, errors = {},
    constructionScalingActive = policy.capacityDenominator > 1
      or policy.capacityNumerator ~= 1,
    runtimeScalingWorks = false,
  }
  local listed, towns = pcall(deps.listTowns)
  if listed and type(towns) == "table" then
    outcome.towns = #towns
  elseif not listed then
    outcome.errors[#outcome.errors + 1] = "town enumeration failed: " .. tostring(towns)
  end
  if outcome.constructionScalingActive then
    outcome.skipped = "runtime setTownInfo scaling is unsafe on Build 35924; "
      .. "loadConstruction applies the policy while town buildings load"
  else
    outcome.skipped = "policy keeps the vanilla population"
  end
  if state.world then state.world.agentPolicy = util.deepCopy(outcome) end
  state.probes.agentPolicy = outcome
  state.probes.agentPolicy.configuredFingerprint = cfg.agentPolicyFingerprint
  if log then
    log("agent-policy", {
      mode = state.probes.agentPolicy.mode,
      towns = state.probes.agentPolicy.towns,
      applied = state.probes.agentPolicy.applied,
      verified = state.probes.agentPolicy.verified,
      runtimeScalingWorks = state.probes.agentPolicy.runtimeScalingWorks,
      tick = state.tick,
    })
  end
  return state.probes.agentPolicy
end

function M.fingerprint(policy)
  policy = policy or M.mode(M.DEFAULT_MODE)
  return table.concat({
    "agents", policy.label,
    tostring(policy.capacityNumerator), tostring(policy.capacityDenominator),
    tostring(policy.capacityFloor),
    policy.pinLoadSpeed and "pinned" or "native",
    tostring(policy.simulateCargoWeight and 1 or 0),
    tostring(policy.destinationRecomputationPermille),
  }, ":")
end

return M
