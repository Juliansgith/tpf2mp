local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local componentType = {
  BASE_EDGE = "BASE_EDGE",
  BASE_EDGE_STREET = "BASE_EDGE_STREET",
  BASE_EDGE_TRACK = "BASE_EDGE_TRACK",
  PLAYER_OWNED = "PLAYER_OWNED",
}
local components = {
  BASE_EDGE = { [10] = { node0 = 1, node1 = 2 }, [30] = { node0 = 3, node1 = 4 } },
  BASE_EDGE_STREET = { [10] = { streetType = 7 } },
  BASE_EDGE_TRACK = { [30] = { trackType = 8 } },
  PLAYER_OWNED = { [30] = { player = 100 } },
}
local nextEdge = 19
local forceFailure = false

api = {
  type = {
    ComponentType = componentType,
    SimpleProposal = {
      new = function()
        return { streetProposal = { edgesToRemove = {}, edgesToAdd = {} } }
      end,
    },
    SegmentAndEntity = { new = function() return {} end },
    PlayerOwned = { new = function() return {} end },
  },
  engine = {
    getComponent = function(entity, kind)
      return components[kind] and components[kind][entity] or nil
    end,
    forEachEntityWithComponent = function(callback, kind)
      for entity in pairs(components[kind] or {}) do callback(entity) end
    end,
  },
  cmd = {
    make = {
      buildProposal = function(proposal)
        return { proposal = proposal }
      end,
    },
    sendCommand = function(command, callback)
      if forceFailure then
        callback({}, false)
        return
      end
      local streetProposal = command.proposal.streetProposal
      local previous = streetProposal.edgesToRemove[1]
      local segment = streetProposal.edgesToAdd[1]
      nextEdge = nextEdge + 1
      components.BASE_EDGE[previous] = nil
      components.BASE_EDGE_STREET[previous] = nil
      components.BASE_EDGE_TRACK[previous] = nil
      components.PLAYER_OWNED[previous] = nil
      components.BASE_EDGE[nextEdge] = segment.comp
      if segment.streetEdge then components.BASE_EDGE_STREET[nextEdge] = segment.streetEdge end
      if segment.trackEdge then components.BASE_EDGE_TRACK[nextEdge] = segment.trackEdge end
      components.PLAYER_OWNED[nextEdge] = segment.playerOwned
      callback({ resultEntities = {} }, true)
    end,
  },
}

local canonical = require "tpf2_mp/canonical"
local edgeOwnership = require "tpf2_mp/edge_ownership"

local supported, supportError = edgeOwnership.supported()
assert(supported, supportError)

local streetProposal, streetError, streetInfo = edgeOwnership.makeProposal(10, 101)
assert(streetProposal and not streetError and streetInfo.carrier == "street",
  "street ownership proposal was not constructed")
assert(streetProposal.streetProposal.edgesToRemove[1] == 10
  and streetProposal.streetProposal.edgesToAdd[1].playerOwned.player == 101,
  "street ownership proposal lost its source or target owner")

local registry = canonical.newState()
assert(canonical.bind(registry, "edge:test", "edge", 10, { owner = "company:2" }))
local worldState = {
  logicalOwners = { ["10"] = "company:2" },
  pinnedCustody = {
    ["10"] = { cid = "edge:test", kind = "edge", logicalOwnerCid = "company:2" },
  },
}
local firstResult
local issued, issueInfo = edgeOwnership.send(10, 101, function(result) firstResult = result end)
assert(issued and issueInfo and firstResult and firstResult.success,
  "proposal ownership assignment failed in the supported-path mock")
assert(firstResult.replacementEntity == 20 and #firstResult.resultIds == 0,
  "replacement edge was not found from the exhaustive BASE_EDGE delta")
assert(edgeOwnership.ownerOf(20) == 101, "replacement edge has the wrong native owner")
assert(edgeOwnership.rebind(worldState, registry, "edge:test", 10, 20, "company:2", 101))
assert(canonical.resolveLocal(registry, "edge:test") == 20
  and worldState.logicalOwners["10"] == nil
  and worldState.logicalOwners["20"] == "company:2",
  "proposal replacement did not migrate canonical/logical identity")

local secondResult
assert(edgeOwnership.send(20, 100, function(result) secondResult = result end))
assert(secondResult and secondResult.success and secondResult.replacementEntity == 21,
  "proposal ownership restore did not identify its second replacement")
