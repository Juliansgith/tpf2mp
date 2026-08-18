local util = require "tpf2_mp/util"
local proposalCodec = require "tpf2_mp/proposal_codec"

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_RESOURCES = 1024

local function count(value)
  return util.clamp(util.integer(value, 0), 0, 1000000000)
end

function M.newProbe()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    observedProposals = 0,
    portableProposals = 0,
    rejectedProposals = 0,
    resources = {},
    ignoredResources = 0,
    byKind = {},
    lastProposal = nil,
    lastError = nil,
  }
end

function M.migrate(value)
  local probe = type(value) == "table" and value or M.newProbe()
  probe.schemaVersion = M.SCHEMA_VERSION
  probe.observedProposals = count(probe.observedProposals)
  probe.portableProposals = count(probe.portableProposals)
  probe.rejectedProposals = count(probe.rejectedProposals)
  probe.ignoredResources = count(probe.ignoredResources)
  probe.resources = type(probe.resources) == "table" and probe.resources or {}
  probe.byKind = type(probe.byKind) == "table" and probe.byKind or {}
  return probe
end

local function remember(probe, kind, name, adapter, digest)
  if type(name) ~= "string" or name == "" then return end
  local key = kind .. "\0" .. name
  local record = probe.resources[key]
  if not record then
    if util.tableCount(probe.resources) >= M.MAX_RESOURCES then
      probe.ignoredResources = count(probe.ignoredResources + 1)
      return
    end
    record = {
      kind = kind,
      name = name,
      adapter = adapter,
      status = "portable-by-name",
      exactReplay = true,
      peerPreflight = true,
      uses = 0,
      firstProposalDigest = digest,
    }
    probe.resources[key] = record
    probe.byKind[kind] = count((probe.byKind[kind] or 0) + 1)
  end
  record.uses = count(record.uses + 1)
  record.lastProposalDigest = digest
end

function M.observe(value, transaction)
  local probe = M.migrate(value)
  probe.observedProposals = count(probe.observedProposals + 1)
  local valid, validationError = proposalCodec.validatePortable(transaction)
  if not valid then
    probe.rejectedProposals = count(probe.rejectedProposals + 1)
    probe.lastError = tostring(validationError)
    return false, validationError, probe
  end

  local digest = transaction.digest
  for _, edge in ipairs(transaction.edges or {}) do
    remember(probe, edge.carrier, edge.resource and edge.resource.name,
      "named-edge-resource", digest)
  end
  for _, object in ipairs(transaction.edgeObjects and transaction.edgeObjects.add or {}) do
    remember(probe, "edge_object_model", object.model,
      "named-edge-object", digest)
  end
  for _, construction in ipairs(transaction.constructions or {}) do
    if construction.mode ~= "remove" then
      remember(probe, "construction", construction.fileName,
        construction.adapter, digest)
      for _, module in ipairs(construction.modules or {}) do
        remember(probe, "module", module.name,
          construction.adapter, digest)
      end
    end
  end

  probe.portableProposals = count(probe.portableProposals + 1)
  probe.lastError = nil
  probe.lastProposal = {
    digest = digest,
    schemaVersion = transaction.schemaVersion,
    companyCid = transaction.companyCid,
    nodes = #(transaction.nodes or {}),
    edges = #(transaction.edges or {}),
    edgeObjects = #(transaction.edgeObjects and transaction.edgeObjects.add or {}),
    constructions = #(transaction.constructions or {}),
    removedEdges = #(transaction.remove and transaction.remove.edges or {}),
    removedNodes = #(transaction.remove and transaction.remove.nodes or {}),
  }
  return true, probe.lastProposal, probe
end

function M.publicView(value)
  local probe = M.migrate(value)
  local resources = {}
  for _, key in ipairs(util.sortedKeys(probe.resources)) do
    resources[#resources + 1] = util.deepCopy(probe.resources[key])
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    observedProposals = probe.observedProposals,
    portableProposals = probe.portableProposals,
    rejectedProposals = probe.rejectedProposals,
    resourceCount = #resources,
    ignoredResources = probe.ignoredResources,
    byKind = util.deepCopy(probe.byKind),
    resources = resources,
    lastProposal = util.deepCopy(probe.lastProposal),
    lastError = probe.lastError,
    policy = {
      vanillaAndDataOnlyMods = "same named-resource path",
      roadsAndTracks = "generic named repository resources",
      signalsAndWaypoints = "generic named model resources",
      constructionsAndStations = "bounded portable params/modules",
      opaqueCallbacks = "blocked: explicit adapter required",
      maxEdges = proposalCodec.MAX_CONSTRUCTION_EDGES,
      maxModulesAndParams = proposalCodec.MAX_CONSTRUCTION_PARAM_VALUES,
    },
  }
end

function M.observer(getState)
  assert(type(getState) == "function", "resource compatibility state provider is required")
  return function(transaction)
    local state = getState()
    local ok, result, probe = M.observe(
      state.probes.resourceCompatibility, transaction)
    state.probes.resourceCompatibility = probe
    return ok, result
  end
end

return M
