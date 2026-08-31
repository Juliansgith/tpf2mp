local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local exactOwnership = require "tpf2_mp/construction_exact_ownership"
local guiBuildCommandFactory = require "tpf2_mp/gui_build_command_factory"
local proposalCodec = require "tpf2_mp/proposal_codec"
local terminalFixture = require "tpf2_mp/validation_connected_terminal_proposal"
local util = require "tpf2_mp/util"

local function fakeProposal()
  return {
    constructionsToAdd = {}, constructionsToRemove = {}, old2new = {},
    streetProposal = {
      nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
  }
end

local fakeApi = { type = {
  SimpleProposal = {
    ConstructionEntity = { new = function() return {} end },
    new = fakeProposal,
  },
  SegmentAndEntity = { new = function() return { comp = {} } end },
  NodeAndEntity = { new = function() return { comp = {} } end },
  PlayerOwned = { new = function() return {} end },
  Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
  Vec4f = { new = function(a, b, c, d) return { a, b, c, d } end },
  Mat4f = { new = function(a, b, c, d) return { a, b, c, d } end },
  BaseEdgeStreet = { new = function() return {} end },
  BaseEdgeTrack = { new = function() return {} end },
}, res = {
  constructionRep = { find = function() return 1 end },
  moduleRep = {
    find = function() return 1 end,
    get = function() return { metadata = {} } end,
  },
  streetTypeRep = { find = function() return 1 end },
  trackTypeRep = { find = function() return 1 end },
} }

do
  local corruptedExpected = { playerOwned = { player = 8 } }
  local corruptedObserved = { playerOwned = { player = 8 } }
  assert(exactOwnership.rewriteEdge(
    corruptedObserved, corruptedExpected, 7, 7, fakeApi.type.PlayerOwned.new))
  assert(corruptedObserved.playerOwned.player == 7,
    "canonical owner did not replace engine-mutated PlayerOwned userdata")

  local missingObserved, missingExpected = {}, {}
  assert(exactOwnership.rewriteEdge(
    missingObserved, missingExpected, 7, 7, fakeApi.type.PlayerOwned.new))
  assert(missingObserved.playerOwned.player == 7,
    "canonical owner did not recreate a missing private ownership component")

  local pollutedPublic = { playerOwned = { player = 8 } }
  assert(exactOwnership.rewriteEdge(
    pollutedPublic, {}, -1, 7, fakeApi.type.PlayerOwned.new))
  assert(pollutedPublic.playerOwned.player == -1,
    "canonical public edge retained the local command issuer")

  local accepted, invalidPlan = exactOwnership.rewriteEdge(
    { playerOwned = { player = 8 } }, corruptedExpected, 8, 7,
    fakeApi.type.PlayerOwned.new)
  assert(accepted == nil and invalidPlan == "canonical construction edge ownership plan is invalid",
    "ownership replay accepted a plan that disagreed with the mapped company owner")
end

local localIds = {
  ["node:pre:41440cf4"] = 701,
  ["node:pre:41620cf4"] = 702,
  ["edge:pre:72fc11f4"] = 703,
  ["construction:pre:adee28b9"] = 704,
  ["construction:pre:aff228b9"] = 705,
}

local variants = {
  { label = "passenger-bus", templateIndex = 0, tramTrack = 0, missingPrivate = false },
  { label = "passenger-tram", templateIndex = 1, tramTrack = 1, missingPrivate = true },
  { label = "cargo-truck", templateIndex = 3, tramTrack = 0, cargo = true,
    missingPrivate = false },
}

for _, variant in ipairs(variants) do
  local transaction = assert(terminalFixture.transaction("company:1"))
  local construction = transaction.constructions[1]
  construction.params.templateIndex = variant.templateIndex
  construction.params.tramTrack = variant.tramTrack
  if variant.cargo then
    for _, module in ipairs(construction.modules) do
      if module.name == "station/street/passenger_platform.module" then
        module.name = "station/street/cargo_platform.module"
        module.metadata = { cargo = true }
      end
    end
  end
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  assert(proposalCodec.validate(transaction))

  local proposal, metadata = assert(proposalCodec.materialise(transaction, {
    api = fakeApi,
    nativePlayerId = 7,
    resolveLocal = function(cid) return localIds[cid] end,
  }))
  local exact = metadata.construction.exactTopology.typed
  assert(#exact.edges == 3 and #exact.edgeOwners == 3
      and exact.edgeOwners[1] == 7
      and exact.edgeOwners[2] == -1 and exact.edgeOwners[3] == -1,
    variant.label .. " did not derive an immutable ownership plan from the transaction")

  local generatedNodes, generatedEdges, remappedNodes = {}, {}, {}
  for index, expected in ipairs(exact.nodes) do
    local generatedId = -(100 + index)
    generatedNodes[index] = {
      entity = generatedId,
      comp = { position = util.deepCopy(expected.comp.position) },
    }
    remappedNodes[tostring(expected.entity)] = generatedId
  end
  for index, expected in ipairs(exact.edges) do
    local comp = util.deepCopy(expected.comp)
    comp.node0 = remappedNodes[tostring(comp.node0)] or comp.node0
    comp.node1 = remappedNodes[tostring(comp.node1)] or comp.node1
    generatedEdges[index] = {
      entity = -(200 + index), type = expected.type,
      comp = comp, streetEdge = util.deepCopy(expected.streetEdge),
      -- Construction expansion incorrectly substitutes the local issuer for
      -- private and public edges alike in this adversarial fixture.
      playerOwned = { player = 8 },
    }
  end

  -- Reproduce the 0.42.2 live failure: buildProposal mutates the same typed
  -- input object retained for exact replay. One variant also removes the
  -- component completely to cover the fresh-component fallback.
  if variant.missingPrivate then
    exact.edges[1].playerOwned = nil
    generatedEdges[1].playerOwned = nil
  else
    exact.edges[1].playerOwned.player = 8
  end

  local command, commandError = guiBuildCommandFactory.make(function()
    return { proposal = {
      proposal = {
        addedNodes = generatedNodes,
        addedSegments = generatedEdges,
        edgeObjectsToAdd = {},
      },
      toAdd = { { playerEntity = 8 } },
      toRemove = util.deepCopy(proposal.constructionsToRemove),
    } }
  end, proposal, transaction, metadata, function(value, key) return value[key] end)
  assert(command, variant.label .. " exact replay failed: " .. tostring(commandError))
  assert(command.proposal.toAdd[1].playerEntity == 7,
    variant.label .. " retained the local issuer on its construction")
  assert(command.proposal.proposal.addedSegments[1].playerOwned.player == 7,
    variant.label .. " retained the local issuer on its private entrance")
  for index = 2, 3 do
    assert(command.proposal.proposal.addedSegments[index].playerOwned.player == -1,
      variant.label .. " retained private ownership on public road edge " .. tostring(index))
  end
end

print("PASS construction exact ownership tests")