assert(edgeOwnership.rebind(worldState, registry, "edge:test", 20, 21, "company:2", 100))
assert(canonical.resolveLocal(registry, "edge:test") == 21
  and worldState.pinnedCustody["21"].nativePlayerId == 100
  and worldState.pinnedCustody["21"].reason == "build35924-proposal-replacement",
  "second proposal replacement did not preserve logical custody")

local trackProposal, trackError, trackInfo = edgeOwnership.makeProposal(30, 101)
assert(trackProposal and not trackError and trackInfo.carrier == "track"
  and trackProposal.streetProposal.edgesToAdd[1].trackEdge.trackType == 8,
  "track ownership proposal was not constructed")

forceFailure = true
local failedResult
assert(edgeOwnership.send(21, 101, function(result) failedResult = result end))
assert(failedResult and failedResult.success == false and failedResult.commandSuccess == false
  and failedResult.error == "BuildProposal callback returned success=false",
  "failed ownership callback was misreported")

-- Reproduce the live cross-company electrification shape. The GUI preview
-- carries the old IDs, builder.apply carries the new IDs, and segment order
-- may be reversed. Topology matching must preserve both canonical owners.
components.BASE_EDGE[15370] = { node0 = 27015, node1 = 27016 }
components.BASE_EDGE[27020] = { node0 = 27014, node1 = 27015 }
components.BASE_EDGE_TRACK[15370] = { trackType = 9 }
components.BASE_EDGE_TRACK[27020] = { trackType = 9 }
components.PLAYER_OWNED[15370] = { player = 100 }
components.PLAYER_OWNED[27020] = { player = 100 }
local upgradeRegistry = canonical.newState()
assert(canonical.bind(upgradeRegistry, "edge:track-a", "edge", 27017, { owner = "company:2" }))
assert(canonical.bind(upgradeRegistry, "edge:track-b", "edge", 27018, { owner = "company:2" }))
local upgradeWorld = {
  logicalOwners = { ["27017"] = "company:2", ["27018"] = "company:2" },
  pinnedCustody = {
    ["27017"] = { cid = "edge:track-a", kind = "edge", logicalOwnerCid = "company:2" },
    ["27018"] = { cid = "edge:track-b", kind = "edge", logicalOwnerCid = "company:2" },
  },
}
local upgradeMatch = edgeOwnership.matchBuilderReplacements({
  proposal = {
    removedSegments = {
      ["1"] = { entity = 27018, type = 1, comp = { node0 = 27015, node1 = 27016 } },
      ["2"] = { entity = 27017, type = 1, comp = { node0 = 27014, node1 = 27015 } },
    },
  },
}, {
  proposal = {
    addedSegments = {
      ["1"] = { entity = 15370, type = 1, comp = { node0 = 27015, node1 = 27016 }, playerOwned = { player = 100 } },
      ["2"] = { entity = 27020, type = 1, comp = { node0 = 27014, node1 = 27015 }, playerOwned = { player = 100 } },
    },
  },
})
assert(#upgradeMatch.pairs == 2 and #upgradeMatch.unmatchedSources == 0,
  "two-edge upgrade was not matched by stable topology")
assert(upgradeMatch.pairs[1].appliedNativePlayerId == 100
  and upgradeMatch.pairs[2].appliedNativePlayerId == 100,
  "builder.apply native ownership evidence was not retained")
local upgradeMigration = edgeOwnership.rebindObserved(upgradeWorld, upgradeRegistry, upgradeMatch, 100)
assert(#upgradeMigration.failed == 0 and #upgradeMigration.rebound == 2,
  "two-edge upgrade did not rebind atomically")
assert(canonical.resolveLocal(upgradeRegistry, "edge:track-a") == 27020
  and canonical.resolveLocal(upgradeRegistry, "edge:track-b") == 15370,
  "two-edge upgrade rebound the wrong topology pair")
assert(upgradeWorld.logicalOwners["27017"] == nil and upgradeWorld.logicalOwners["27018"] == nil
  and upgradeWorld.logicalOwners["27020"] == "company:2"
  and upgradeWorld.logicalOwners["15370"] == "company:2",
  "two-edge upgrade lost the inactive company's logical ownership")

