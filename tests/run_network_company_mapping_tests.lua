local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local bridgeRoot = assert(arg[2], "bridge root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local proposalCodec = require "tpf2_mp/proposal_codec"

local players = {
  -- Mirrors app.startGame(): the original local player has seed cash/loan,
  -- while addPlayer competitors start clean. Network initialization must
  -- normalize the logical companies without treating the native loan as
  -- competitive credit.
  [100] = { id = 100, type = "PLAYER", name = "Local player", balance = 30000000, loan = 30000000 },
}
local components = {
  BASE_NODE = {}, BASE_EDGE = {}, BASE_EDGE_TRACK = {}, BASE_EDGE_STREET = {}, PLAYER_OWNED = {},
  LINE = {}, TRANSPORT_VEHICLE = {},
  CONSTRUCTION = {}, STATION = {}, STATION_GROUP = {}, VEHICLE_DEPOT = {},
  ASSET_GROUP = {}, SIGNAL_LIST = {},
}
local stationBuildFixture, depotBuildFixture, assetBuildFixture, bulldozeFixture
local stationUpgradeObserved, assetUpgradeObserved
-- The pinned starting save already contains one Company 1 track. On player2
-- the source save's native owner becomes the local representative of Company
-- 2, but the pre-existing track must remain canonically owned by Company 1.
components.BASE_NODE[90] = { position = { x = -50, y = 0, z = 0 } }
components.BASE_NODE[91] = { position = { x = 0, y = 0, z = 0 } }
components.BASE_EDGE[92] = { node0 = 90, node1 = 91 }
components.BASE_EDGE_TRACK[92] = { trackType = 0, catenary = false }
components.PLAYER_OWNED[92] = { player = 100 }
components.LINE[96] = { stops = {} }
components.TRANSPORT_VEHICLE[97] = { line = 96, stopIndex = 0 }
components.PLAYER_OWNED[96] = { player = 100 }
components.PLAYER_OWNED[97] = { player = 100 }
local nextPlayer = 100
local buildGateEnables, commandGateEnables = 0, 0
local journalCommands = 0
local buildGateEnabled, commandGateEnabled = false, false
tpf2mp_native_enable_build_gate = function()
  buildGateEnables, buildGateEnabled = buildGateEnables + 1, true
end
tpf2mp_native_disable_build_gate = function() buildGateEnabled = false end
tpf2mp_native_enable_command_gate = function()
  commandGateEnables, commandGateEnabled = commandGateEnables + 1, true
end
tpf2mp_native_disable_command_gate = function() commandGateEnabled = false end
tpf2mp_native_authorize_command = function() end
tpf2mp_native_revoke_command = function() end
tpf2mp_native_arm_build_correlation = function() end
tpf2mp_native_take_suppressed_build = function() return nil end
tpf2mp_native_status = function()
  return {
    hookVersion = "0.19.0",
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
      authorityCommandVisitors = 31,
    },
    gates = {
      buildProposal = { enabled = buildGateEnabled, tagMismatches = 0,
        suppressedQueue = { queued = 0, captured = 0, consumed = 0, dropped = 0 } },
      commandVisitors = {
        enabled = commandGateEnabled,
        hooked = 31,
        tagMismatches = 0,
      },
    },
  }
end

game = {
  config = { tpf2mp = {
    protocolVersion = 1,
    peerId = "player2",
    sessionId = "network-company-map",
    bridgeDir = bridgeRoot,
    updateStride = 1,
    maxEvents = 64,
    startNetwork = true,
    startingCash = 5000000,
  } },
  interface = {
    getPlayer = function() return 100 end,
    addPlayer = function()
      nextPlayer = nextPlayer + 1
      players[nextPlayer] = {
        id = nextPlayer, type = "PLAYER", name = "Added player", balance = 5000000, loan = 0,
      }
      return nextPlayer
    end,
    getEntity = function(id) return players[id] end,
    setName = function(id, name) if players[id] then players[id].name = name end end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    getDepots = function() return {} end,
    getGameTime = function() return { time = 0 } end,
    getPlayerJournal = function() return { income = { _sum = 0 } } end,
    setTownCapacities = function() end,
    setTownDevelopmentActive = function() end,
    buildConstruction = function(fileName, params, transform)
      local fixture = (stationBuildFixture and fileName == stationBuildFixture.fileName and stationBuildFixture)
        or (depotBuildFixture and fileName == depotBuildFixture.fileName and depotBuildFixture)
        or (assetBuildFixture and fileName == assetBuildFixture.fileName and assetBuildFixture)
      assert(fixture, "unexpected construction replay")
      if fixture == stationBuildFixture then
      assert(fileName == fixture.fileName and params.year == fixture.year
        and #transform == 16 and params.modules[8401000],
        "construction replay did not materialise the canonical station payload")
      end
      if fixture.construction then
        components.CONSTRUCTION[fixture.construction] = { fileName = fileName, transf = transform }
      end
      -- Build 35924 exposes a construction root before the generated station
      -- graph on a busy live pair. Tests can hold back those child components
      -- to prove the bounded settle window survives the old 120-tick cutoff.
      if fixture.delayTopology then return fixture.root or fixture.construction end
      if fixture.station then components.STATION[fixture.station] = { cargo = false } end
      if fixture.stationGroup then
        components.STATION_GROUP[fixture.stationGroup] = { stations = { fixture.station } }
      end
      if fixture.depot then components.VEHICLE_DEPOT[fixture.depot] = { carrier = "RAIL" } end
      if fixture.asset then components.ASSET_GROUP[fixture.asset] = { assets = {} } end
      for _, node in ipairs(fixture.nodes or {}) do
        components.BASE_NODE[node.id] = { position = node.position }
      end
      for _, edge in ipairs(fixture.edges or {}) do
        components.BASE_EDGE[edge.id] = { node0 = edge.node0, node1 = edge.node1 }
        components.BASE_EDGE_TRACK[edge.id] = {
          trackType = edge.trackType or 1,
          catenary = edge.catenary == nil and true or edge.catenary,
        }
        components.PLAYER_OWNED[edge.id] = { player = 100 }
      end
      return fixture.root or fixture.construction
    end,
    upgradeConstruction = function(entity, fileName, params)
      if entity == 600 then
        assert(fileName == "station/rail/modular_station/modular_station.con"
          and params.modules[10800010], "station upgrade did not materialise its module edit")
        stationUpgradeObserved = { entity = entity, fileName = fileName, params = params }
        components.CONSTRUCTION[entity].params = params
      else
        assert(entity == 8201 and fileName == "asset/test/example_new.con"
          and params.variant == "green", "asset upgrade did not materialise its portable payload")
        assetUpgradeObserved = { entity = entity, fileName = fileName, params = params }
        components.ASSET_GROUP[entity].fileName = fileName
      end
      -- Build 35924 helpers are allowed to mutate in place without returning a
      -- replacement entity; the canonical source identity must still survive.
      return nil
    end,
    bulldoze = function(entity)
      assert(bulldozeFixture and (bulldozeFixture.root or bulldozeFixture.construction) == entity,
        "unexpected construction bulldoze")
      local fixture = bulldozeFixture
      if fixture.construction then components.CONSTRUCTION[fixture.construction] = nil end
      -- A live station root can disappear before its generated topology.  Keep
      -- that intermediate state available to assert that canonical completion
      -- waits for every explicitly removed child rather than merely the root.
      if fixture.delayRemoval then return end
      if fixture.station then components.STATION[fixture.station] = nil end
      if fixture.stationGroup then components.STATION_GROUP[fixture.stationGroup] = nil end
      if fixture.depot then components.VEHICLE_DEPOT[fixture.depot] = nil end
      if fixture.asset then components.ASSET_GROUP[fixture.asset] = nil end
      for _, node in ipairs(fixture.nodes or {}) do components.BASE_NODE[node.id] = nil end
      for _, edge in ipairs(fixture.edges or {}) do
        components.BASE_EDGE[edge.id] = nil
        components.BASE_EDGE_TRACK[edge.id] = nil
        components.BASE_EDGE_STREET[edge.id] = nil
        components.PLAYER_OWNED[edge.id] = nil
      end
    end,
    setPlayer = function(entity, player)
      components.PLAYER_OWNED[entity] = { player = player }
      local fixture = (stationBuildFixture and entity == stationBuildFixture.construction and stationBuildFixture)
        or (depotBuildFixture and entity == depotBuildFixture.construction and depotBuildFixture)
        or (assetBuildFixture
          and entity == (assetBuildFixture.root or assetBuildFixture.construction) and assetBuildFixture)
      if fixture then
        for _, edge in ipairs(fixture.edges or {}) do
          if components.BASE_EDGE[edge.id] then
            components.PLAYER_OWNED[edge.id] = { player = player }
          end
        end
      end
    end,
  },
}

