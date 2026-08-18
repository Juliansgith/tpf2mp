local util = require "tpf2_mp/util"

local M = {}

function M.cargoProof(snapshot)
  local cargo, cursors = snapshot.cargoPresentation or {}, snapshot.deliveryCursors or {}
  local totals, active, settled, revenue = cargo.totals or {}, 0, 0, 0
  for lineCid, line in pairs(cargo.lines or {}) do
    if type(line) == "table" and line.retired ~= true then
      active = active + 1
      local cursor = cursors[lineCid]
      if type(cursor) == "table" then
        settled = settled + math.max(0, tonumber(cursor.deliveredCargo) or 0)
        revenue = revenue + math.max(0, tonumber(cursor.earnedRevenueCents) or 0)
      end
    end
  end
  return active, math.max(0, tonumber(totals.waiting) or 0),
    math.max(0, tonumber(totals.aboard) or 0),
    math.max(0, tonumber(totals.capacity) or 0),
    math.max(0, tonumber(totals.delivered) or 0), settled, revenue
end

local function label(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  return tostring(fallback or "?")
end

local function chain(names, fallback)
  local values = {}
  for index, value in ipairs(names or {}) do
    values[#values + 1] = label(value, fallback and fallback[index])
  end
  if #values == 0 then
    for _, value in ipairs(fallback or {}) do values[#values + 1] = tostring(value) end
  end
  return table.concat(values, " -> ")
end

local function appendRouteManager(lines, snapshot)
  local network = snapshot.transportNetwork or {}
  lines[#lines + 1] = "-- ROUTES & TRANSFERS --"
  lines[#lines + 1] = string.format(
    "Passenger through-routes %d | cargo paths %d | cargo lines awaiting a compatible path %d",
    tonumber(network.passengerRouteCount) or 0,
    tonumber(network.cargoRouteCount) or 0,
    tonumber(network.unresolvedCargoCount) or 0)

  for _, route in ipairs(network.passengerRoutes or {}) do
    lines[#lines + 1] = string.format(
      "PAX %s -> %s | %d transfer(s), %d demand/hour | %s",
      label(route.sourceName, route.sourceTownCid),
      label(route.destinationName, route.destinationTownCid),
      tonumber(route.transfers) or 0, tonumber(route.demand) or 0,
      chain(route.stationNames, route.stations))
  end
  for _, route in ipairs(network.cargoRoutes or {}) do
    lines[#lines + 1] = string.format(
      "CARGO %s %s -> %s | %d leg(s), %d demand / %d capacity per hour | %s",
      tostring(route.cargoType or "cargo"),
      label(route.sourceName, route.sourceIndustryCid),
      label(route.destinationName, route.destinationIndustryCid),
      #(route.lines or {}), tonumber(route.demand) or 0,
      tonumber(route.capacity) or 0,
      chain(route.stationNames, route.stations))
  end

  for _, line in ipairs(network.unresolvedCargoLines or {}) do
    lines[#lines + 1] = string.format(
      "WAITING %s (%s): no source-to-compatible-industry path yet",
      tostring(line.name or line.lineCid), tostring(line.companyCid or "?"))
  end
  if (tonumber(network.unresolvedCargoCount) or 0) > 0 then
    lines[#lines + 1] = "Connect cargo lines through the exact same station group; the manager re-plans automatically."
  end

  local cargo = snapshot.cargoPresentation or {}
  local transfers = cargo.transferStations or {}
  if next(transfers) == nil then
    lines[#lines + 1] = "Transfer inventory: empty"
  else
    lines[#lines + 1] = "Transfer inventory (authoritative, survives vehicle hand-off):"
    for _, stationCid in ipairs(util.sortedKeys(transfers)) do
      local station, stocks = transfers[stationCid], {}
      for _, cargoType in ipairs(util.sortedKeys(station.stocks or {})) do
        stocks[#stocks + 1] = cargoType .. " " .. tostring(station.stocks[cargoType])
      end
      lines[#lines + 1] = "  " .. label(station.name, stationCid)
        .. ": " .. table.concat(stocks, ", ")
    end
  end
end

local function appendCompatibility(lines, snapshot)
  local view = snapshot.probes and snapshot.probes.resourceCompatibility or {}
  local policy = view.policy or {}
  lines[#lines + 1] = "-- INFRASTRUCTURE COMPATIBILITY --"
  lines[#lines + 1] = string.format(
    "%d portable proposal(s) | %d observed resource(s) | %d rejected | %d inventory overflow",
    tonumber(view.portableProposals) or 0, tonumber(view.resourceCount) or 0,
    tonumber(view.rejectedProposals) or 0, tonumber(view.ignoredResources) or 0)
  lines[#lines + 1] = "Roads/tracks: " .. tostring(policy.roadsAndTracks or "-")
    .. " | signals/waypoints: " .. tostring(policy.signalsAndWaypoints or "-")
  lines[#lines + 1] = "Stations/depots/constructions: "
    .. tostring(policy.constructionsAndStations or "-")
  lines[#lines + 1] = "Mod policy: " .. tostring(policy.vanillaAndDataOnlyMods or "-")
    .. " | " .. tostring(policy.opaqueCallbacks or "-")
  for _, resource in ipairs(view.resources or {}) do
    lines[#lines + 1] = string.format("  [%s] %s | %s | used %d",
      tostring(resource.kind or "?"), tostring(resource.name or "?"),
      tostring(resource.adapter or resource.status or "portable"),
      tonumber(resource.uses) or 0)
  end
  if #(view.resources or {}) == 0 then
    lines[#lines + 1] = "Build something once; every exact resource used will appear here."
  end
end

local function appendAlphaStatus(lines, snapshot)
  local alpha = snapshot.alphaReadiness or {}
  lines[#lines + 1] = "-- TRUSTED-LAN ALPHA STATUS --"
  lines[#lines + 1] = tostring(alpha.state or "WAITING")
    .. " | profile " .. tostring(alpha.profile or "unavailable")
  if #(alpha.blockers or {}) == 0 then
    lines[#lines + 1] = "No current session-safety blockers. This is readiness, not a substitute for the live checklist."
  else
    lines[#lines + 1] = "Resolve before continuing:"
    for _, item in ipairs(alpha.blockers or {}) do
      lines[#lines + 1] = "  BLOCK " .. tostring(item.code or "unknown")
        .. ": " .. tostring(item.text or "")
    end
  end
  for _, item in ipairs(alpha.warnings or {}) do
    lines[#lines + 1] = "  NOTE " .. tostring(item.code or "unknown")
      .. ": " .. tostring(item.text or "")
  end
  lines[#lines + 1] = "Supported in this alpha:"
  for _, value in ipairs(alpha.capabilities or {}) do
    lines[#lines + 1] = "  + " .. tostring(value)
  end
  lines[#lines + 1] = "Explicit limits:"
  for _, value in ipairs(alpha.limitations or {}) do
    lines[#lines + 1] = "  - " .. tostring(value)
  end
end

function M.append(lines, gui, snapshot)
  local network = snapshot.transportNetwork or {}
  local cargo = snapshot.cargoPresentation or {}
  local totals = cargo.totals or {}
  lines[#lines + 1] = string.format(
    "Transport manager: %d passenger through-route(s), %d cargo path(s), %d transfer unit(s), %d unresolved cargo line(s)",
    tonumber(network.passengerRouteCount) or 0,
    tonumber(network.cargoRouteCount) or 0,
    tonumber(totals.transferStock) or 0,
    tonumber(network.unresolvedCargoCount) or 0)
  local mode = gui.managerView or "overview"
  if mode == "routes" then appendRouteManager(lines, snapshot); return true end
  if mode == "compatibility" then appendCompatibility(lines, snapshot); return true end
  if mode == "alpha" then appendAlphaStatus(lines, snapshot); return true end
  return false
end

function M.buttons(gui)
  local function switch(mode)
    return function()
      gui.managerView = mode
      return { type = "snapshot.request", localOnly = true }
    end
  end
  return {
    { "Overview", switch("overview") },
    { "Routes / Transfers", switch("routes") },
    { "Compatibility", switch("compatibility") },
    { "Alpha Status", switch("alpha") },
  }
end

return M