-- Live Build 35924 can deliver builder.apply one update before the engine
-- state's PLAYER_OWNED lookup sees replacement entities. The committed apply
-- projection is valid fallback evidence only when it names the expected desk.
local transientRegistry = canonical.newState()
assert(canonical.bind(transientRegistry, "edge:transient", "edge", 60, { owner = "company:2" }))
local transientWorld = {
  logicalOwners = { ["60"] = "company:2" },
  pinnedCustody = { ["60"] = { cid = "edge:transient", logicalOwnerCid = "company:2" } },
}
local transientMatch = edgeOwnership.matchBuilderReplacements({
  proposal = { removedSegments = {
    ["1"] = { entity = 60, type = 1, comp = { node0 = 7, node1 = 8 } },
  } },
}, {
  proposal = { addedSegments = {
    ["1"] = { entity = 61, type = 1, comp = { node0 = 7, node1 = 8 }, playerOwned = { player = 100 } },
  } },
})
local transientMigration = edgeOwnership.rebindObserved(
  transientWorld, transientRegistry, transientMatch, 100)
assert(#transientMigration.failed == 0 and #transientMigration.rebound == 1
  and transientMigration.rebound[1].ownerEvidence == "builder.apply-playerOwned"
  and canonical.resolveLocal(transientRegistry, "edge:transient") == 61,
  "committed builder.apply ownership did not bridge the transient engine lookup gap")
local transientPostcondition = edgeOwnership.validatePinnedCustody(transientWorld, 100)
assert(#transientPostcondition.failed == 1,
  "unobservable projected owner was accepted as the final turn postcondition")
components.PLAYER_OWNED[61] = { player = 100 }
transientPostcondition = edgeOwnership.validatePinnedCustody(transientWorld, 100)
assert(#transientPostcondition.failed == 0 and #transientPostcondition.verified == 1,
  "pinned replacement owner was not confirmed once the engine component became visible")

-- Build 35924 can cascade a depot or station construction transfer onto an
-- attached edge. That edge is still safely held when its native owner is the
-- same company recorded by logical custody. A rival company must still fail.
components.PLAYER_OWNED[90] = { player = 102 }
local constructionCascadeWorld = {
  logicalOwners = { ["90"] = "company:2" },
  pinnedCustody = {
    ["90"] = { cid = "edge:construction-link", logicalOwnerCid = "company:2" },
  },
}
local companies = {
  ["company:1"] = { playerId = 101 },
  ["company:2"] = { playerId = 102 },
}
local cascadePostcondition = edgeOwnership.validatePinnedCustody(
  constructionCascadeWorld, 100, companies)
assert(#cascadePostcondition.failed == 0 and #cascadePostcondition.verified == 1
  and cascadePostcondition.verified[1].logicalNativeOwner == 102
  and #cascadePostcondition.verified[1].allowedNativeOwners == 2,
  "rightful depot/station edge cascade was rejected")
components.PLAYER_OWNED[90].player = 101
cascadePostcondition = edgeOwnership.validatePinnedCustody(
  constructionCascadeWorld, 100, companies)
assert(#cascadePostcondition.failed == 1
  and cascadePostcondition.failed[1].observedNativeOwner == 101,
  "rival company owner bypassed construction-linked edge custody")
components.PLAYER_OWNED[90] = nil

components.PLAYER_OWNED[777] = { player = 999 }
local ownerlessPostcondition = edgeOwnership.validatePinnedCustody({
  pinnedCustody = {
    ["777"] = { localId = 777, cid = "edge:ownerless", logicalOwnerCid = "company:missing" },
  },
}, nil, {})
assert(#ownerlessPostcondition.failed == 1
  and ownerlessPostcondition.failed[1].error == "pinned edge has no permitted native owner",
  "pinned custody without a desk or rightful company owner did not fail closed")
components.PLAYER_OWNED[777] = nil

local wrongOwnerRegistry = canonical.newState()
assert(canonical.bind(wrongOwnerRegistry, "edge:wrong-owner", "edge", 70, { owner = "company:2" }))
local wrongOwnerWorld = {
  logicalOwners = { ["70"] = "company:2" },
  pinnedCustody = { ["70"] = { cid = "edge:wrong-owner", logicalOwnerCid = "company:2" } },
}
local wrongOwnerMatch = edgeOwnership.matchBuilderReplacements({
  proposal = { removedSegments = {
    ["1"] = { entity = 70, type = 1, comp = { node0 = 9, node1 = 10 } },
  } },
}, {
  proposal = { addedSegments = {
    ["1"] = { entity = 71, type = 1, comp = { node0 = 9, node1 = 10 }, playerOwned = { player = 101 } },
  } },
})
local wrongOwnerMigration = edgeOwnership.rebindObserved(
  wrongOwnerWorld, wrongOwnerRegistry, wrongOwnerMatch, 100)
