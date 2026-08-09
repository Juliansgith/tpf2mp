local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local operationCodec = require "tpf2_mp/operation_codec"

local M = {}

local KNOWN_LIMITS = {
  "BuildProposal has a payload-aware pre-mutation gate. Of the twenty-three additional exact visitor gates, fifteen line/portable-vehicle/name/color tags have strict canonical operation codecs. Native SetGameSpeed is host-ordered; calendar/logo/field/terrain/date/cheat/person-debug categories stay fail-closed for player input.",
  "Proposal schema 5 canonically serializes road/track changes plus named signal/waypoint edge objects, including retained objects across edge replacement, with quoted cost and no machine-local IDs. Schema 7 adds stock rail-station placement and bounded generic named .con/.module payloads for depots, ordinary constructions, ASSET_DEFAULT roots, upgrades, modular station edits, and removal. Both paths use repository names, strict ownership, preflight and physical consensus. Opaque/script callbacks and ambiguous dependency migration fail closed; every peer still requires an identical pinned mod pack.",
  "Construction uses all-peer prepare before native mutation, then two-peer physical completion consensus, ordered success/fault controls, a bounded timeout, and fail-closed dependency gating. A readiness rejection is non-fatal because neither world changed. Match start and each successful physical result are followed by a host-verified checkpoint barrier; in-place native geometry rollback is deliberately not claimed.",
  "Shared-clock v2 projects staggered peer heartbeats to one host time, orders future-time pause/speed rendezvous, corrects bounded overshoot, emits paused heartbeats, and adaptively caps the effective speed from engine/backlog health. Populated localhost is live-proven; two-computer long-pause and slowdown/recovery proof remains.",
  "Assigned canonical trains are held at every native terminal until both peers report the same vehicle, line, stop and sequential leg round, then receive one ordered future-time release. Format-5 checkpoints digest that authority state together with exact model passenger and cargo queues/loads. Four populated localhost rounds are live-proven. This does not teleport trains; a different stop index faults closed.",
  "Line/vehicle creation IDs are discovered from the native callback result or an exact before/after component-set delta, then bound to event-derived canonical IDs.",
  "The GUI rejects known mutating actions against rival logical entities. Native visitors stop selected unsupported line, vehicle, naming, speed, terrain, date, and cheat commands in network mode; unlisted/autonomous categories still require dedicated authority analysis.",
  "Populated local hot-seat validation covers stations, depots, lines, two running trains and real passenger/cargo trips. Canonical network sale/replacement/maintenance and long-running income/expense still require live destructive tests.",
  "Native loan principal is not mirrored, so native borrowing and repayment remain disabled. Competitive credit is instead authored from earned revenue, charged through ordered settlements, and included in the core digest.",
  "The desk retains the base game's loan, so unpaused month-boundary interest can contaminate a long proxy turn; pause-on-switch is the supported local-test configuration.",
  "Company starting cash is an explicit, idempotent match-setup grant; it is audited separately and is not a money-conserving operational transfer.",
  "Build 35924 asserts when legacy setPlayer is used directly on BASE_EDGE. Tracked edges therefore use logical ownership and normally stay on the desk; a depot/station transfer may cascade attached edges to their rightful company. Either native holder is valid, rival holders fail closed, and rival builder proposals are vetoed before commit.",
  "Canonical town growth and freight production are host-authored. Native physical town/industry presentation and other unproven autonomous subsystems remain frozen during authority tests.",
  "Native person and cargo entity IDs are intentionally local scenery. Direct SIM_* component telemetry is retained, while the synchronized passenger/cargo ledgers and authored stock-UI projection are authoritative for station queues, vehicle loads, revenue, and score.",
  "Debug_SetSimPersonState carries only an eight-byte person-id/boolean payload and cannot address a train or station. Native cosmetic writes therefore fail closed with zero commands issued; misleading stock load, station-board, finance-history, and transported widgets are hidden or relabelled while exact authored replacements are inserted into their standard windows.",
}