api = {
  res = {
    trackTypeRep = { find = function(name)
      return ({ ["standard.lua"] = 0, ["high_speed.lua"] = 1 })[name] or -1
    end, getAll = function() return { "standard.lua", "high_speed.lua" } end },
    streetTypeRep = { find = function(name)
      return ({ ["standard/town_small.lua"] = 0 })[name] or -1
    end, getAll = function() return { "standard/town_small.lua" } end },
    modelRep = { find = function(name)
      return name == "railroad/signal_path_a.mdl" and 10 or -1
    end, getAll = function() return { "railroad/signal_path_a.mdl" } end },
    constructionRep = { find = function(name)
      return type(name) == "string" and name:match("%.con$") and 1 or -1
    end },
    moduleRep = { find = function(name)
      return type(name) == "string" and name:match("%.module$") and 1 or -1
    end },
  },
  type = {
    ComponentType = {
      NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
      VEHICLE_DEPOT = "VEHICLE_DEPOT", CONSTRUCTION = "CONSTRUCTION",
      ASSET_GROUP = "ASSET_GROUP", SIGNAL_LIST = "SIGNAL_LIST",
      STATION_GROUP = "STATION_GROUP", STATION = "STATION", BASE_EDGE = "BASE_EDGE",
      BASE_EDGE_TRACK = "BASE_EDGE_TRACK", BASE_EDGE_STREET = "BASE_EDGE_STREET",
      BASE_NODE = "BASE_NODE", SIM_BUILDING = "SIM_BUILDING", TOWN = "TOWN",
      PLAYER = "PLAYER", PLAYER_OWNED = "PLAYER_OWNED",
    },
    JournalEntryCategory = { new = function() return {} end },
    JournalEntry = { new = function() return {} end },
  },
  engine = {
    entityExists = function(id)
      if players[id] then return true end
      for _, values in pairs(components) do if values[id] then return true end end
      return false
    end,
    getComponent = function(id, kind) return components[kind] and components[kind][id] or nil end,
    forEachEntityWithComponent = function(callback, kind)
      for id in pairs(components[kind] or {}) do callback(id) end
    end,
    system = {
      lineSystem = { getLines = function() return {} end },
      transportVehicleSystem = { getLineVehicles = function() return {} end },
      townBuildingSystem = { getLandUsePersonCapacities = function() return { 100, 100, 100 } end },
      stationSystem = { getStation2TownMap = function() return {} end },
      stationGroupSystem = { getStationGroup = function() return nil end },
    },
  },
  cmd = {
    make = {
      buildProposal = function() return {} end,
      bookJournalEntry = function(player, journal) return { player = player, journal = journal } end,
      sendScriptEvent = function() return {} end,
      developTown = function() return {} end,
      setSimBuildingManualDevelopment = function() return {} end,
      setCalendarSpeed = function() return {} end,
      setGameSpeed = function(speed) return { speed = speed } end,
    },
    sendCommand = function(command, callback)
      if command and command.player and command.journal and players[command.player] then
        players[command.player].balance = players[command.player].balance + command.journal.amount
        journalCommands = journalCommands + 1
      end
      if callback then callback(command, true) end
    end,
  },
}

-- A populated save can retain an old hot-seat/control player that owns no
-- assets while its two real companies still own infrastructure. Do not count
-- that selected desk as a third asset owner and reject a valid two-player map.
components.BASE_NODE[93] = { position = { x = 10, y = 0, z = 0 } }
components.BASE_NODE[94] = { position = { x = 60, y = 0, z = 0 } }
components.BASE_EDGE[95] = { node0 = 93, node1 = 94 }
components.BASE_EDGE_TRACK[95] = { trackType = 0, catenary = false }
components.PLAYER_OWNED[95] = { player = 101 }
local worldModule = require "tpf2_mp/world"
local deskSeedState = {}
local deskSeeded, deskSeedSummary = worldModule.seedInitialNetworkOwnership(
  deskSeedState, 2, 999
)
assert(deskSeeded and deskSeedSummary.sourceOwnerCount == 2
    and deskSeedSummary.selectedPlayerOwnsAssets == false
    and deskSeedState.logicalOwners["92"] == "company:1"
    and deskSeedState.logicalOwners["95"] == "company:2",
  "an unowned selected desk was miscounted as a third starting asset owner")
components.BASE_NODE[93], components.BASE_NODE[94] = nil, nil
components.BASE_EDGE[95], components.BASE_EDGE_TRACK[95], components.PLAYER_OWNED[95] = nil, nil, nil

-- A legacy hot-seat save can have two actual company owners plus a selected
-- turn desk that still holds physical residue. Persisted company-player hints
-- define the two companies; an explicit logical hint recovers desk-held
-- private property while unrelated desk residue stays public/unassigned.
components.BASE_NODE[93] = { position = { x = 10, y = 0, z = 0 } }
components.BASE_NODE[94] = { position = { x = 60, y = 0, z = 0 } }
components.BASE_EDGE[95] = { node0 = 93, node1 = 94 }
components.BASE_EDGE_TRACK[95] = { trackType = 0, catenary = false }
components.PLAYER_OWNED[95] = { player = 101 }
components.ASSET_GROUP[98] = { assets = {} }
components.ASSET_GROUP[99] = { assets = {} }
components.PLAYER_OWNED[98] = { player = 999 }
components.PLAYER_OWNED[99] = { player = 999 }
local hintedSeedState = {
  startingOwnershipHints = {
    schemaVersion = 1,
    companyPlayerIds = { 100, 101 },
    logicalOwners = { ["98"] = "company:1" },
  },
}
local hintedSeeded, hintedSummary = worldModule.seedInitialNetworkOwnership(
  hintedSeedState, 2, 999
)
assert(hintedSeeded and hintedSummary.seedSource == "saved-company-hints"
    and hintedSummary.sourceOwnerCount == 2
    and hintedSummary.selectedPlayerOwnsAssets == true
    and hintedSummary.unmappedSourceOwnerCount == 1
    and hintedSummary.mappedLegacyEntities == 1
    and hintedSeedState.logicalOwners["92"] == "company:1"
    and hintedSeedState.logicalOwners["95"] == "company:2"
    and hintedSeedState.logicalOwners["98"] == "company:1"
    and hintedSeedState.logicalOwners["99"] == nil,
  "saved company hints did not separate real owners from legacy desk residue")
components.BASE_NODE[93], components.BASE_NODE[94] = nil, nil
components.BASE_EDGE[95], components.BASE_EDGE_TRACK[95], components.PLAYER_OWNED[95] = nil, nil, nil
components.ASSET_GROUP[98], components.ASSET_GROUP[99] = nil, nil
components.PLAYER_OWNED[98], components.PLAYER_OWNED[99] = nil, nil

local sequenceOffset = 0
local function writeOrdered(seq, kind, originPeer, action, originLocalSeq)
  seq = seq + sequenceOffset
  local envelope = {
    protocol = 1,
    session = "network-company-map",
    seq = seq,
    kind = kind,
    origin_peer = originPeer,
    tick = seq,
    payload = { action = action },
  }
  if kind == "commit" then envelope.origin_local_seq = originLocalSeq or seq end
  envelope.checksum = hash.value(envelope)
  local path = string.format("%s/game_inbox/%012d.json", bridgeRoot, seq)
  local file = assert(io.open(path, "wb"))
  file:write(json.encode(envelope) .. "\n")
  file:close()
end

local function writeCommit(seq, originPeer, action, originLocalSeq)
  return writeOrdered(seq, "commit", originPeer, action, originLocalSeq)
end

local function proposalId(peer, logicalSeq)
  return "network-company-map:" .. tostring(peer) .. ":" .. tostring(logicalSeq + sequenceOffset)
end

local function writeConsensus(seq, record, authoritativeFinanceDelta)
  local completion = assert(record.completion, "network proposal did not emit a completion report")
  return writeOrdered(seq, "control", "player1", {
    type = "network.proposal_outcome",
    proposalId = record.proposalId,
    commitSeq = record.commitSeq,
    proposalDigest = completion.proposalDigest,
    success = true,
    resultDigest = completion.resultDigest,
    coreDigest = completion.coreDigest,
    financeDelta = authoritativeFinanceDelta ~= nil and authoritativeFinanceDelta or completion.financeDelta,
    peers = { "player1", "player2" },
  })
end

local function writeCheckpointConsensus(seq, saved, boundarySeq)
  boundarySeq = boundarySeq + sequenceOffset
  local record = assert(saved.world.checkpointConsensus.byBoundary[tostring(boundarySeq)],
    "local checkpoint barrier is missing")
  assert(record.exported == true and record.convergenceKey and record.coreDigest,
    "local checkpoint barrier was not exported")
  return writeOrdered(seq, "control", "player1", {
    type = "network.checkpoint_outcome",
    boundarySeq = boundarySeq,
    reason = record.reason,
    proposalId = record.proposalId,
    success = true,
    convergenceKey = record.convergenceKey,
    coreDigest = record.coreDigest,
    financialDigest = record.financialDigest,
    modelDigest = saved.checkpoint.lastModelDigest,
    canonicalDigest = hash.value(canonical.digestView(saved.canonical)),
    peers = { "player1", "player2" },
  })
end

local companionStatus = assert(io.open(
  bridgeRoot .. "/companion_state/companion_status.json", "wb"))
companionStatus:write(json.encode({
  session = "network-company-map", peer = "player2", status = "connected",
  connected = true,
}) .. "\n")
companionStatus:close()

assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))()
local script = assert(data())
script.init()
assert(buildGateEnables == 1 and commandGateEnables == 1,
  "player2 network startup did not enable both native authority gates")

-- This integration fixture exercises only the engine/game-script half of the
-- runtime, so it has no GUI state in which to construct a typed
-- SimpleProposal.ConstructionEntity. Reproduce the production fail-safe: the
-- GUI attests that the world is unchanged and asks the engine to use the
-- legacy helper. Exact typed replay is covered by the GUI/materializer tests
-- and the disposable supported-API live probe.
local function requestConstructionHelperFallback(record)
  assert(record and record.status == "queued"
      and record.replayPath == "gui-build-proposal",
    "schema-7 construction was not primed for exact GUI replay")
  script.handleEvent("test", "tpf2mp", "proposal.result", {
    proposalId = record.proposalId,
    success = false,
    fallbackHelper = true,
    worldUnchanged = true,
    error = "fixture has no GUI state",
  })
  local fallback = assert(script.save().world.proposals.byId[record.proposalId])
  assert(fallback.status == "queued" and fallback.replayPath == "helper-fallback",
    "unchanged-world construction fallback did not return to the helper queue")
end

writeCommit(1, "player1", { type = "match.initialise" })
script.update()
local initialized = script.save()
assert(initialized.initialized, "player2 did not apply host match initialization")
assert(initialized.companies["company:1"].playerId == 101,
  "player2 mapped its original native player to remote Company 1")
assert(initialized.companies["company:2"].playerId == 100,
  "player2 did not map its original native player to canonical Company 2")
assert(canonical.resolveLocal(initialized.canonical, "company:1") == 101)
assert(canonical.resolveLocal(initialized.canonical, "company:2") == 100)
assert(initialized.world.logicalOwnershipAuthoritative == true,
  "network logical ownership was not made authoritative")
