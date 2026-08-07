local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"
local authoredText = require "tpf2_mp/gui_authoritative_text"
local passengerHud = require "tpf2_mp/gui_passenger_hud"
local economyHud = require "tpf2_mp/gui_economy_hud"

local M = {}

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

local function createPanel(panelId, content)
  local comp = api and api.gui and api.gui.comp or {}
  local layouts = api and api.gui and api.gui.layout or {}
  if not (comp.Component and comp.TextView and layouts.BoxLayout
    and util.isCallable(comp.Component.new) and util.isCallable(comp.TextView.new)
    and util.isCallable(layouts.BoxLayout.new)) then return nil end
  local ok, panel = pcall(function()
    local result = comp.Component.new("TPF2MPAuthoritativePanel")
    if util.isCallable(result.setId) then result:setId(panelId) end
    local layout = layouts.BoxLayout.new("VERTICAL")
    result:setLayout(layout)
    local title = comp.TextView.new(content.title or "TPF2MP AUTHORITATIVE")
    if util.isCallable(title.setId) then title:setId(panelId .. ".title") end
    if util.isCallable(title.setName) then title:setName("TPF2MPAuthoritativeTitle") end
    local primary = comp.TextView.new(content.primary or "")
    if util.isCallable(primary.setId) then primary:setId(panelId .. ".primary") end
    if util.isCallable(primary.setName) then primary:setName("TPF2MPAuthoritativePrimary") end
    local secondary = comp.TextView.new(content.secondary or "")
    if util.isCallable(secondary.setId) then secondary:setId(panelId .. ".secondary") end
    if util.isCallable(secondary.setName) then secondary:setName("TPF2MPAuthoritativeSecondary") end
    layout:addItem(title)
    layout:addItem(primary)
    layout:addItem(secondary)
    setTooltip(result, content.tooltip)
    return result
  end)
  return ok and panel or nil
end

local function updatePanel(panelId, content)
  local panel = byId(panelId)
  if not panel then return false end
  setText(byId(panelId .. ".title"), content.title)
  setText(byId(panelId .. ".primary"), content.primary)
  setText(byId(panelId .. ".secondary"), content.secondary)
  setTooltip(panel, content.tooltip)
  return true
end

local function attachPanel(seedIds, panelId, content)
  if updatePanel(panelId, content) then return true end
  local seed
  for _, seedId in ipairs(seedIds or {}) do
    seed = byId(seedId)
    if seed then break end
  end
  local window = findWindow(seed)
  if not window then return false end
  local layout, layoutOk = invoke(window, "getLayout")
  if not layoutOk or not layout then return false end
  local panel = createPanel(panelId, content)
  if not panel then return false end
  -- A stock Window is a vertical title/content stack. Index one puts the
  -- authoritative strip inside that standard window, directly below its
  -- title and above the native content, without taking ownership of native
  -- widgets or retaining their short-lived userdata across frames.
  local _, inserted = invoke(layout, "insertItem", panel, 1)
  if not inserted then _, inserted = invoke(layout, "addItem", panel) end
  if not inserted then
    local destroy = api and api.gui and api.gui.util and api.gui.util.destroyLater
    if util.isCallable(destroy) then pcall(destroy, panel) end
    return false
  end
  return updatePanel(panelId, content)
end

local function walk(root, visitor)
  local seen, visited = {}, 0
  local function visit(item, depth)
    if item == nil or depth > 24 or visited >= 768 or seen[item] then return end
    seen[item] = true
    visited = visited + 1
    pcall(visitor, item)
    local layout = invoke(item, "getLayout")
    if not layout and member(item, "getNumItems") then layout = item end
    if not layout then return end
    local rawCount = invoke(layout, "getNumItems")
    local count = tonumber(rawCount) or 0
    count = math.min(math.max(0, count), 256)
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

local function companyManagerContent(snapshot, title, details)
  local company = authoredText.company(snapshot)
  company.title = title
  if details and details ~= "" then company.secondary = details end
  return company
end

local function hideFallbackHuds()
  setVisible(byId("tpf2mp.passengerHud"), false)
  setVisible(byId("tpf2mp.economyHud"), false)
end

local function projectToolbar(gui, snapshot)
  local projection = authoredText.toolbar(snapshot)
  local changed = 0
  if setText(byId("gameInfo.earningsComp.earningsText"), projection.earningsLabel) then changed = changed + 1 end
  local earnings = byId("gameInfo.earningsComp.earnings")
  if setText(earnings, projection.earnings) then
    changed = changed + 1
    local positive = tonumber(authoredText.company(snapshot).netRevenueCents) >= 0
    invoke(earnings, "setStyleClassList", { positive and "positive" or "negative" })
  end
  local passenger = byId("gameInfo.passengerComp.numPassenger")
  if setText(passenger, projection.transportedPassengers) then changed = changed + 1 end
  setTooltip(byId("gameInfo.passengerComp"), projection.passengerTooltip)
  local cargo = byId("gameInfo.cargoComp.numCargo")
  if cargo then
    setText(cargo, "--")
    setTooltip(byId("gameInfo.cargoComp"),
      "No authoritative cargo-presentation ledger exists yet. The native cargo counter is suppressed so scenery is not mistaken for competitive state.")
  end
  if setText(byId("menu.financesButton.number"), projection.accountNumber) then changed = changed + 1 end
  setText(byId("menu.financesButton.label"), "TPF2MP account")
  setTooltip(byId("menu.financesButton"), authoredText.company(snapshot).tooltip)
  gui.stockPresentation = gui.stockPresentation or {}
  gui.stockPresentation.toolbarProjected = changed >= 3
  if gui.stockPresentation.toolbarProjected then hideFallbackHuds() end
  return gui.stockPresentation.toolbarProjected
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
  local panelId = "tpf2mp.stock.entity." .. tostring(localId)
  local attached = attachPanel(seedIds, panelId, content)
  if attached then
    local seed = byId(seedIds[1]) or byId(seedIds[2])
    rewriteNativeEntityWindow(findWindow(seed), kind)
  end
  return attached
