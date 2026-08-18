local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local readiness = require "tpf2_mp/alpha_readiness"
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function equal(actual, expected, message)
  if actual ~= expected then error((message or "values differ")
    .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function truthy(value, message) if not value then error(message or "expected truthy value", 2) end end

local function readySnapshot()
  return {
    networkMode = "network", initialized = true, serviceCount = 2,
    autonomyFrozen = true, transportNetwork = { unresolvedCargoCount = 0 },
    probes = { networkAuthority = { ready = true },
      resourceCompatibility = { rejectedProposals = 0 } },
    bridge = { companion = { connected = true, synchronized = true,
      reconnect = { active = false, synchronizingPeers = {} } } },
    proposalConsensus = { pending = 0 }, operationConsensus = { pending = 0 },
    checkpointConsensus = { pending = 0, lastAgreed = { boundarySeq = 7 } },
    deferredNetworkQueue = { count = 0 },
  }
end

test("a settled synchronized session reports alpha ready", function()
  local result = readiness.evaluate(readySnapshot())
  equal(result.state, "READY")
  truthy(result.ready)
  equal(#result.blockers, 0)
  truthy(#result.capabilities >= 7)
  truthy(#result.limitations >= 6)
end)

test("backlog replay and consensus work remain visibly blocked", function()
  local snapshot = readySnapshot()
  snapshot.bridge.companion.connected = false
  snapshot.bridge.companion.socketConnected = true
  snapshot.bridge.companion.reconnect.active = true
  snapshot.proposalConsensus.pending = 1
  snapshot.checkpointConsensus.pending = 1
  local result = readiness.evaluate(snapshot)
  equal(result.state, "WAITING")
  truthy(#result.blockers >= 4)
end)

test("an authority fault is never presented as an ordinary wait", function()
  local snapshot = readySnapshot()
  snapshot.bridge.companion.auditFaulted = true
  snapshot.operationConsensus.sessionFault = { errorCode = "physical-divergence" }
  local result = readiness.evaluate(snapshot)
  equal(result.state, "FAULTED")
  equal(result.ready, false)
end)

local passed = 0
for _, item in ipairs(tests) do
  local ok, err = pcall(item.fn)
  if ok then print("PASS " .. item.name); passed = passed + 1
  else print("FAIL " .. item.name .. ": " .. tostring(err)) end
end
print(string.format("Alpha-readiness tests: %d/%d passed", passed, #tests))
if passed ~= #tests then os.exit(1) end