assert(initialized.world.logicalOwners["92"] == "company:1",
  "player2 reassigned a shared pre-existing track to its local canonical company")
assert(initialized.world.logicalOwners["90"] == "company:1"
  and initialized.world.logicalOwners["91"] == "company:1",
  "pre-existing private track endpoints were not assigned canonical custody")
assert(initialized.world.initialNetworkOwnership
  and initialized.world.initialNetworkOwnership.companies["company:1"].total == 3
  and initialized.world.initialNetworkOwnership.trackedNodes == 2,
  "starting-save ownership manifest did not capture the pre-existing track")
assert(components.PLAYER_OWNED[92].player == 100,
  "network bootstrap called the invalid legacy BASE_EDGE owner setter")
assert(components.PLAYER_OWNED[96].player == 101
    and components.PLAYER_OWNED[97].player == 101,
  "player2 retained remote Company 1 line/vehicle in its stock managers")
assert(initialized.lastResult and initialized.lastResult.nativeOwnershipProjection
    and initialized.lastResult.nativeOwnershipProjection.projected == 2
    and initialized.lastResult.nativeOwnershipProjection.retainedEdges == 1,
  "network match did not report its native manager ownership projection")
local initialTrack
for _, object in ipairs(initialized.probes.structural.objects or {}) do
  if object.cid and object.kind == "edge" then initialTrack = object; break end
end
assert(initialTrack and initialTrack.owner == "company:1",
  "structural consensus view used player2's machine-local owner for the starting track")
local initialTrackBinding = assert(initialized.canonical.byCanonical[initialTrack.cid])
assert(initialTrackBinding.metadata and initialTrackBinding.metadata.manifestBound == true,
  "private starting track was not bound by the cross-peer world manifest")
assert(players[100].balance == 30000000 and players[101].balance == 5000000
    and journalCommands == 0,
  "network initialization mutated a native wallet inside the ordered commit")
assert(players[100].loan == 30000000 and players[101].loan == 0,
  "network starting-cash normalization unexpectedly mutated engine-local loan principal")
assert(initialized.world.checkpointConsensus.byBoundary["1"].status == "pending",
  "network match initialization did not create a checkpoint barrier")
local initialCheckpoint
for sequence = 1, initialized.bridge.emitted do
  local file = io.open(string.format("%s/game_outbox/%012d.json", bridgeRoot, sequence), "rb")
  if file then
    local envelope = json.decode(file:read("*a"))
    file:close()
    if envelope.kind == "checkpoint" then initialCheckpoint = envelope.payload end
  end
end
assert(initialCheckpoint and initialCheckpoint.model.match.startedTick == nil,
  "machine-local match tick leaked into the canonical model checkpoint")
assert(initialCheckpoint.financial.companies["company:1"].loan == 0
  and initialCheckpoint.financial.companies["company:2"].loan == 0,
  "engine-local seed loan leaked into canonical network finance")
writeCheckpointConsensus(2, initialized, 1)
script.update()
assert(script.save().world.checkpointConsensus.byBoundary["1"].status == "complete",
  "network match-initialization checkpoint did not reach consensus")
script.update()
assert(players[100].balance == 5000000 and players[101].balance == 5000000
    and journalCommands == 1,
  "quiescent network housekeeping did not normalize the deferred native wallet")

-- Incomplete construction captures must fail closed and leave a bounded bridge diagnostic
-- immediately; a live click must never disappear without inspectable evidence.
local emittedBeforeCodecFailure = script.save().bridge.emitted
script.handleEvent("test", "tpf2mp", "intent", {
  type = "proposal.capture",
  companyCid = "company:2",
  proposalSnapshot = {
    __observedCost = 100,
    constructionsToAdd = {{ fileName = "station/unsupported.con" }},
  },
})
local codecFailureState = script.save()
assert(codecFailureState.probes.capture.proposalCodecFailureCount == 1
  and codecFailureState.probes.capture.lastProposalCodecFailure.snapshotDigest,
  "unsupported proposal did not persist its codec failure")
assert(tostring(codecFailureState.lastError):find("construction transform is not a finite 4x4 matrix", 1, true),
  "incomplete construction proposal did not expose its precise codec error")
local codecFailureFile = assert(io.open(string.format(
  "%s/game_outbox/%012d.json", bridgeRoot, emittedBeforeCodecFailure + 1), "rb"))
local codecFailureEnvelope = json.decode(codecFailureFile:read("*a"))
codecFailureFile:close()
assert(codecFailureEnvelope.kind == "telemetry"
  and codecFailureEnvelope.payload.type == "proposal-codec-failure"
  and codecFailureEnvelope.payload.snapshotDigest
  and codecFailureEnvelope.payload.diagnostic.counts.constructionsToAdd == 1,
  "unsupported proposal disappeared without a bounded bridge diagnostic")

local transaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:2",
  cost = 0,
  nodes = {
    { slot = "node:1", position = { x = 0, y = 0, z = 0 } },
    { slot = "node:2", position = { x = 50, y = 0, z = 0 } },
  },
  edges = {{
    slot = "edge:1", carrier = "track",
    node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
    tangent0 = { x = 50, y = 0, z = 0 }, tangent1 = { x = 50, y = 0, z = 0 },
    type = 0, typeIndex = 0, resource = { index = 0, name = "standard.lua" }, catenary = false,
    private = true, logicalOwnerCid = "company:2",
  }},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
}
transaction.digest = proposalCodec.digest(transaction)
transaction.transactionId = "proposal:" .. transaction.digest
writeCommit(3, "player2", { type = "proposal.build", transaction = transaction })
script.update()
local queued = script.save()
local record = queued.world.proposals.byId[proposalId("player2", 3)]
assert(record and record.status == "queued", "player2 proposal was not queued under its authoritative event ID")
assert(record.companyCid == "company:2" and record.issuerPlayerId == 100
  and record.nativeOwnerPlayerId == 100,
  "player2's own proposal did not bind its issuer and native owner to Company 2")

-- Vanilla clicks can arrive after the native gate suppressed them but while a
-- prior physical/checkpoint barrier is still pending. Preserve a bounded FIFO
-- and submit its head after authority becomes idle instead of silently losing
-- clicks or reordering them.
local deferredCapture = {
  type = "proposal.capture",
  companyCid = "company:2",
  proposalSnapshot = {
    __observedCost = 12345,
    streetProposal = {
      nodesToAdd = {
        { entity = -11, comp = { position = { x = 200, y = 0, z = 0 } } },
        { entity = -12, comp = { position = { x = 240, y = 0, z = 0 } } },
      },
      edgesToAdd = {{
        entity = -10, type = 1,
        comp = {
          node0 = -11, node1 = -12,
          tangent0 = { x = 40, y = 0, z = 0 },
          tangent1 = { x = 40, y = 0, z = 0 },
          type = 0, typeIndex = 0,
        },
        trackEdge = { trackType = 0, catenary = false },
        playerOwned = { player = 100 },
      }},
      nodesToRemove = {}, edgesToRemove = {},
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    constructionsToAdd = {}, constructionsToRemove = {},
  },
}
local emittedBeforeDeferred = script.save().bridge.emitted
script.handleEvent("test", "tpf2mp", "intent", deferredCapture)
local deferredState = script.save()
local deferredQueuedTick = deferredState.tick
assert(deferredState.lastResult and deferredState.lastResult.deferred == true
  and deferredState.lastResult.queued == true and deferredState.lastResult.queuePosition == 1
  and deferredState.lastError == nil,
  "busy physical barrier did not retain the first deferred build")
assert(deferredState.bridge.emitted == emittedBeforeDeferred,
  "deferred build escaped to the companion before the physical barrier closed")
local rejectIfBusyCapture = {}
for key, value in pairs(deferredCapture) do rejectIfBusyCapture[key] = value end
rejectIfBusyCapture.queuePolicy = "reject-if-busy"
script.handleEvent("test", "tpf2mp", "intent", rejectIfBusyCapture)
local busyRejectedState = script.save()
assert(busyRejectedState.lastResult and busyRejectedState.lastResult.rejected == true
    and busyRejectedState.lastResult.busy == true
    and busyRejectedState.lastResult.queued == false
    and tostring(busyRejectedState.lastError):find("not queued", 1, true),
  "construction-only busy policy did not reject instead of deferring")
assert(busyRejectedState.bridge.emitted == emittedBeforeDeferred,
  "busy-rejected construction escaped to the companion")
deferredCapture.proposalSnapshot.__observedCost = 54321
deferredCapture.proposalSnapshot.streetProposal.nodesToAdd[1].comp.position.x = 300
deferredCapture.proposalSnapshot.streetProposal.nodesToAdd[2].comp.position.x = 340
script.handleEvent("test", "tpf2mp", "intent", deferredCapture)
local secondDeferredState = script.save()
assert(secondDeferredState.lastResult and secondDeferredState.lastResult.deferred == true
  and secondDeferredState.lastResult.queuePosition == 2
  and secondDeferredState.lastResult.queueDepth == 2
  and secondDeferredState.lastError == nil,
  "a second busy build was not appended to the bounded FIFO")
assert(secondDeferredState.bridge.emitted == emittedBeforeDeferred,
  "a queued follower escaped before the physical barrier closed")
script.handleEvent("test", "tpf2mp", "intent", {
  type = "fare.adjust", lineCid = "line:blocked", deltaCents = 1,
})
assert(tostring(script.save().lastError or ""):find("awaiting two%-peer consensus") ~= nil,
  "game state allowed a dependent network intent while physical completion was pending")
components.BASE_NODE[301] = { position = { x = 0, y = 0, z = 0 } }
components.BASE_NODE[302] = { position = { x = 50, y = 0, z = 0 } }
components.BASE_EDGE[303] = { node0 = 301, node1 = 302 }
components.BASE_EDGE_TRACK[303] = { trackType = 0, catenary = false }
components.PLAYER_OWNED[303] = { player = 100 }
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = record.proposalId,
  success = true,
  createdNodeIds = { 301, 302 },
  createdEdgeIds = { 303 },
})
for _ = 1, 181 do script.update() end
local ownApplied = script.save().world.proposals.byId[record.proposalId]
assert(ownApplied.status == "applied" and ownApplied.completionEmitted == true,
  "player2 proposal did not emit its second-phase physical completion")
