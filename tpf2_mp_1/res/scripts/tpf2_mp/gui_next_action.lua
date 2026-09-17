-- The one sentence a player needs: what to do now. Everything else in the
-- panel is evidence; this line is the instruction. It is derived from the
-- public snapshot only, so it is a pure function of observable state and can
-- be unit tested without any GUI. The module registers itself as
-- guiView.nextAction so the game script, which sits at Lua 5.1's 200-local
-- cap, needs no new local to reach it.
local matchInitialisePolicy = require "tpf2_mp/match_initialise_policy"
local guiView = require "tpf2_mp/gui_view"

local M = {}

-- The companion publishes a finite reconnect grace interval
-- (companion/tpf2mp/reconnect.py). When its countdown has not reached the
-- game yet, quote the documented default rather than inventing a number.
M.GRACE_SECONDS = 120

M.FINISH_REASONS = {
  bankruptcy = "the rival company's bankruptcy",
  ["valuation-target"] = "valuation target",
  ["epoch-limit"] = "the epoch limit",
  manual = "a manual finish",
  ["manual-ui"] = "a manual finish",
}

-- match_runtime.lua records finish reasons as machine codes; players read
-- words.
function M.finishReason(reason)
  local code = tostring(reason or "manual")
  local words = M.FINISH_REASONS[code]
  if words then return words end
  return (code:gsub("[-_]", " "))
end

function M.peerLabel(peerId)
  local peer = tostring(peerId or "")
  if peer == "player1" then return "Player 1" end
  if peer == "player2" then return "Player 2" end
  if peer == "" then return "the other player" end
  return peer
end

-- The sentence is always about the *other* computer, so name it explicitly.
function M.otherPeerLabel(snapshot)
  local peer = tostring(snapshot.peerId or "")
  if peer == "player1" then return "Player 2" end
  if peer == "player2" then return "Player 1" end
  return "the other player"
end

function M.companyName(snapshot, companyCid)
  if not companyCid then return nil end
  local companies = snapshot.companies
  if type(companies) == "table" and type(companies[companyCid]) == "table" then
    return tostring(companies[companyCid].name or companyCid)
  end
  return tostring(companyCid)
end

function M.matchOver(snapshot)
  local match = snapshot.match or {}
  if tostring(match.status or "") ~= "finished" then return nil end
  local winner = M.companyName(snapshot, match.winnerCid)
  local reason = M.finishReason(match.finishReason)
  if not winner then return "Match over: no winner was recorded (" .. reason .. ")." end
  return "Match over: " .. winner .. " won by " .. reason .. "."
end

