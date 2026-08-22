local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"
local authoredText = require "tpf2_mp/gui_authoritative_text"

local M = {}
local TOOLBAR_STRIDE = 600
local WINDOW_SCAN_STRIDE = 1800
local EVENT_DEFER_FRAMES = 3
local REPEATED_EVENT_STRIDE = 120
local MAX_WINDOW_ITEMS = 192

local function member(value, name)
  if value == nil then return nil end
  local ok, result = pcall(function() return value[name] end)
  return ok and result or nil
end

local function invoke(value, name, ...)
  local fn = member(value, name)
  if not util.isCallable(fn) then return nil, false end
  local ok, result = pcall(fn, value, ...)
  return ok and result or nil, ok
end

local function byId(id)
  local getter = api and api.gui and api.gui.util and api.gui.util.getById
  if not util.isCallable(getter) then return nil end
  local ok, value = pcall(getter, id)
  return ok and value or nil
end

local function setText(component, value)
  local _, ok = invoke(component, "setText", tostring(value or ""))
  return ok
end

local function setTooltip(component, value)
  local _, ok = invoke(component, "setTooltip", tostring(value or ""))
  if not ok then _, ok = invoke(component, "setToolTip", tostring(value or "")) end
  return ok
end

local function setVisible(component, visible)
  local _, ok = invoke(component, "setVisible", visible == true, false)
  return ok
end

local function componentName(component)
  local value = invoke(component, "getName")
  return value and tostring(value) or ""
end

local function findWindow(seed)
  local current = seed
  for _ = 1, 32 do
    if componentName(current) == "Window" then return current end
    local parent, ok = invoke(current, "getParent")
    if not ok or parent == nil or parent == current then return nil end
    current = parent
  end
  return nil
end

local function walk(root, visitor)
  local seen, visited = {}, 0
  local function visit(item, depth)
    if item == nil or depth > 16 or visited >= MAX_WINDOW_ITEMS or seen[item] then return end
    seen[item] = true
    visited = visited + 1
    pcall(visitor, item)
    local layout = invoke(item, "getLayout")
    if not layout and member(item, "getNumItems") then layout = item end
    if not layout then return end
    local rawCount = invoke(layout, "getNumItems")
    local count = tonumber(rawCount) or 0
    count = math.min(math.max(0, count), 96)
    for index = 0, count - 1 do visit(invoke(layout, "getItem", index), depth + 1) end
  end
  visit(root, 0)
end

local function rewriteNativeEntityWindow(window, kind)
  if not window then return end
  walk(window, function(component)
    local name = componentName(component)
    local current = invoke(component, "getText")
    current = current ~= nil and tostring(current) or nil
    if kind == "vehicle" and name == "VehicleCargo" then
      setVisible(component, false)
    elseif (kind == "station" or kind == "station_group")
      and name == "StationGroupDisplayComp" then
      setVisible(component, false)
    end
    if kind == "vehicle" and current == "Finances" then
      setText(component, "Native history (cosmetic)")
    elseif (kind == "vehicle" or kind == "line") and current == "Transported" then
      setText(component, "Native transported (cosmetic)")
    elseif (kind == "station" or kind == "station_group")
      and (current == "Loaded" or current == "Unloaded") then
      setText(component, "Native " .. string.lower(current) .. " (cosmetic)")
    end
  end)
end

local function projectToolbar(gui, snapshot, force)
  gui.stockPresentation = gui.stockPresentation or {}
  local status = gui.stockPresentation
  local snapshotTick = tonumber(snapshot.tick) or -1
  local projection = status.toolbarSource == snapshot
    and status.toolbarSourceTick == snapshotTick and status.toolbarSourceProjection or nil
  if not projection then
    local company = authoredText.company(snapshot)
    projection = authoredText.toolbar(snapshot, company)
    status.toolbarSource, status.toolbarSourceTick = snapshot, snapshotTick
    status.toolbarSourceProjection = projection
    status.toolbarSourceCompany = company
  end
  local projectionKey = table.concat({
    tostring(projection.earningsLabel), tostring(projection.earnings),
    tostring(projection.transportedPassengers), tostring(projection.transportedCargo),
    tostring(projection.accountNumber), tostring(projection.passengerTooltip),
    tostring(projection.cargoTooltip),
  }, "\31")
  if force ~= true and status.toolbarProjected == true
    and status.toolbarProjectionKey == projectionKey then return true end
  local company = status.toolbarSourceCompany or authoredText.company(snapshot)
  local changed = 0
  if setText(byId("gameInfo.earningsComp.earningsText"), projection.earningsLabel) then changed = changed + 1 end
  local earnings = byId("gameInfo.earningsComp.earnings")
  if setText(earnings, projection.earnings) then
    changed = changed + 1
    local positive = tonumber(company.netRevenueCents) >= 0
    invoke(earnings, "setStyleClassList", { positive and "positive" or "negative" })
  end
  local passenger = byId("gameInfo.passengerComp.numPassenger")
  if setText(passenger, projection.transportedPassengers) then changed = changed + 1 end
  setTooltip(byId("gameInfo.passengerComp"), projection.passengerTooltip)
  local cargo = byId("gameInfo.cargoComp.numCargo")
  if cargo then
    if setText(cargo, projection.transportedCargo) then changed = changed + 1 end
    setTooltip(byId("gameInfo.cargoComp"), projection.cargoTooltip)
  end
  if setText(byId("menu.financesButton.number"), projection.accountNumber) then changed = changed + 1 end
  setText(byId("menu.financesButton.label"), "TPF2MP account")
  setTooltip(byId("menu.financesButton"), company.tooltip)
  status.toolbarProjected = changed >= 3
  status.toolbarProjectionKey = projectionKey
  return status.toolbarProjected