end

local function managerPanels(gui, snapshot)
  local status = gui.stockPresentation
  local lineContent = gui.selectedLineId
    and authoredText.line(snapshot, gui.selectedLineId)
    or companyManagerContent(snapshot, "TPF2MP AUTHORITATIVE SERVICES",
      authoredText.serviceList(snapshot, 8))
  status.lineManager = attachPanel({ "lineManager.newLine" },
    "tpf2mp.stock.lineManager", lineContent)

  local vehicleContent = gui.selectedVehicleId
    and authoredText.vehicle(snapshot, gui.selectedVehicleId)
    or companyManagerContent(snapshot, "TPF2MP AUTHORITATIVE FLEET",
      authoredText.vehicleList(snapshot, 8))
  status.vehicleManager = attachPanel({ "vehicleManager.buyVehicles", "menu.vehicleManager.editButton" },
    "tpf2mp.stock.vehicleManager", vehicleContent)

  status.finances = attachPanel({ "finances.borrow", "menu.finances.tabFinancesTable" },
    "tpf2mp.stock.finances", authoredText.company(snapshot))
  if status.finances then
    local seed = byId("finances.borrow") or byId("menu.finances.tabFinancesTable")
    local window = findWindow(seed)
    walk(window, function(component)
      if componentName(component) == "FinancesManager" then setVisible(component, false) end
    end)
  end

  local statistics = {
    { key = "lineStatistics", seed = "menu.stats.lines.table",
      title = "TPF2MP AUTHORITATIVE LINE STATISTICS", body = authoredText.serviceList(snapshot, 12) },
    { key = "vehicleStatistics", seed = "menu.stats.vehicles.table",
      title = "TPF2MP AUTHORITATIVE VEHICLE STATISTICS", body = authoredText.vehicleList(snapshot, 12) },
    { key = "stationStatistics", seed = "menu.stats.stations.table",
      title = "TPF2MP AUTHORITATIVE STATION STATISTICS", body = authoredText.stationList(snapshot, 12) },
  }
  for _, item in ipairs(statistics) do
    local content = companyManagerContent(snapshot, item.title, item.body)
    status[item.key] = attachPanel({ item.seed }, "tpf2mp.stock." .. item.key, content)
    if status[item.key] then setVisible(byId(item.seed), false) end
  end
end

local function collectNumbers(value, output, depth)
  if depth > 3 or #output >= 64 then return end
  if type(value) == "number" then
    output[#output + 1] = value
  elseif type(value) == "table" then
    for _, nested in pairs(value) do collectNumbers(nested, output, depth + 1) end
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
  local values = {}
  if type(param) == "table" then
    for _, key in ipairs({ "entity", "entityId", "vehicle", "vehicleId", "line", "lineId", "selectedEntity" }) do
      if tonumber(param[key]) then values[#values + 1] = tonumber(param[key]) end
    end
  elseif tonumber(param) then values[#values + 1] = tonumber(param) end
  collectNumbers(param, values, 0)
  if source:find("linemanager", 1, true) or source:find("lineeditor", 1, true) then
    gui.selectedLineId = selectMapped(snapshot, values, "localLines") or gui.selectedLineId
  elseif source:find("vehiclemanager", 1, true) then
    gui.selectedVehicleId = selectMapped(snapshot, values, "localVehicles") or gui.selectedVehicleId
    gui.selectedLineId = selectMapped(snapshot, values, "localLines") or gui.selectedLineId
  end
  return M.update(gui, snapshot, true)
end

function M.update(gui, snapshot, force)
  snapshot = snapshot or {}
  gui.stockPresentation = gui.stockPresentation or { scans = 0 }
  if snapshot.initialized ~= true then
    passengerHud.update(gui, snapshot)
    economyHud.update(gui, snapshot)
    return false
  end
  local toolbar = projectToolbar(gui, snapshot)
  if not toolbar then
    passengerHud.update(gui, snapshot)
    economyHud.update(gui, snapshot)
  end
  if force or (tonumber(gui.frames) or 0) % 15 == 0 then
    gui.stockPresentation.scans = (gui.stockPresentation.scans or 0) + 1
    local ok, errorMessage = pcall(function()
      gui.stockPresentation.entity = entityPanel(gui, snapshot)
      managerPanels(gui, snapshot)
    end)
    gui.stockPresentation.lastError = ok and nil or tostring(errorMessage)
  end
  return toolbar
end

return M