local ownAppliedState = script.save()
assert(ownAppliedState.world.logicalOwners["301"] == "company:2"
  and ownAppliedState.world.logicalOwners["302"] == "company:2",
  "private proposal did not assign logical custody to its created endpoints")
for _, nodeId in ipairs({ 301, 302 }) do
  local nodeCid = canonical.resolveCanonical(ownAppliedState.canonical, "node", nodeId)
  assert(nodeCid and ownAppliedState.canonical.byCanonical[nodeCid].metadata.owner == "company:2",
    "private proposal node binding did not retain its canonical owner")
end
writeConsensus(4, ownApplied)
script.update()
local ownConsensus = script.save().world.proposalConsensus.byId[record.proposalId]
assert(ownConsensus and ownConsensus.status == "complete" and ownConsensus.success == true,
  "player2 did not apply the host's ordered physical-consensus outcome")
script.handleEvent("test", "tpf2mp", "intent", {
  type = "fare.adjust", lineCid = "line:blocked", deltaCents = 1,
})
assert(tostring(script.save().lastError or ""):find("checkpoint boundary") ~= nil,
  "game state allowed a dependent network intent before checkpoint consensus")
writeCheckpointConsensus(5, script.save(), 4)
script.update()
local releasedState = script.save()
assert(releasedState.lastResult and releasedState.lastResult.deferred == true
  and releasedState.lastResult.deferredFromTick == deferredQueuedTick
  and releasedState.lastResult.queueRemaining == 1
  and releasedState.lastError == nil,
  "FIFO head was not released alone after checkpoint consensus")
local deferredEnvelope
for sequence = emittedBeforeDeferred + 1, releasedState.bridge.emitted do
  local file = io.open(string.format("%s/game_outbox/%012d.json", bridgeRoot, sequence), "rb")
  if file then
    local envelope = json.decode(file:read("*a"))
    file:close()
    if envelope.kind == "intent" and envelope.payload and envelope.payload.action
      and envelope.payload.action.type == "proposal.prepare" then
      deferredEnvelope = envelope
    end
  end
end
assert(deferredEnvelope and deferredEnvelope.payload.action.transaction.companyCid == "company:2"
  and deferredEnvelope.payload.action.transaction.cost == 12345
  and deferredEnvelope.payload.action.proposalSnapshot == nil,
  "released deferred build was not canonicalized into one portable intent")

-- Ordering the released head must hold its follower until the first physical
-- result and checkpoint both close. Then the second independent capture is
-- canonicalized and emitted, preserving FIFO order and its original payload.
local firstDeferredBuild = json.decode(json.encode(deferredEnvelope.payload.action))
firstDeferredBuild.type = "proposal.build"
writeCommit(6, "player2", firstDeferredBuild, deferredEnvelope.local_seq)
script.update()
local firstDeferredRecord = script.save().world.proposals.byId[proposalId("player2", 6)]
assert(firstDeferredRecord and firstDeferredRecord.status == "queued",
  "ordered FIFO head was not queued for physical replay")
components.BASE_NODE[501] = { position = { x = 200, y = 0, z = 0 } }
components.BASE_NODE[502] = { position = { x = 240, y = 0, z = 0 } }
components.BASE_EDGE[503] = { node0 = 501, node1 = 502 }
components.BASE_EDGE_TRACK[503] = { trackType = 0, catenary = false }
components.PLAYER_OWNED[503] = { player = 100 }
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = firstDeferredRecord.proposalId,
  success = true,
  createdNodeIds = { 501, 502 },
  createdEdgeIds = { 503 },
})
local firstDeferredApplied = script.save().world.proposals.byId[firstDeferredRecord.proposalId]
assert(firstDeferredApplied.status == "applied" and firstDeferredApplied.completionEmitted == true,
  "FIFO head did not complete immediately from its settled GUI finance sample")
writeConsensus(7, firstDeferredApplied, -12345)
script.update()
writeCheckpointConsensus(8, script.save(), 7)
script.update()
local secondReleasedState = script.save()
assert(secondReleasedState.lastResult and secondReleasedState.lastResult.deferred == true
  and secondReleasedState.lastResult.queueRemaining == 0,
  "FIFO follower was not released after the head checkpoint")
local secondDeferredEnvelope
for sequence = deferredEnvelope.local_seq + 1, secondReleasedState.bridge.emitted do
  local file = io.open(string.format("%s/game_outbox/%012d.json", bridgeRoot, sequence), "rb")
  if file then
    local envelope = json.decode(file:read("*a"))
    file:close()
    if envelope.kind == "intent" and envelope.payload and envelope.payload.action
      and envelope.payload.action.type == "proposal.prepare" then
      secondDeferredEnvelope = envelope
    end
  end
end
assert(secondDeferredEnvelope
  and secondDeferredEnvelope.payload.action.transaction.cost == 54321
  and secondDeferredEnvelope.payload.action.transaction.nodes[1].position.x == 300
  and secondDeferredEnvelope.payload.action.transaction.nodes[2].position.x == 340,
  "FIFO follower was overwritten, reordered, or emitted with stale geometry")

-- The follower has now proved FIFO emission, but this fixture does not replay
-- its physical graph. Close its real awaiting-order latch exactly as the host
-- would before introducing the independent remote-proposal scenarios below.
writeOrdered(9, "control", "player1", {
  type = "network.intent_rejected",
  originPeer = "player2",
  originLocalSeq = secondDeferredEnvelope.local_seq,
  actionType = "proposal.prepare",
  errorCode = "fixture intentionally ends after FIFO emission",
})
script.update()
sequenceOffset = 1

-- Replay a host-owned proposal on player2. The command still issues through
-- this machine's current player (100), while PlayerOwned must target the local
-- native representative of canonical Company 1 (101). Conflating these two
-- IDs is the exact failure that previously let remote replays steal assets.
local remoteTransaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:1",
  cost = 25000,
  nodes = {
    { slot = "node:1", position = { x = 100, y = 0, z = 0 } },
    { slot = "node:2", position = { x = 150, y = 0, z = 0 } },
  },
  edges = {{
    slot = "edge:1", carrier = "track",
    node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
    tangent0 = { x = 50, y = 0, z = 0 }, tangent1 = { x = 50, y = 0, z = 0 },
    type = 0, typeIndex = 0, resource = { index = 0, name = "standard.lua" }, catenary = true,
    private = true, logicalOwnerCid = "company:1",
  }},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
}
remoteTransaction.digest = proposalCodec.digest(remoteTransaction)
remoteTransaction.transactionId = "proposal:" .. remoteTransaction.digest
writeCommit(9, "player1", { type = "proposal.build", transaction = remoteTransaction })
script.update()
local remoteQueued = script.save()
local remoteRecord = remoteQueued.world.proposals.byId[proposalId("player1", 9)]
assert(remoteRecord and remoteRecord.status == "queued", "remote Company 1 proposal was not queued on player2")
assert(remoteRecord.companyCid == "company:1" and remoteRecord.issuerPlayerId == 100,
  "remote proposal did not preserve player2's actual local command issuer")
assert(remoteRecord.nativeOwnerPlayerId == 101 and remoteRecord.nativeOwnerPlayerId ~= remoteRecord.issuerPlayerId,
  "remote proposal conflated the local payer with Company 1's native output owner")
components.BASE_NODE[401] = { position = { x = 100, y = 0, z = 0 } }
components.BASE_NODE[402] = { position = { x = 150, y = 0, z = 0 } }
components.BASE_EDGE[403] = { node0 = 401, node1 = 402 }
components.BASE_EDGE_TRACK[403] = { trackType = 0, catenary = true }
components.PLAYER_OWNED[403] = { player = 101 }
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = remoteRecord.proposalId,
  success = true,
  createdNodeIds = { 401, 402 },
  createdEdgeIds = { 403 },
})
for _ = 1, 31 do script.update() end
local remoteApplied = script.save().world.proposals.byId[remoteRecord.proposalId]
assert(remoteApplied.status == "applied" and remoteApplied.completion.nativeOwnerBalance == nil,
  "remote proposal did not finalise without serialising native balance/player data")
local remoteAppliedState = script.save()
assert(remoteAppliedState.world.logicalOwners["401"] == "company:1"
  and remoteAppliedState.world.logicalOwners["402"] == "company:1",
  "remote private proposal did not reproduce endpoint custody")
assert(components.PLAYER_OWNED[403].player == 101,
  "remote Company 1 proposal was physically assigned to player2's Company 2")
writeConsensus(10, remoteApplied, -25000)
script.update()
assert(players[101].balance == 4975000 and players[100].balance == 4987655,
  "ordered origin finance did not normalize the remote canonical company wallet")
writeCheckpointConsensus(11, script.save(), 10)
script.update()
local final = script.save()
local remoteConsensus = final.world.proposalConsensus.byId[remoteRecord.proposalId]
assert(remoteConsensus and remoteConsensus.status == "complete" and remoteConsensus.success == true,
  "remote Company 1 proposal did not reach ordered physical consensus")
assert(remoteConsensus.errorCode == nil
    and final.world.checkpointConsensus.lastOutcome.errorCode == nil,
  "successful physical/checkpoint consensus retained a false error code")
assert(final.world.proposalConsensus.completed == 3 and final.world.proposalConsensus.failed == 0
  and final.world.proposalConsensus.sessionFault == nil,
  "network consensus counters or session health are incorrect")
assert(final.world.checkpointConsensus.completed == 4 and final.world.checkpointConsensus.failed == 0,
  "network checkpoint-barrier counters are incorrect")
assert(final.lastError == nil, "player2 company mapping/consensus left an engine error")

-- Pure upgrades replace one or more edges without creating BASE_NODEs. Lua
-- serialises that empty node array as `{}` on the live wire. Replay a remote
-- Company 1 track-type/catenary change all the way through output rebinding,
-- physical consensus, finance routing, and the checkpoint barrier.
local oldEdgeCid = assert(canonical.resolveCanonical(final.canonical, "edge", 403),
  "remote edge had no canonical identity before its upgrade")
