local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"

local M = {}

local COMPONENT_ID = "tpf2mp.passengerHud"

local function byId(id)
  local getter = api and api.gui and api.gui.util and api.gui.util.getById
  if not util.isCallable(getter) then return nil end
  local ok, value = pcall(getter, id)
  return ok and value or nil
end

local function install(gui)
  if gui.passengerHud and gui.passengerHud.text then return true end
  local existing = byId(COMPONENT_ID)
  if existing then
    gui.passengerHud = gui.passengerHud or {}
    gui.passengerHud.root = existing
    gui.passengerHud.text = byId(COMPONENT_ID .. ".text") or existing
    return true
  end
  local layout = byId("gameInfo.layout")
  local comp = api and api.gui and api.gui.comp or {}
  if not (layout and util.isCallable(layout.addItem)
    and comp.Component and comp.TextView
    and util.isCallable(comp.Component.new) and util.isCallable(comp.TextView.new)) then
    return false
  end
  local ok, root, text = pcall(function()
    local rootValue = comp.Component.new(COMPONENT_ID)
    if util.isCallable(rootValue.setId) then rootValue:setId(COMPONENT_ID) end
    local box = api.gui.layout.BoxLayout.new("HORIZONTAL")
    rootValue:setLayout(box)
    local textValue = comp.TextView.new("TPF2MP PAX: waiting for match state")
    if util.isCallable(textValue.setId) then textValue:setId(COMPONENT_ID .. ".text") end
    box:addItem(textValue)
    layout:addItem(rootValue)
    return rootValue, textValue
  end)
  if not ok then return false end
  gui.passengerHud = { root = root, text = text }
  return true
end

local function selectedStationGroup(gui)
  if gui.selectedEntityKind == "station_group" then return gui.selectedEntityId end
  if gui.selectedEntityKind ~= "station" then return nil end
  local ok, value = pcall(world.stationGroupFor, gui.selectedEntityId)
  return ok and value or nil
end

local function vehicleText(item)
  local trip = "between stops"
  if item.originName and item.destinationName then
    trip = tostring(item.originName) .. " -> " .. tostring(item.destinationName)
  elseif item.destinationName then
    trip = "to " .. tostring(item.destinationName)
  end
  return string.format("TPF2MP PAX  %d/%d aboard  |  %s  |  %s",
    tonumber(item.aboard) or 0,
    tonumber(item.capacity) or 0,
    trip,
    tostring(item.lineName or item.lineCid or "unregistered line"))
end

local function stationText(item)
  return string.format("TPF2MP PAX  %d waiting  |  %d passengers/epoch  |  %s",
    tonumber(item.waiting) or 0,
    tonumber(item.throughput) or 0,
    tostring(item.name or item.stationGroupCid or "station"))
end

local function lineText(item)
  return string.format("TPF2MP PAX  %d waiting  |  %d allocated/epoch  |  %d boarded  |  %s",
    tonumber(item.waiting) or 0,
    tonumber(item.allocated) or 0,
    tonumber(item.boardedTotal) or 0,
    tostring(item.name or item.lineCid or "line"))
end

function M.update(gui, snapshot)
  if not install(gui) then return false end
  snapshot = snapshot or {}
  local view = snapshot.passengerPresentation or {}
  local text
  local selectedId = tostring(gui.selectedEntityId or "")
  if gui.selectedEntityKind == "vehicle" then
    local cid = view.localVehicles and view.localVehicles[selectedId]
    local item = cid and view.vehicles and view.vehicles[cid]
    if item then text = vehicleText(item) end
  elseif gui.selectedEntityKind == "line" then
    local cid = view.localLines and view.localLines[selectedId]
    local item = cid and view.lines and view.lines[cid]
    if item then text = lineText(item) end
  else
    local groupId = selectedStationGroup(gui)
    local cid = groupId and view.localStations
      and view.localStations[tostring(groupId)] or nil
    local item = cid and view.stations and view.stations[cid]
    if item then text = stationText(item) end
  end
  if not text then
    local totals = view.totals or {}
    text = string.format("TPF2MP PAX  %d aboard  |  %d waiting  |  select a train, line, or station",
      tonumber(totals.aboard) or 0,
      tonumber(totals.waiting) or 0)
  end
  local native = snapshot.probes and snapshot.probes.passengerCosmetics or {}
  local tooltip = string.format(
    "Authoritative synchronized counts. Native scenery currently shows %d aboard and %d waiting; it never affects revenue or score.",
    tonumber(native.nativeAboard) or 0,
    tonumber(native.nativeWaiting) or 0)
  if util.isCallable(gui.passengerHud.text.setText) then
    pcall(gui.passengerHud.text.setText, gui.passengerHud.text, text)
  end
  if util.isCallable(gui.passengerHud.root.setTooltip) then
    pcall(gui.passengerHud.root.setTooltip, gui.passengerHud.root, tooltip)
  elseif util.isCallable(gui.passengerHud.text.setTooltip) then
    pcall(gui.passengerHud.text.setTooltip, gui.passengerHud.text, tooltip)
  end
  return true
end

return M