end

local function selectedStationGroup(gui)
  if gui.selectedEntityKind == "station_group" then return tonumber(gui.selectedEntityId) end
  if gui.selectedEntityKind ~= "station" then return nil end
  local ok, result = pcall(world.stationGroupFor, gui.selectedEntityId)
  return ok and tonumber(result) or nil
end

local function entityPanel(gui, snapshot)
  local kind = gui.selectedEntityKind
  local localId = tonumber(gui.selectedEntityId)
  local presentationId = localId
  local content
  if kind == "vehicle" then
    content = authoredText.vehicle(snapshot, localId)
  elseif kind == "line" then
    content = authoredText.line(snapshot, localId)
  elseif kind == "station" or kind == "station_group" then
    presentationId = selectedStationGroup(gui) or localId
    content = authoredText.station(snapshot, presentationId)
  else return false end
  local seedIds = {
    "temp.view.entity_" .. tostring(localId),
    "temp.view.entity_" .. tostring(presentationId),
  }
  local seed = byId(seedIds[1]) or byId(seedIds[2])
  if not seed then return false end
  local window = findWindow(seed)
  rewriteNativeEntityWindow(window, kind)
  setTooltip(window or seed, content.tooltip)
  return true
end

local function managerSurfaces(gui, snapshot)
  local status = gui.stockPresentation
  local lineContent = gui.selectedLineId
    and authoredText.line(snapshot, gui.selectedLineId)
    or authoredText.company(snapshot)
  local lineSeed = byId("lineManager.newLine")
  status.lineManager = lineSeed ~= nil
  if lineSeed then setTooltip(lineSeed, lineContent.tooltip) end

  local vehicleContent = gui.selectedVehicleId
    and authoredText.vehicle(snapshot, gui.selectedVehicleId)
    or authoredText.company(snapshot)
  local vehicleSeed = byId("vehicleManager.buyVehicles")
    or byId("menu.vehicleManager.editButton")
  status.vehicleManager = vehicleSeed ~= nil
  if vehicleSeed then setTooltip(vehicleSeed, vehicleContent.tooltip) end

  local companyContent = authoredText.company(snapshot)
  local financesSeed = byId("finances.borrow") or byId("menu.finances.tabFinancesTable")
  status.finances = financesSeed ~= nil
  if financesSeed then setTooltip(financesSeed, companyContent.tooltip) end

  local statistics = {
    { key = "lineStatistics", seed = "menu.stats.lines.table" },
    { key = "vehicleStatistics", seed = "menu.stats.vehicles.table" },
    { key = "stationStatistics", seed = "menu.stats.stations.table" },
  }
  for _, item in ipairs(statistics) do
    local seed = byId(item.seed)
    status[item.key] = seed ~= nil
    if seed then
      setTooltip(seed,
        "Native history is cosmetic in multiplayer. Open Multiplayer for the synchronized authoritative ledger.")
    end
  end
end