local node0Cid = assert(canonical.resolveCanonical(final.canonical, "node", 401))
local node1Cid = assert(canonical.resolveCanonical(final.canonical, "node", 402))
local upgradeTransaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:1",
  cost = 1234,
  nodes = {},
  edges = {{
    slot = "edge:1", carrier = "track",
    node0 = { cid = node0Cid }, node1 = { cid = node1Cid },
    tangent0 = { x = 50, y = 0, z = 0 }, tangent1 = { x = 50, y = 0, z = 0 },
    type = 0, typeIndex = 0, resource = { index = 1, name = "high_speed.lua" }, catenary = false,
    private = true, logicalOwnerCid = "company:1",
  }},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = { oldEdgeCid }, nodes = {} },
}
upgradeTransaction.digest = proposalCodec.digest(upgradeTransaction)
upgradeTransaction.transactionId = "proposal:" .. upgradeTransaction.digest
assert(json.encode(upgradeTransaction):find('"nodes":{}', 1, true),
  "integration upgrade did not preserve the live empty-node spelling")
writeCommit(12, "player1", { type = "proposal.build", transaction = upgradeTransaction })
script.update()
local upgradeQueuedState = script.save()
local upgradeRecord = upgradeQueuedState.world.proposals.byId[proposalId("player1", 12)]
assert(upgradeRecord and upgradeRecord.status == "queued",
  "zero-node remote track upgrade was not accepted into the canonical queue")
assert(#upgradeRecord.transaction.nodes == 0 and upgradeRecord.localRefs[node0Cid] == 401
  and upgradeRecord.localRefs[node1Cid] == 402,
  "zero-node track upgrade did not resolve its existing canonical endpoints")

-- Build 35924 may update/recycle the removed edge's numeric entity ID in the
-- same native command. Reproduce that live behavior: local edge 403 now
-- represents the upgraded output even though its old canonical identity is
-- one of the transaction inputs.
components.BASE_EDGE[403] = { node0 = 401, node1 = 402 }
components.BASE_EDGE_TRACK[403] = { trackType = 1, catenary = false }
components.PLAYER_OWNED[403] = { player = 101 }
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = upgradeRecord.proposalId,
  success = true,
  createdNodeIds = {},
  createdEdgeIds = { 403 },
})
for _ = 1, 31 do script.update() end
local upgradeAppliedState = script.save()
local upgradeApplied = upgradeAppliedState.world.proposals.byId[upgradeRecord.proposalId]
assert(upgradeApplied.status == "applied" and upgradeApplied.completionEmitted == true,
  "zero-node track upgrade did not emit its physical completion")
assert(#(upgradeApplied.result.outputs or {}) == 1
  and upgradeApplied.result.outputs[1].kind == "edge",
  "zero-node track upgrade emitted unexpected node outputs")
assert(canonical.resolveLocal(upgradeAppliedState.canonical, oldEdgeCid) == nil,
  "replaced canonical edge still points at the retired local edge")
local upgradedEdgeCid = assert(canonical.resolveCanonical(upgradeAppliedState.canonical, "edge", 403),
  "replacement edge was not rebound canonically")
assert(upgradedEdgeCid ~= oldEdgeCid and upgradeAppliedState.world.logicalOwners["403"] == "company:1"
  and components.PLAYER_OWNED[403].player == 101,
  "replacement edge did not preserve Company 1's logical/native custody")
assert(canonical.resolveLocal(upgradeAppliedState.canonical, node0Cid) == 401
  and canonical.resolveLocal(upgradeAppliedState.canonical, node1Cid) == 402,
  "track upgrade disturbed its populated existing endpoint identities")

writeConsensus(13, upgradeApplied, -1234)
script.update()
assert(players[101].balance == 4973766 and players[100].balance == 4987655,
  "track upgrade cost was not routed only to its canonical owner")
writeCheckpointConsensus(14, script.save(), 13)
script.update()
local upgradedFinal = script.save()
assert(upgradedFinal.world.proposalConsensus.completed == 4
  and upgradedFinal.world.proposalConsensus.failed == 0
  and upgradedFinal.world.proposalConsensus.sessionFault == nil,
  "zero-node track upgrade did not reach healthy physical consensus")
assert(upgradedFinal.world.checkpointConsensus.completed == 5
  and upgradedFinal.world.checkpointConsensus.failed == 0,
  "zero-node track upgrade did not close its checkpoint barrier")
assert(upgradedFinal.lastError == nil, "zero-node track upgrade left an engine error")

-- Schema 4 replays the measured smallest stock modular passenger station on
-- the engine thread and binds its whole compound graph as one physical result.
local stationNodes, stationEdges = {}, {}
for index = 1, 13 do
  stationNodes[index] = {
    slot = "node:" .. index,
    position = { x = 600 + index * 2, y = 100, z = 5 },
  }
end
for index = 1, 12 do
  stationEdges[index] = {
    slot = "edge:" .. index, carrier = "track",
    node0 = { slot = "node:" .. index }, node1 = { slot = "node:" .. (index + 1) },
    tangent0 = { x = 2, y = 0, z = 0 }, tangent1 = { x = 2, y = 0, z = 0 },
    type = 0, typeIndex = -1, resource = { index = 1, name = "high_speed.lua" }, catenary = true,
    private = true, logicalOwnerCid = "company:2",
  }
end
local stationPrefix = "station/rail/modular_station/"
local stationTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2",
  cost = 1000,
  nodes = stationNodes,
  edges = stationEdges,
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
  constructions = {{
    slot = "construction:1", mode = "build", adapter = "stock-rail-station",
    kind = "rail_station", sourceCid = "", collateral = {},
    fileName = stationPrefix .. "modular_station.con",
    transform = { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 600, 100, 5, 1 },
    params = {
      year = 1992, seed = 2, trackType = 0, catenary = 1,
      length = 0, tracks = 0, paramX = 0, paramY = 0,
    },
    modules = {
      { slot = 3700000, name = stationPrefix .. "main_building_1_era_c.module", variant = 0, metadata = {} },
      { slot = 7400000, name = stationPrefix .. "platform_passenger_era_c.module", variant = 0, metadata = {} },
      { slot = 7400010, name = stationPrefix .. "platform_passenger_era_c.module", variant = 0, metadata = {} },
      { slot = 8401000, name = stationPrefix .. "platform_track_catenary.module", variant = 0, metadata = {} },
      { slot = 8401010, name = stationPrefix .. "platform_track_catenary.module", variant = 0, metadata = {} },
      { slot = 10400000, name = stationPrefix .. "platform_passenger_roof_era_c.module", variant = 0, metadata = {} },
      { slot = 10400010, name = stationPrefix .. "platform_passenger_roof_era_c.module", variant = 0, metadata = {} },
      { slot = 10800000, name = stationPrefix .. "addon_platform_passenger_stairs_era_c.module", variant = 0, metadata = {} },
    },
  }},
}
stationTransaction.digest = proposalCodec.digest(stationTransaction)
stationTransaction.transactionId = "proposal:" .. stationTransaction.digest
stationBuildFixture = {
  fileName = stationPrefix .. "modular_station.con", year = 1992,
  construction = 600, station = 601, stationGroup = 602,
  delayTopology = true,
  nodes = {}, edges = {},
}
for index, node in ipairs(stationNodes) do
  stationBuildFixture.nodes[index] = { id = 609 + index, position = node.position }
end
for index = 1, 12 do
  stationBuildFixture.edges[index] = {
    id = 629 + index,
    node0 = stationBuildFixture.nodes[index].id,
    node1 = stationBuildFixture.nodes[index + 1].id,
  }
end
local stationBalanceBefore = players[100].balance
writeCommit(15, "player2", { type = "proposal.build", transaction = stationTransaction })
script.update() -- ordered commit queues the transaction
requestConstructionHelperFallback(
  script.save().world.proposals.byId[proposalId("player2", 15)])
for _ = 1, 150 do script.update() end
local delayedStationState = script.save()
local delayedStationRecord = delayedStationState.world.proposals.byId[proposalId("player2", 15)]
assert(delayedStationRecord and delayedStationRecord.status == "building-construction"
    and delayedStationState.world.proposals.failed == 0,
  "valid delayed station graph was failed at the legacy 120-tick cutoff")
stationBuildFixture.delayTopology = false
components.STATION[stationBuildFixture.station] = { cargo = false }
components.STATION_GROUP[stationBuildFixture.stationGroup] = {
  stations = { stationBuildFixture.station },
}
for _, node in ipairs(stationBuildFixture.nodes) do
  components.BASE_NODE[node.id] = { position = node.position }
end
for _, edge in ipairs(stationBuildFixture.edges) do
  components.BASE_EDGE[edge.id] = { node0 = edge.node0, node1 = edge.node1 }
  components.BASE_EDGE_TRACK[edge.id] = {
    trackType = edge.trackType or 1,
    catenary = edge.catenary == nil and true or edge.catenary,
  }
  components.PLAYER_OWNED[edge.id] = { player = 100 }
end
for _ = 1, 6 do script.update() end -- delayed graph plus three-tick stabilization
local stationState = script.save()
local stationRecord = stationState.world.proposals.byId[proposalId("player2", 15)]
assert(stationRecord and stationRecord.status == "applied" and stationRecord.completionEmitted == true,
  "canonical station construction did not reach physical completion")
local stationTransitionEvent
for _, event in ipairs(stationState.eventLog.items or {}) do
  if event.action and event.action.type == "proposal.construction_step"
    and event.action.proposalId == stationRecord.proposalId
    and event.success == true and event.preDigest ~= event.postDigest then
    stationTransitionEvent = event
  end
end
assert(stationTransitionEvent and stationTransitionEvent.action.localOnly == true
  and stationTransitionEvent.commitSeq == nil,
  "station graph binding and finance mutation bypassed the local event chain")