function M.new(env)
  assert(type(env) == "table" and type(env.getState) == "function",
    "research-report state provider is required")
  assert(type(env.nativeHookStatus) == "function"
      and type(env.authoredDigest) == "function"
      and type(env.coreDigest) == "function",
    "research-report diagnostic providers are required")
  assert(type(env.publicSnapshot) == "function" and type(env.accountOf) == "function",
    "research-report public account providers are required")
  assert(type(env.emit) == "function", "research-report emitter is required")
  local researchSnapshot = env.researchSnapshot or world.researchSnapshot

  local function build()
    local state = env.getState()
    local report = researchSnapshot(state.world, state.canonical, state.companies)
    report.tick = state.tick
    report.sessionId = state.bridge.sessionId
    report.peerId = state.bridge.peerId
    report.networkMode = state.networkMode
    for _, field in ipairs({
      "capture", "guiCapabilities", "networkAuthority", "networkCalendar",
      "mobility", "mobilityHistory", "operational", "agentPolicy",
      "townDevelopment", "townDevelopmentQueue", "passengerCosmetics",
      "serviceRegistration", "freightMilestone", "passengerMilestone",
    }) do
      report[field] = util.deepCopy(state.probes[field])
    end
    report.nativeHook = env.nativeHookStatus()
    report.financeTransfers = util.deepCopy(state.finance.transfers)
    report.startingCash = util.deepCopy(state.finance.startingCash)
    report.networkAccounts = util.deepCopy(state.finance.networkAccounts)
    report.validation = util.deepCopy(state.validation)
    report.checkpoint = util.deepCopy(state.checkpoint)
    report.match = util.deepCopy(state.match)
    report.modelDigest = env.authoredDigest()
    report.coreDigest = env.coreDigest()
    report.passengerPresentation = passengerPresentation.digestView(
      state.world.passengerPresentation)
    report.passengerPresentationDigest = hash.value(report.passengerPresentation)
    report.economyPresentation = util.deepCopy(env.publicSnapshot().economyPresentation)
    report.proposals = {
      queued = state.world.proposals.queued or 0,
      applied = state.world.proposals.applied or 0,
      failed = state.world.proposals.failed or 0,
      retained = util.tableCount(state.world.proposals.byId),
    }
    report.operations = {
      schemaVersion = operationCodec.SCHEMA_VERSION,
      queued = state.world.operations.queued or 0,
      applied = state.world.operations.applied or 0,
      failed = state.world.operations.failed or 0,
      retained = util.tableCount(state.world.operations.byId),
      records = util.deepCopy(state.world.operations.byId),
    }
    report.proposalConsensus = util.deepCopy(state.world.proposalConsensus)
    report.operationConsensus = util.deepCopy(state.world.operationConsensus)
    report.checkpointConsensus = util.deepCopy(state.world.checkpointConsensus)
    report.worldManifest = util.deepCopy(state.probes.worldManifest)
    report.recovery = util.deepCopy(state.recovery)
    report.accounts = {
      source = state.networkMode == "network"
        and "native-cache-plus-canonical-ledger" or "native",
      canonical = finance.networkDigestView(state.finance),
      control = state.world.controlPlayerId
        and env.accountOf(state.world.controlPlayerId) or nil,
      companies = {},
    }
    for _, companyCid in ipairs(state.companyOrder) do
      report.accounts.companies[companyCid] = env.accountOf(
        state.companies[companyCid].playerId)
    end
    report.knownLimits = util.deepCopy(KNOWN_LIMITS)
    return report
  end

  local function export()
    local state, report = env.getState(), build()
    local ok, outbound = env.emit(report, state.tick)
    local exportError
    if not ok then exportError = tostring(outbound) end
    state.probes.lastResearch = {
      ok = ok,
      localSeq = ok and outbound.local_seq or nil,
      error = exportError,
      structuralDigest = report.structural and report.structural.digest or nil,
    }
    return ok, util.deepCopy(state.probes.lastResearch)
  end

  return { build = build, export = export }
end

return M