local function collectNumbers(value, output, depth, seen, budget)
  if depth > 3 or #output >= 64 or budget.remaining <= 0 then return end
  budget.remaining = budget.remaining - 1
  if type(value) == "number" then
    output[#output + 1] = value
  elseif type(value) == "table" then
    if seen[value] then return end
    seen[value] = true
    for _, nested in pairs(value) do
      collectNumbers(nested, output, depth + 1, seen, budget)
      if budget.remaining <= 0 then break end
    end
  end
end

local function selectMapped(snapshot, values, mapName)
  local view = snapshot and snapshot.economyPresentation or {}
  local map = view[mapName] or {}
  for _, value in ipairs(values) do
    local id = tonumber(value)
    if id and map[tostring(id)] then return id end
  end
  return nil
end

function M.handleEvent(gui, snapshot, id, name, param)
  local source = string.lower(tostring(id or ""))
  if source:find("tpf2mp.", 1, true) == 1 then return false end
  local relevant = source == "mainview"
    or source:find("linemanager", 1, true) or source:find("lineeditor", 1, true)
    or source:find("vehiclemanager", 1, true) or source:find("finances", 1, true)
    or source:find("menu.stats", 1, true) or source:find("temp.view.entity", 1, true)
  if not relevant then return false end
  local values = {}
  if type(param) == "table" then
    for _, key in ipairs({ "entity", "entityId", "vehicle", "vehicleId", "line", "lineId", "selectedEntity" }) do
      if tonumber(param[key]) then values[#values + 1] = tonumber(param[key]) end
    end
  elseif tonumber(param) then values[#values + 1] = tonumber(param) end
  collectNumbers(param, values, 0, {}, { remaining = 128 })
  if source:find("linemanager", 1, true) or source:find("lineeditor", 1, true) then
    gui.selectedLineId = selectMapped(snapshot, values, "localLines") or gui.selectedLineId
  elseif source:find("vehiclemanager", 1, true) then
    gui.selectedVehicleId = selectMapped(snapshot, values, "localVehicles") or gui.selectedVehicleId
    gui.selectedLineId = selectMapped(snapshot, values, "localLines") or gui.selectedLineId
  end
  -- guiHandleEvent runs inside the native widget callback. Never traverse or
  -- mutate the same window tree from that stack: depot-open used to re-enter
  -- the renderer here and hang the game. guiUpdate performs one deferred pass.
  gui.stockPresentation = gui.stockPresentation or { scans = 0 }
  local status, frame = gui.stockPresentation, tonumber(gui.frames) or 0
  local eventKey = table.concat({ source, tostring(name or ""),
    tostring(gui.selectedEntityKind or ""), tostring(gui.selectedEntityId or ""),
    tostring(gui.selectedLineId or ""), tostring(gui.selectedVehicleId or "") }, "\31")
  if status.dirty == true or (status.lastEventKey == eventKey
      and frame - (status.lastEventFrame or -REPEATED_EVENT_STRIDE) < REPEATED_EVENT_STRIDE) then
    status.coalescedEvents = (status.coalescedEvents or 0) + 1
    return false
  end
  status.lastEventKey, status.lastEventFrame = eventKey, frame
  status.dirty, status.refreshAfterFrame = true, frame + EVENT_DEFER_FRAMES
  status.toolbarProjected = false
  return false
end

function M.update(gui, snapshot, force)
  snapshot = snapshot or {}
  gui.stockPresentation = gui.stockPresentation or { scans = 0 }
  local status = gui.stockPresentation
  local frame = tonumber(gui.frames) or 0
  if snapshot.initialized ~= true then
    -- Never graft fallback widgets into gameInfo.layout. Build 35924's native
    -- CSelector assumes that stock layout contains only its own ContentView
    -- implementation; even apparently compatible api.gui TextView children
    -- trip its checked downcast when a depot is selected. The authoritative
    -- toolbar projection below mutates existing stock leaves only and is the
    -- safe in-game presentation surface.
    return false
  end
  local toolbar = status.toolbarProjected == true
  if force or status.toolbarProjected ~= true or status.toolbarSource ~= snapshot
    or frame - (status.lastToolbarFrame or -TOOLBAR_STRIDE) >= TOOLBAR_STRIDE then
    status.lastToolbarFrame = frame
    toolbar = projectToolbar(gui, snapshot, force)
  end
  local refreshAfter = tonumber(status.refreshAfterFrame) or -1
  local safeToScan = frame >= refreshAfter
  local dirtyDue = status.dirty == true and safeToScan
  local periodicDue = safeToScan
    and frame - (status.lastScanFrame or -WINDOW_SCAN_STRIDE) >= WINDOW_SCAN_STRIDE
  if force or dirtyDue or periodicDue then
    status.lastScanFrame = frame
    status.dirty = false
    status.scans = (status.scans or 0) + 1
    local ok, errorMessage = pcall(function()
      status.entity = entityPanel(gui, snapshot)
      managerSurfaces(gui, snapshot)
    end)
    status.lastError = not ok and tostring(errorMessage) or nil
  end
  return toolbar
end

function M.due(gui, snapshot, force)
  snapshot = snapshot or {}
  if force == true then return true end
  if snapshot.initialized ~= true then return false end
  local status = gui.stockPresentation or {}
  local frame = tonumber(gui.frames) or 0
  if status.toolbarProjected ~= true or status.toolbarSource ~= snapshot
    or frame - (status.lastToolbarFrame or -TOOLBAR_STRIDE) >= TOOLBAR_STRIDE then return true end
  local refreshAfter = tonumber(status.refreshAfterFrame) or -1
  if frame < refreshAfter then return false end
  return status.dirty == true
    or frame - (status.lastScanFrame or -WINDOW_SCAN_STRIDE) >= WINDOW_SCAN_STRIDE
end

return M
