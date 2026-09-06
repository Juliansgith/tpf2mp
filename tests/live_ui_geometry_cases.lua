return function(project)
  local M = assert(loadfile(project .. "/tpf2_mp_1/res/scripts/tpf2_mp/live_ui_geometry_observer.lua"))()
  local registry = { byCanonical = {
    ["edge:b"] = { kind = "edge", localId = 22, metadata = { fake = true } },
    ["edge:a"] = { kind = "edge", localId = 11 },
    ["construction:a"] = { kind = "construction", localId = 33 },
  } }
  local calls = {}
  local world = {
    entityExists = function(id) return id == 11 or id == 22 end,
    topologyFingerprint = function(id, kind, options)
      calls[#calls + 1] = id
      assert(kind == "edge" and options.includeNeighbours == false)
      assert(options.registry == registry)
      return "native-" .. id, nil, { kind = kind, nativeId = id,
        carrier = { kind = "track", resource = "standard.lua" },
        endpoints = { { position = { 0, id, 0 } }, { position = { 1600, id, 0 } } } }
    end,
  }
  local read = M.read(registry, world)
  assert(read.complete and read.count == 2 and calls[1] == 11 and calls[2] == 22)
  assert(read.edges["edge:b"].nativeId == 22 and not read.edges["edge:b"].fake)
  assert(registry.byCanonical["edge:a"].metadata == nil, "observer cannot repair metadata")
  registry.byCanonical["edge:a"].localId = -1
  assert(not pcall(M.read, registry, world), "temporary IDs must fail before native reads")
  registry.byCanonical["edge:a"].localId = math.huge
  assert(not pcall(M.read, registry, world), "infinite IDs must fail before native reads")
  registry.byCanonical["edge:a"].localId = 12
  assert(not pcall(M.read, registry, world), "missing physical object is not an empty result")
  registry.byCanonical["edge:a"].localId = 11
  world.topologyFingerprint = function() return nil, "missing geometry" end
  assert(not pcall(M.read, registry, world), "unavailable native geometry must fail closed")
  M.MAX_EDGES = 1
  assert(not pcall(M.read, registry, world), "partial edge inventory must never claim complete")
  print("PASS readonly native edge geometry observer cases")
end