assert(#wrongOwnerMigration.failed == 1 and #wrongOwnerMigration.rebound == 0
  and canonical.resolveLocal(wrongOwnerRegistry, "edge:wrong-owner") == 70,
  "unexpected builder.apply owner bypassed fail-closed validation")

components.PLAYER_OWNED[81] = { player = 101 }
local engineMismatchRegistry = canonical.newState()
assert(canonical.bind(
  engineMismatchRegistry, "edge:engine-mismatch", "edge", 80, { owner = "company:2" }))
local engineMismatchWorld = {
  logicalOwners = { ["80"] = "company:2" },
  pinnedCustody = { ["80"] = { cid = "edge:engine-mismatch", logicalOwnerCid = "company:2" } },
}
local engineMismatch = edgeOwnership.matchBuilderReplacements({
  proposal = { removedSegments = {
    ["1"] = { entity = 80, type = 1, comp = { node0 = 11, node1 = 12 } },
  } },
}, {
  proposal = { addedSegments = {
    ["1"] = { entity = 81, type = 1, comp = { node0 = 11, node1 = 12 }, playerOwned = { player = 100 } },
  } },
})
local engineMismatchMigration = edgeOwnership.rebindObserved(
  engineMismatchWorld, engineMismatchRegistry, engineMismatch, 100)
assert(#engineMismatchMigration.failed == 1 and #engineMismatchMigration.rebound == 0
  and engineMismatchMigration.failed[1].observedNativeOwner == 101
  and canonical.resolveLocal(engineMismatchRegistry, "edge:engine-mismatch") == 80,
  "committed apply evidence overrode a contradictory engine owner")

-- A partial/ambiguous builder observation must not migrate only the pair that
-- happened to resolve; reconciliation can then fail closed with no money move.
components.PLAYER_OWNED[50] = { player = 100 }
local partialRegistry = canonical.newState()
assert(canonical.bind(partialRegistry, "edge:partial-a", "edge", 40, { owner = "company:2" }))
assert(canonical.bind(partialRegistry, "edge:partial-b", "edge", 41, { owner = "company:2" }))
local partialWorld = {
  logicalOwners = { ["40"] = "company:2", ["41"] = "company:2" },
  pinnedCustody = {
    ["40"] = { cid = "edge:partial-a", logicalOwnerCid = "company:2" },
    ["41"] = { cid = "edge:partial-b", logicalOwnerCid = "company:2" },
  },
}
local partialMatch = edgeOwnership.matchBuilderReplacements({
  proposal = { removedSegments = {
    ["1"] = { entity = 40, type = 1, comp = { node0 = 1, node1 = 2 } },
    ["2"] = { entity = 41, type = 1, comp = { node0 = 3, node1 = 4 } },
  } },
}, {
  proposal = { addedSegments = {
    ["1"] = { entity = 50, type = 1, comp = { node0 = 1, node1 = 2 } },
  } },
})
local partialMigration = edgeOwnership.rebindObserved(partialWorld, partialRegistry, partialMatch, 100)
assert(#partialMigration.failed == 1 and #partialMigration.rebound == 0,
  "partial replacement observation did not fail atomically")
assert(canonical.resolveLocal(partialRegistry, "edge:partial-a") == 40
  and canonical.resolveLocal(partialRegistry, "edge:partial-b") == 41,
  "partial replacement observation mutated canonical state before failing")

-- The hot-seat desk owns every pinned edge natively, so proposal access must
-- use logical company custody. Existing rival sources are denied before the
-- builder commits; own, new-preview, and public/untracked sources stay usable.
local accessWorld = {
  logicalOwners = {
    ["900"] = "company:1",
    ["901"] = "company:2",
    ["903"] = "company:2",
    ["910"] = "company:1",
    ["911"] = "company:2",
  },
  pinnedCustody = {
    ["902"] = { cid = "edge:pinned-fallback", logicalOwnerCid = "company:2" },
    ["904"] = { cid = "edge:missing-logical-owner" },
  },
}
local rivalProposal = {
  proposal = {
    proposal = {
      removedSegments = {
        ["1"] = { entity = 901, type = 1 },
        ["2"] = { entity = -4, type = 1 },
      },
    },
  },
}
local rivalAccess = edgeOwnership.checkProposalAccess(accessWorld, rivalProposal, "company:1")
assert(rivalAccess.allowed == false and #rivalAccess.sourceIds == 1
  and rivalAccess.sourceIds[1] == 901 and #rivalAccess.blocked == 1
  and rivalAccess.blocked[1].logicalOwnerCid == "company:2",
  "rival tracked edge was not rejected from a nested builder projection")

local ownAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  streetProposal = { edgesToRemove = { 900 } },
}, "company:1")
assert(ownAccess.allowed == true and #ownAccess.tracked == 1,
  "active company's own edge was rejected")

local publicAndNewAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  proposal = { removedSegments = {
    ["1"] = { entity = 999 },
    ["2"] = { entity = -1 },
  } },
}, "company:1")
assert(publicAndNewAccess.allowed == true and #publicAndNewAccess.tracked == 0
  and #publicAndNewAccess.sourceIds == 1 and publicAndNewAccess.sourceIds[1] == 999,
  "public/untracked or new preview infrastructure was rejected")

local pinnedFallbackAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  proposal = { edgeObjectsToRemove = { ["1"] = { edgeEntity = 902 } } },
}, "company:1")
assert(pinnedFallbackAccess.allowed == false
  and pinnedFallbackAccess.blocked[1].canonicalId == "edge:pinned-fallback",
  "pinned logical custody did not protect an entity missing from logicalOwners")

local rivalSignalAddition = edgeOwnership.checkProposalAccess(accessWorld, {
  proposal = { edgeObjectsToAdd = {
    ["1"] = { entity = -7, edgeEntity = 901, model = "railroad/signal_path_a.mdl" },
  } },
}, "company:1")
assert(rivalSignalAddition.allowed == false
  and #rivalSignalAddition.sourceIds == 1
  and rivalSignalAddition.sourceIds[1] == 901,
  "adding a signal to a rival edge was not rejected when the object id was temporary")

local constructionAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  toRemove = { ["1"] = { entity = 903 } },
}, "company:1")
assert(constructionAccess.allowed == false and constructionAccess.blocked[1].localId == 903,
  "tracked construction source was not covered by the general access policy")

local explicitConstructionAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  constructionsToRemove = { ["1"] = 903 },
}, "company:1")
assert(explicitConstructionAccess.allowed == false
  and explicitConstructionAccess.blocked[1].localId == 903,
  "explicit constructionsToRemove did not protect a rival station/depot edit")

local projectedConstructionAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  __constructionRemovals = { ["1"] = { constructionEntity = 903 } },
}, "company:1")
assert(projectedConstructionAccess.allowed == false
  and projectedConstructionAccess.blocked[1].localId == 903,
  "deep construction-removal projection did not protect a rival station edit")

local corruptCustodyAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  proposal = { removedSegments = { ["1"] = { entity = 904 } } },
}, "company:1")
assert(corruptCustodyAccess.allowed == false
  and corruptCustodyAccess.blocked[1].canonicalId == "edge:missing-logical-owner",
  "tracked custody with a missing logical owner failed open")

-- Extending track can reference an existing endpoint without removing an
-- adjoining edge. Positive node0/node1 references must therefore receive the
-- same symmetric ownership check as removal containers.
local rivalEndpointAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  proposal = { addedSegments = {
    ["1"] = { entity = -1, type = 1, comp = { node0 = 911, node1 = -2 } },
  } },
}, "company:1")
assert(rivalEndpointAccess.allowed == false and #rivalEndpointAccess.sourceIds == 1
  and rivalEndpointAccess.sourceIds[1] == 911
  and rivalEndpointAccess.blocked[1].logicalOwnerCid == "company:2",
  "rival private endpoint expansion was not rejected")

local ownEndpointAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  streetProposal = { edgesToAdd = {
    ["1"] = { entity = -3, type = 1, comp = { node0 = -4, node1 = 910 } },
  } },
}, "company:1")
assert(ownEndpointAccess.allowed == true and #ownEndpointAccess.tracked == 1,
  "active company's own endpoint expansion was rejected")

local publicEndpointAccess = edgeOwnership.checkProposalAccess(accessWorld, {
  proposal = { proposal = { streetProposal = { edgesToAdd = {
    ["1"] = { entity = -5, type = 1, comp = { node0 = 9999, node1 = -6 } },
  } } } },
}, "company:1")
assert(publicEndpointAccess.allowed == true and #publicEndpointAccess.tracked == 0
  and publicEndpointAccess.sourceIds[1] == 9999,
  "public/untracked endpoint expansion was rejected")

print("PASS proposal ownership, symmetric endpoint access, replacement matching, and atomic canonical rebinding")