assert(#stationRecord.result.outputs == 28,
  "station completion did not bind 13 nodes, 12 edges, construction, station, and station group")
assert(canonical.resolveCanonical(stationState.canonical, "construction", 600)
  and canonical.resolveCanonical(stationState.canonical, "station", 601)
  and canonical.resolveCanonical(stationState.canonical, "station_group", 602),
  "compound station identities were not bound canonically")
assert(stationState.world.logicalOwners["600"] == "company:2"
  and stationState.world.logicalOwners["601"] == "company:2"
  and stationState.world.logicalOwners["602"] == "company:2"
  and stationState.world.logicalOwners["630"] == "company:2",
  "compound station graph did not retain Company 2 logical custody")
assert(players[100].balance == stationBalanceBefore - 1000,
  "direct station replay did not normalize the native wallet to its signed quoted cost")
writeConsensus(16, stationRecord, -1000)
script.update()
writeCheckpointConsensus(17, script.save(), 16)
script.update()
local stationFinal = script.save()
local stationOutcomeEvent
for _, event in ipairs(stationFinal.eventLog.items or {}) do
  if event.action and event.action.type == "network.proposal_outcome"
    and event.action.proposalId == stationRecord.proposalId then
    stationOutcomeEvent = event
  end
end
assert(stationOutcomeEvent and stationOutcomeEvent.preDigest == stationTransitionEvent.postDigest,
  "station consensus did not continue from the recorded construction transition")
assert(stationFinal.world.proposalConsensus.completed == 5
  and stationFinal.world.proposalConsensus.failed == 0
  and stationFinal.world.checkpointConsensus.completed == 6
  and stationFinal.lastError == nil,
  "station physical/checkpoint consensus did not close cleanly")

-- Schema 5 carries a signal/waypoint as a canonical edge object bound to the
-- same replacement edge on every peer.
local signalTransaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:2",
  cost = 100,
  nodes = {
    { slot = "node:1", position = { x = 900, y = 0, z = 5 } },
    { slot = "node:2", position = { x = 950, y = 0, z = 5 } },
  },
  edges = {{
    slot = "edge:1", carrier = "track",
    node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
    tangent0 = { x = 50, y = 0, z = 0 }, tangent1 = { x = 50, y = 0, z = 0 },
    type = 0, typeIndex = -1, resource = { index = 0, name = "standard.lua" },
    catenary = false, private = true, logicalOwnerCid = "company:2",
  }},
  edgeObjects = {
    add = {{
      slot = "edge_object:1", edge = { slot = "edge:1" }, param = 0.5,
      oneWay = true, left = false, model = "railroad/signal_path_a.mdl", name = "S1",
      category = 2, logicalOwnerCid = "company:2", private = true,
    }},
    retain = {}, remove = {},
  },
  remove = { edges = {}, nodes = {} },
}
signalTransaction.digest = proposalCodec.digest(signalTransaction)
signalTransaction.transactionId = "proposal:" .. signalTransaction.digest
writeCommit(18, "player2", { type = "proposal.build", transaction = signalTransaction })
script.update()
local signalRecord = assert(script.save().world.proposals.byId[proposalId("player2", 18)])
components.BASE_NODE[8001] = { position = { x = 900, y = 0, z = 5 } }
components.BASE_NODE[8002] = { position = { x = 950, y = 0, z = 5 } }
components.BASE_EDGE[8003] = { node0 = 8001, node1 = 8002, objects = { { 8004, 2 } } }
components.BASE_EDGE_TRACK[8003] = { trackType = 0, catenary = false }
components.SIGNAL_LIST[8004] = { signals = { 8004 } }
components.PLAYER_OWNED[8003], components.PLAYER_OWNED[8004] = { player = 100 }, { player = 100 }
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = signalRecord.proposalId, success = true,
  createdNodeIds = { 8001, 8002 }, createdEdgeIds = { 8003 },
})
for _ = 1, 31 do script.update() end
signalRecord = assert(script.save().world.proposals.byId[signalRecord.proposalId])
assert(signalRecord.status == "applied" and #signalRecord.result.outputs == 4,
  "signal-bearing proposal did not bind its two nodes, edge, and edge object")
local signalState = script.save()
local signalCid = assert(canonical.resolveCanonical(signalState.canonical, "edge_object", 8004))
assert(signalState.world.logicalOwners["8004"] == "company:2"
  and signalState.world.pinnedCustody["8004"].cid == signalCid,
  "signal output did not retain Company 2 canonical custody")
writeConsensus(19, signalRecord, -100)
script.update()
writeCheckpointConsensus(20, script.save(), 19)
script.update()

-- A data-driven rail depot uses the same portable `.con` adapter as a modded
-- construction; no filename-specific branch exists in the codec.
local depotTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2", cost = 2000,
  nodes = {
    { slot = "node:1", position = { x = 1000, y = 0, z = 5 } },
    { slot = "node:2", position = { x = 1040, y = 0, z = 5 } },
  },
  edges = {{
    slot = "edge:1", carrier = "track",
    node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
    tangent0 = { x = 40, y = 0, z = 0 }, tangent1 = { x = 40, y = 0, z = 0 },
    type = 0, typeIndex = -1, resource = { index = 0, name = "standard.lua" },
    catenary = true, private = true, logicalOwnerCid = "company:2",
  }},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
  constructions = {{
    slot = "construction:1", mode = "build", adapter = "portable-construction",
    kind = "depot", sourceCid = "", collateral = {}, fileName = "depot/train/test_depot.con",
    transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1000, 0, 5, 1 },
    params = { catenary = true, trackType = "standard.lua", year = 1992 }, modules = {},
  }},
}
depotTransaction.digest = proposalCodec.digest(depotTransaction)
depotTransaction.transactionId = "proposal:" .. depotTransaction.digest
depotBuildFixture = {
  fileName = "depot/train/test_depot.con", construction = 8100, depot = 8104,
  nodes = {
    { id = 8101, position = { x = 1000, y = 0, z = 5 } },
    { id = 8102, position = { x = 1040, y = 0, z = 5 } },
  },
  edges = { { id = 8103, node0 = 8101, node1 = 8102, trackType = 0, catenary = true } },
}
writeCommit(21, "player2", { type = "proposal.build", transaction = depotTransaction })
script.update()
local queuedDepotRecord = assert(script.save().world.proposals.byId[proposalId("player2", 21)])
assert(queuedDepotRecord.replayPath ~= "gui-build-proposal",
  "depot escaped the selectable helper-built construction path")
for _ = 1, 6 do script.update() end
local depotRecord = assert(script.save().world.proposals.byId[proposalId("player2", 21)])
assert(depotRecord.status == "applied" and #depotRecord.result.outputs == 5,
  "portable depot did not bind construction, depot, and track graph outputs")
local depotState = script.save()
assert(canonical.resolveCanonical(depotState.canonical, "depot", 8104)
  and depotState.world.logicalOwners["8104"] == "company:2",
  "rail depot was not canonically owned by its company")
writeConsensus(22, depotRecord, -2000)
script.update()
writeCheckpointConsensus(23, script.save(), 22)
script.update()

-- An arbitrary mod-style construction with no transport topology is still a
-- canonical physical operation. Its compound asset output is bounded and
-- included in completion consensus.
local assetTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2", cost = 500, nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
  constructions = {{
    slot = "construction:1", mode = "build", adapter = "portable-construction",
    kind = "asset", sourceCid = "", collateral = {}, fileName = "asset/test/example.con",
    transform = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, 1100, 20, 5, 1 },
    params = { seed = 3, variant = "blue" }, modules = {},
  }},
}
assetTransaction.digest = proposalCodec.digest(assetTransaction)
assetTransaction.transactionId = "proposal:" .. assetTransaction.digest
assetBuildFixture = {
  fileName = "asset/test/example.con", root = 8201, asset = 8201,
  nodes = {}, edges = {},
}
writeCommit(24, "player2", { type = "proposal.build", transaction = assetTransaction })
script.update()
-- Let the helper work index prove the exact GUI-owned queue idle before the
-- GUI fallback changes ownership. finalise must invalidate that exhausted
-- index or this construction remains queued forever.
script.update()
requestConstructionHelperFallback(
  script.save().world.proposals.byId[proposalId("player2", 24)])
for _ = 1, 6 do script.update() end
local assetRecord = assert(script.save().world.proposals.byId[proposalId("player2", 24)])
local assetCid = canonical.resolveCanonical(script.save().canonical, "asset", 8201)
assert(assetRecord.status == "applied" and #assetRecord.result.outputs == 1 and assetCid,
  "ASSET_DEFAULT root was not completed canonically without a CONSTRUCTION component")
writeConsensus(25, assetRecord, -500)
script.update()
writeCheckpointConsensus(26, script.save(), 25)
script.update()

local assetUpgradeTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2", cost = 75, nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
  constructions = {{
    slot = "construction:1", mode = "upgrade", adapter = "portable-construction",
    kind = "asset", sourceCid = assetCid, collateral = {}, fileName = "asset/test/example_new.con",
    transform = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, 1100, 20, 5, 1 },
    params = { seed = 4, variant = "green" }, modules = {},
  }},
}
assetUpgradeTransaction.digest = proposalCodec.digest(assetUpgradeTransaction)
assetUpgradeTransaction.transactionId = "proposal:" .. assetUpgradeTransaction.digest
writeCommit(27, "player2", { type = "proposal.build", transaction = assetUpgradeTransaction })
script.update()
for _ = 1, 6 do script.update() end
local assetUpgradeRecord = assert(script.save().world.proposals.byId[proposalId("player2", 27)])
assert(assetUpgradeRecord.status == "applied" and assetUpgradeObserved
  and canonical.resolveLocal(script.save().canonical, assetCid) == 8201,
  "asset upgrade did not preserve the canonical ASSET_GROUP root")
writeConsensus(28, assetUpgradeRecord, -75)
script.update()
writeCheckpointConsensus(29, script.save(), 28)
script.update()

local assetRemoveTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2", cost = -25, nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
  constructions = {{
    slot = "construction:1", mode = "remove", adapter = "portable-construction",
    kind = "asset", sourceCid = assetCid, collateral = {}, fileName = "",
    transform = {}, params = {}, modules = {},
  }},
}
assetRemoveTransaction.digest = proposalCodec.digest(assetRemoveTransaction)
assetRemoveTransaction.transactionId = "proposal:" .. assetRemoveTransaction.digest
bulldozeFixture = assetBuildFixture
writeCommit(30, "player2", { type = "proposal.build", transaction = assetRemoveTransaction })
script.update()
for _ = 1, 6 do script.update() end
local assetRemoveRecord = assert(script.save().world.proposals.byId[proposalId("player2", 30)])
assert(assetRemoveRecord.status == "applied"
  and canonical.resolveLocal(script.save().canonical, assetCid) == nil,
  "asset bulldoze did not retire its canonical ASSET_GROUP root")
writeConsensus(31, assetRemoveRecord, 25)
script.update()
writeCheckpointConsensus(32, script.save(), 31)
script.update()

-- Station editing is an in-place schema-7 upgrade. The source construction CID
-- remains stable even when the engine helper returns no replacement entity.
local stationConstructionCid = assert(canonical.resolveCanonical(script.save().canonical, "construction", 600))
local stationUpgradeTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2", cost = 750, nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
  constructions = {{
    slot = "construction:1", mode = "upgrade", adapter = "portable-construction",
    kind = "station", sourceCid = stationConstructionCid, collateral = {},
    fileName = stationPrefix .. "modular_station.con",
    transform = { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 600, 100, 5, 1 },
    params = { seed = 3, year = 1992 },
    modules = {{
      slot = 10800010,
      name = stationPrefix .. "addon_platform_passenger_stairs_era_c.module",
      variant = 0, metadata = { underground = true },
    }},
  }},
}
stationUpgradeTransaction.digest = proposalCodec.digest(stationUpgradeTransaction)
stationUpgradeTransaction.transactionId = "proposal:" .. stationUpgradeTransaction.digest
writeCommit(33, "player2", { type = "proposal.build", transaction = stationUpgradeTransaction })
script.update()
for _ = 1, 6 do script.update() end
local stationUpgradeRecord = assert(script.save().world.proposals.byId[proposalId("player2", 33)])
assert(stationUpgradeRecord.status == "applied" and stationUpgradeObserved
  and canonical.resolveLocal(script.save().canonical, stationConstructionCid) == 600,
  "station module edit did not preserve its canonical construction identity")
writeConsensus(34, stationUpgradeRecord, -750)
script.update()
writeCheckpointConsensus(35, script.save(), 34)
script.update()

-- Bulldozing the station removes its complete explicitly named topology and
-- retires construction/station/group identities atomically before consensus.
local removalEdges, removalNodes = {}, {}
for _, edge in ipairs(stationBuildFixture.edges) do
  removalEdges[#removalEdges + 1] = assert(canonical.resolveCanonical(script.save().canonical, "edge", edge.id))
end
for _, node in ipairs(stationBuildFixture.nodes) do
  removalNodes[#removalNodes + 1] = assert(canonical.resolveCanonical(script.save().canonical, "node", node.id))
end
table.sort(removalEdges)
table.sort(removalNodes)
local stationRemoveTransaction = {
  schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  companyCid = "company:2", cost = -250, nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = removalEdges, nodes = removalNodes },
  constructions = {{
    slot = "construction:1", mode = "remove", adapter = "portable-construction",
    kind = "station", sourceCid = stationConstructionCid, collateral = {}, fileName = "",
    transform = {}, params = {}, modules = {},
  }},
}
stationRemoveTransaction.digest = proposalCodec.digest(stationRemoveTransaction)
stationRemoveTransaction.transactionId = "proposal:" .. stationRemoveTransaction.digest
bulldozeFixture = stationBuildFixture
stationBuildFixture.delayRemoval = true
writeCommit(36, "player2", { type = "proposal.build", transaction = stationRemoveTransaction })
script.update()
for _ = 1, 6 do script.update() end
local stationRemoveRecord = assert(script.save().world.proposals.byId[proposalId("player2", 36)])
assert(stationRemoveRecord.status == "building-construction"
  and canonical.resolveLocal(script.save().canonical, stationConstructionCid) == 600,
  "station bulldoze completed while generated topology was still retiring")
stationBuildFixture.delayRemoval = nil
if stationBuildFixture.station then components.STATION[stationBuildFixture.station] = nil end
if stationBuildFixture.stationGroup then components.STATION_GROUP[stationBuildFixture.stationGroup] = nil end
for _, node in ipairs(stationBuildFixture.nodes or {}) do components.BASE_NODE[node.id] = nil end
for _, edge in ipairs(stationBuildFixture.edges or {}) do
  components.BASE_EDGE[edge.id] = nil
  components.BASE_EDGE_TRACK[edge.id] = nil
  components.BASE_EDGE_STREET[edge.id] = nil
  components.PLAYER_OWNED[edge.id] = nil
end
for _ = 1, 6 do script.update() end
stationRemoveRecord = assert(script.save().world.proposals.byId[proposalId("player2", 36)])
local removedStationState = script.save()
assert(stationRemoveRecord.status == "applied" and #stationRemoveRecord.result.outputs == 0
  and canonical.resolveLocal(removedStationState.canonical, stationConstructionCid) == nil
  and canonical.resolveCanonical(removedStationState.canonical, "station", 601) == nil
  and canonical.resolveCanonical(removedStationState.canonical, "station_group", 602) == nil,
  "station bulldoze did not atomically retire its compound canonical graph")
writeConsensus(37, stationRemoveRecord, 250)
script.update()
writeCheckpointConsensus(38, script.save(), 37)
script.update()
local featureFinal = script.save()
assert(featureFinal.world.proposalConsensus.completed == 12
  and featureFinal.world.proposalConsensus.failed == 0
  and featureFinal.world.checkpointConsensus.completed == 13
  and featureFinal.lastError == nil,
  "signal/depot/construction/station-edit feature sequence did not close healthy consensus")

-- A bulldozer click on a connected spur has no replacement topology. It must
-- still cross the ordered BuildProposal path, prove the native edge vanished,
-- retire its canonical custody, settle, and close a checkpoint before another
-- physical action can start.
local removalOnlyTransaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:1",
  cost = 0,
  nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = { upgradedEdgeCid }, nodes = {} },
}
removalOnlyTransaction.digest = proposalCodec.digest(removalOnlyTransaction)
removalOnlyTransaction.transactionId = "proposal:" .. removalOnlyTransaction.digest
assert(proposalCodec.isRemovalOnly(removalOnlyTransaction),
  "connected-spur fixture was not classified as removal-only")
writeCommit(39, "player1", { type = "proposal.build", transaction = removalOnlyTransaction })
script.update()
local removalOnlyRecord = assert(
  script.save().world.proposals.byId[proposalId("player1", 39)])
assert(removalOnlyRecord.status == "queued" and removalOnlyRecord.localRefs[upgradedEdgeCid] == 403,
  "removal-only edge was not resolved into the physical proposal queue")
components.BASE_EDGE[403] = nil
components.BASE_EDGE_TRACK[403] = nil
components.PLAYER_OWNED[403] = nil
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = removalOnlyRecord.proposalId,
  success = true,
  createdNodeIds = {}, createdEdgeIds = {},
})
for _ = 1, 31 do script.update() end
removalOnlyRecord = assert(script.save().world.proposals.byId[removalOnlyRecord.proposalId])
local removalOnlyApplied = script.save()
assert(removalOnlyRecord.status == "applied" and #removalOnlyRecord.result.outputs == 0
    and canonical.resolveLocal(removalOnlyApplied.canonical, upgradedEdgeCid) == nil
    and removalOnlyApplied.world.logicalOwners["403"] == nil
    and removalOnlyApplied.world.pinnedCustody["403"] == nil,
  "removal-only edge replay did not retire canonical and logical custody")
writeConsensus(40, removalOnlyRecord, 0)
script.update()
writeCheckpointConsensus(41, script.save(), 40)
script.update()
local removalOnlyFinal = script.save()
assert(removalOnlyFinal.world.proposalConsensus.completed == 13
    and removalOnlyFinal.world.checkpointConsensus.completed == 14
    and removalOnlyFinal.world.proposalConsensus.sessionFault == nil,
  "removal-only edge did not close physical consensus and its checkpoint")

-- A companion protocol rejection is still an ordered control message. It must
-- release the origin's awaiting-order latch so a following physical click can
-- leave the bounded local FIFO instead of freezing every future build.
local emittedBeforeRejectedIntent = script.save().bridge.emitted
script.handleEvent("test", "tpf2mp", "intent", {
  type = "proposal.build", transaction = stationRemoveTransaction,
})
local emittedAfterRejectedIntent = script.save().bridge.emitted
assert(emittedAfterRejectedIntent == emittedBeforeRejectedIntent + 1,
  "first rejectable intent did not enter the bridge")
local firstIntentFile = assert(io.open(string.format(
  "%s/game_outbox/%012d.json", bridgeRoot, emittedAfterRejectedIntent), "rb"))
local firstIntent = json.decode(firstIntentFile:read("*a"))
firstIntentFile:close()
assert(firstIntent.kind == "intent" and firstIntent.payload.action.type == "proposal.build",
  "rejectable bridge record is not the expected physical intent")

script.handleEvent("test", "tpf2mp", "intent", {
  type = "proposal.build", transaction = stationRemoveTransaction,
})
assert(script.save().bridge.emitted == emittedAfterRejectedIntent,
  "second physical intent bypassed the awaiting-order FIFO")
writeOrdered(42, "control", "player1", {
  type = "network.intent_rejected",
  originPeer = "player2",
  originLocalSeq = firstIntent.local_seq,
  actionType = "proposal.build",
  errorCode = "proposal.build is host-generated; submit proposal.prepare first",
})
script.update()
local releasedState = script.save()
assert(releasedState.bridge.emitted == emittedAfterRejectedIntent + 1,
  "ordered intent rejection did not release the deferred physical action")