-- companion reconnect status: { graceSeconds, active, waitingPeers = {
-- [peer] = { secondsRemaining, reason, status } } }.
function M.reconnectWait(companion)
  local reconnect = companion.reconnect
  if type(reconnect) ~= "table" then return nil end
  local waiting = reconnect.waitingPeers
  if type(waiting) ~= "table" then return nil end
  local peers = {}
  for peer in pairs(waiting) do peers[#peers + 1] = tostring(peer) end
  table.sort(peers)
  if #peers == 0 then return nil end
  local item = waiting[peers[1]]
  local seconds
  if type(item) == "table" then seconds = tonumber(item.secondsRemaining) end
  local grace = tonumber(reconnect.graceSeconds) or M.GRACE_SECONDS
  return peers[1], seconds, grace
end

local function missingPeer(companion)
  local required = companion.requiredPeers
  if type(required) ~= "table" then return nil end
  local connected = {}
  if type(companion.connectedPeers) == "table" then
    for _, peer in ipairs(companion.connectedPeers) do connected[tostring(peer)] = true end
  end
  for _, peer in ipairs(required) do
    if not connected[tostring(peer)] then return tostring(peer) end
  end
  return nil
end

local function pendingWork(snapshot, other)
  local deferredQueue = snapshot.deferredNetworkQueue or {}
  if type(deferredQueue.awaitingOrder) == "table" then
    return "Your last build is waiting for the host's order."
  end
  local deferred = snapshot.deferredNetworkIntent
  if type(deferred) == "table" then
    return "Your last action is queued until the shared world can accept it ("
      .. tostring(deferred.reason or "waiting for authority") .. ")."
  end
  local proposals = snapshot.proposalConsensus or {}
  if (tonumber(proposals.pending) or 0) > 0 then
    return "Your last build is waiting for " .. other .. "'s computer to agree."
  end
  local operations = snapshot.operationConsensus or {}
  if (tonumber(operations.pending) or 0) > 0 then
    return "Your last line or vehicle order is waiting for " .. other .. "'s computer to agree."
  end
  local checkpoints = snapshot.checkpointConsensus or {}
  if (tonumber(checkpoints.pending) or 0) > 0 then
    return "Both worlds are comparing a shared checkpoint; this takes a moment."
  end
  return nil
end

local function readyText(snapshot)
  local clock = snapshot.networkClock or {}
  local effective = tonumber(clock.effectiveSpeed) or 0
  if effective <= 0 then
    return "Both worlds are ready. Build freely; the shared clock is paused until you press Speed 1."
  end
  return "Both worlds are ready and the shared clock is running at speed "
    .. tostring(effective) .. "."
end

-- The one public entry point: a pure snapshot -> sentence function.
function M.text(snapshot)
  if type(snapshot) ~= "table" then snapshot = {} end
  local finished = M.matchOver(snapshot)
  if finished then return finished end
  if snapshot.networkMode ~= "network" then
    return "Local mode: nothing is shared. Switch to Network Mode before inviting a player."
  end
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local other = M.otherPeerLabel(snapshot)
  local status = tostring(matchInitialisePolicy.status(snapshot) or "setup")
  if status == "FAULTED" then
    return "The session is faulted. Use Recover / Resync Session."
  end
  local waitingPeer, seconds = M.reconnectWait(companion)
  if waitingPeer then
    local label = M.peerLabel(waitingPeer)
    if label == M.peerLabel(snapshot.peerId) then label = other end
    if seconds then
      return "Waiting for " .. label .. " to reconnect ("
        .. string.format("%d", math.max(0, math.floor(seconds))) .. " s left)."
    end
    return "Waiting for " .. label .. " to reconnect (up to "
      .. tostring(M.GRACE_SECONDS) .. " s)."
  end
  if companion.connected ~= true then
    local link = tostring(companion.status or "offline")
    if link == "not-running" or link == "offline" then
      return "The network companion is not running. Start the session from the TPF2MP launcher."
    end
    return "Waiting for " .. other .. " to join (companion " .. link .. ")."
  end
  local absent = missingPeer(companion)
  if absent then
    return "Waiting for " .. M.peerLabel(absent) .. " to join."
  end
  if status == "waiting for peer world" then
    return "Waiting for " .. other .. "'s world to load."
  end
  if status == "waiting for peer" then
    return "Waiting for " .. other .. " to join."
  end
  if status == "starting automatically" then
    return "Both worlds are connected; the match is starting itself. No action needed."
  end
  if status == "synchronising checkpoint" then
    return "Both worlds are agreeing on the first shared checkpoint. No action needed."
  end
  if status == "manual setup" then
    return "Press Initialise Match to start the shared session."
  end
  local pending = pendingWork(snapshot, other)
  if pending then return pending end
  return readyText(snapshot)
end

-- The historical spelling used by the brief; kept as an alias so callers can
-- read guiView.nextAction.nextAction(snapshot) or .text(snapshot).
M.nextAction = M.text

function M.render(gui, snapshot)
  local view = gui and gui.nextActionView
  if not view then return end
  if type(view.setText) ~= "function" then return end
  pcall(view.setText, view, M.text(snapshot or (gui and gui.snapshot) or {}))
end

guiView.nextAction = M
return M