local releasedIntentFile = assert(io.open(string.format(
  "%s/game_outbox/%012d.json", bridgeRoot, releasedState.bridge.emitted), "rb"))
local releasedIntent = json.decode(releasedIntentFile:read("*a"))
releasedIntentFile:close()
assert(releasedIntent.kind == "intent"
  and releasedIntent.payload.action.type == "proposal.build"
  and releasedIntent.local_seq ~= firstIntent.local_seq,
  "deferred physical action was not emitted with a fresh bridge identity")

-- Release the still-held latch from the rejection test above with another
-- benign rejection: no origin token means no fault, only the FIFO release.
writeOrdered(43, "control", "player1", {
  type = "network.intent_rejected",
  originPeer = "player2",
  originLocalSeq = releasedIntent.local_seq,
  actionType = "proposal.build",
  errorCode = "proposal.build is host-generated; submit proposal.prepare first",
})
script.update()
assert(script.save().world.operationConsensus.sessionFault == nil,
  "a tokenless intent rejection must release the latch without faulting")

-- An origin-applied vanilla capture that normalises cleanly must carry its
-- origin token onto the wire.
-- bridge.emitted is read as a plain number immediately: the harness save()
-- can alias live state, so table snapshots do not freeze counter values.
local emittedBeforeOwnCapture = tonumber(script.save().bridge.emitted)
script.handleEvent("test", "tpf2mp", "intent", {
  type = "operation.capture",
  capture = {
    kind = "entity.name",
    targetLocalId = 301,
    originLocalId = 301,
    originApplied = true,
    name = "Own Edge",
  },
})
local emittedAfterOwnCapture = tonumber(script.save().bridge.emitted)
assert(emittedAfterOwnCapture == emittedBeforeOwnCapture + 1,
  "origin-applied own-asset capture did not reach the bridge")
local tokenIntentFile = assert(io.open(string.format(
  "%s/game_outbox/%012d.json", bridgeRoot, emittedAfterOwnCapture), "rb"))
local tokenIntent = json.decode(tokenIntentFile:read("*a"))
tokenIntentFile:close()
assert(tokenIntent.kind == "intent"
  and tokenIntent.payload.action.type == "operation.execute"
  and tostring(tokenIntent.payload.action.originCaptureToken):find("^player2:operation%-origin:%d+$"),
  "origin-applied operation intent lost its origin capture token")

-- Rejecting that ordered intent leaves an un-orderable native mutation on
-- this peer only: the session must fault closed and request the pause.
writeOrdered(44, "control", "player1", {
  type = "network.intent_rejected",
  originPeer = "player2",
  originLocalSeq = tokenIntent.local_seq,
  actionType = "operation.execute",
  errorCode = "test-transport-rejection",
})
script.update()
local emittedAfterFault = tonumber(script.save().bridge.emitted)
local residueFault = script.save().world.operationConsensus.sessionFault
assert(residueFault
  and residueFault.errorCode == "origin-applied-intent-rejected:test-transport-rejection"
  and residueFault.detail.originCaptureToken == tokenIntent.payload.action.originCaptureToken,
  "rejected origin-applied intent did not fault the session")
assert(emittedAfterFault == emittedAfterOwnCapture + 1,
  "origin residue fault did not request the ordered pause")
local pauseIntentFile = assert(io.open(string.format(
  "%s/game_outbox/%012d.json", bridgeRoot, emittedAfterFault), "rb"))
local pauseIntent = json.decode(pauseIntentFile:read("*a"))
pauseIntentFile:close()
assert(pauseIntent.kind == "intent"
  and pauseIntent.payload.action.type == "clock.request"
  and tonumber(pauseIntent.payload.action.requestedSpeed) == 0,
  "origin residue fault emitted something other than the ordered pause")

-- Capture-time authorization is a superset of commit-time operationAccess:
-- a vanilla rename of the rival's pre-existing track is rejected at the
-- normalise boundary, and the first fault is retained unchanged.
script.handleEvent("test", "tpf2mp", "intent", {
  type = "operation.capture",
  capture = {
    kind = "entity.name",
    targetLocalId = 92,
    originLocalId = 92,
    originApplied = true,
    name = "Hostile Rename",
  },
})
local rivalError = tostring(script.save().lastError)
assert(rivalError:find("rival%-owned"),
  "capture-time authorization did not reject the manifest-bound rival rename")
assert(script.save().world.operationConsensus.sessionFault.errorCode
    == "origin-applied-intent-rejected:test-transport-rejection",
  "a later residue did not retain the session's first fault")

-- Custody of an origin-applied mutation lives in module-locals that die with
-- a script reload, while the native mutation is inside the saved world. The
-- persisted marker must outlive them and fault the reloaded session.
do
  local savedState = script.save()
  savedState.world.operationConsensus.sessionFault = nil
  savedState.world.originResidueCustody = {
    ["player2:operation-origin:99"] = { kind = "line.update", capturedTick = 5 },
  }
  savedState.world.originResidueNextToken = 100
  script.load(savedState)
  local reloaded = script.save()
  local reloadFault = reloaded.world.operationConsensus.sessionFault
  assert(reloadFault and reloadFault.errorCode == "origin-applied-custody-lost-on-reload"
    and reloadFault.detail.pending == 1,
    "a reload holding origin-applied custody did not fault the session closed")
  assert(next(reloaded.world.originResidueCustody) == nil,
    "the reload did not clear the reported custody markers")
  assert(reloaded.world.originResidueNextToken == 100,
    "origin token monotonicity did not survive the reload")

  savedState = script.save()
  savedState.world.operationConsensus.sessionFault = nil
  savedState.world.originResidueCustody = {}
  script.load(savedState)
  assert(script.save().world.operationConsensus.sessionFault == nil,
    "a reload with no outstanding custody must not fault")
end

-- A native proposal that every peer rejects without outputs or a core change
-- is a rejected user action, not a divergent session. The ordered rejection
-- must close its own checkpoint and leave subsequent construction enabled.
do
  local proposalId = "network-company-map:player2:999"
  local proposalDigest = "a1b2c3d4"
  local resultDigest = "b1c2d3e4"
  local coreDigest = "c1d2e3f4"
  local savedState = script.save()
  savedState.world.proposals.byId[proposalId] = {
    proposalId = proposalId,
    commitSeq = 999,
    companyCid = "company:2",
    transaction = { digest = proposalDigest },
    status = "failed",
    completion = {
      proposalId = proposalId,
      commitSeq = 999,
      proposalDigest = proposalDigest,
      success = false,
      outputs = {},
      resultDigest = resultDigest,
      coreDigest = coreDigest,
      errorCode = "native-proposal-failed",
    },
  }
  script.load(savedState)
  script.update()
  local loadedCompletion = assert(script.save().world.proposals.byId[proposalId].completion,
    "reloaded failed proposal did not retain a completion report")
  resultDigest = loadedCompletion.resultDigest
  coreDigest = loadedCompletion.coreDigest
  writeOrdered(45, "control", "player1", {
    type = "network.proposal_outcome",
    proposalId = proposalId,
    commitSeq = 999,
    proposalDigest = proposalDigest,
    success = false,
    recoverable = true,
    resultDigest = resultDigest,
    coreDigest = coreDigest,
    errorCode = "native-proposal-rejected",
    peers = { "player1", "player2" },
  })
  script.update()
  local rejected = script.save()
  local outcome = rejected.world.proposalConsensus.byId[proposalId]
  assert(outcome and outcome.status == "rejected" and outcome.recoverable == true
      and rejected.world.proposalConsensus.rejected == 1
      and rejected.world.proposalConsensus.failed == 0
      and rejected.world.proposalConsensus.sessionFault == nil,
    "identical no-residue native rejection faulted the Lua session: " .. json.encode({
      outcome = outcome,
      fault = rejected.world.proposalConsensus.sessionFault,
      record = rejected.world.proposals.byId[proposalId],
    }))
  local rejectionBoundary = tostring(45 + sequenceOffset)
  assert(rejected.world.checkpointConsensus.byBoundary[rejectionBoundary]
      and rejected.world.checkpointConsensus.byBoundary[rejectionBoundary].reason
        == "physical-rejection:" .. proposalId,
    "recoverable native rejection did not open a convergence checkpoint")
  writeCheckpointConsensus(46, rejected, 45)
  script.update()
  local recovered = script.save()
  assert(recovered.world.checkpointConsensus.byBoundary[rejectionBoundary].status == "complete"
      and recovered.world.checkpointConsensus.sessionFault == nil,
    "recoverable native rejection did not close its convergence checkpoint")

  local residueId = "network-company-map:player2:1000"
  recovered.world.proposals.byId[residueId] = {
    proposalId = residueId,
    commitSeq = 1000,
    companyCid = "company:2",
    transaction = { digest = proposalDigest },
    status = "failed",
    completion = {
      proposalId = residueId,
      commitSeq = 1000,
      proposalDigest = proposalDigest,
      success = false,
      outputs = { { kind = "edge", cid = "edge:residue", slot = "edge:1" } },
      resultDigest = resultDigest,
      coreDigest = coreDigest,
      errorCode = "native-proposal-failed",
    },
  }
  writeOrdered(47, "control", "player1", {
    type = "network.proposal_outcome",
    proposalId = residueId,
    commitSeq = 1000,
    proposalDigest = proposalDigest,
    success = false,
    recoverable = true,
    resultDigest = resultDigest,
    coreDigest = coreDigest,
    errorCode = "native-proposal-rejected",
    peers = { "player1", "player2" },
  })
  script.update()
  local residueFault = script.save().world.proposalConsensus.sessionFault
  assert(residueFault and residueFault.status == "faulted"
      and residueFault.errorCode == "recoverable-rejection-does-not-match-local-completion"
      and script.save().world.proposalConsensus.rejected == 1
      and script.save().world.proposalConsensus.failed == 1,
    "a rejected proposal with local outputs was incorrectly treated as recoverable")
end

print("PASS network signals, depots, arbitrary constructions, station editing/removal, ownership, finance, and consensus")
