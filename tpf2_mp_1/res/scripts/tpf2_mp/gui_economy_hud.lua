local util = require "tpf2_mp/util"

local M = {}
local COMPONENT_ID = "tpf2mp.economyHud"

local function byId(id)
  local getter = api and api.gui and api.gui.util and api.gui.util.getById
  if not util.isCallable(getter) then return nil end
  local ok, value = pcall(getter, id)
  return ok and value or nil
end

local function install(gui)
  if gui.economyHud and gui.economyHud.text then return true end
  local existing = byId(COMPONENT_ID)
  if existing then
    gui.economyHud = gui.economyHud or {}
    gui.economyHud.root = existing
    gui.economyHud.text = byId(COMPONENT_ID .. ".text") or existing
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
    local textValue = comp.TextView.new("TPF2MP ECO: waiting for match state")
    if util.isCallable(textValue.setId) then textValue:setId(COMPONENT_ID .. ".text") end
    box:addItem(textValue)
    layout:addItem(rootValue)
    return rootValue, textValue
  end)
  if not ok then return false end
  gui.economyHud = { root = root, text = text }
  return true
end

local function moneyCents(cents)
  local dollars = (tonumber(cents) or 0) / 100
  local absolute = math.abs(dollars)
  if absolute >= 1000000 then return string.format("$%.2fm", dollars / 1000000) end
  if absolute >= 1000 then return string.format("$%.1fk", dollars / 1000) end
  return string.format("$%.2f", dollars)
end

local function moneyDollars(dollars)
  return moneyCents((tonumber(dollars) or 0) * 100)
end

local function minutes(seconds)
  return string.format("%.1f min", (tonumber(seconds) or 0) / 60)
end

local function vehicleText(item)
  local purchase = item.purchasePriceDollars
    and (moneyDollars(item.purchasePriceDollars) .. " buy") or "pre-existing"
  local annual = item.annualVehicleUpkeepCents
    and (moneyCents(item.annualVehicleUpkeepCents) .. "/yr") or "upkeep unbound"
  local hourly = item.projectedHourlyVehicleUpkeepCents
    and (moneyCents(item.projectedHourlyVehicleUpkeepCents) .. "/financial h") or "-"
  local tick = item.intervalVehicleUpkeepCents
    and (moneyCents(item.intervalVehicleUpkeepCents) .. "/5m") or "-"
  local line = item.line
  local result = string.format("TPF2MP ECO  %s | %s (%s; %s)", purchase, annual, tick, hourly)
  if line then
    result = result .. string.format(" | line %s pending; %s net last 5m",
      moneyCents(line.pendingGrossRevenueCents), moneyCents(line.netRevenueCents))
  else
    result = result .. " | parked/unassigned still accrues upkeep"
  end
  return result
end

local function lineText(item)
  local speed = item.topSpeedKmh and (tostring(item.topSpeedKmh) .. " km/h") or "speed estimated"
  local parity = item.fareAtOutsideParityCents
    and (" | outside parity " .. moneyCents(item.fareAtOutsideParityCents)) or ""
  return string.format(
    "TPF2MP ECO  fare %s%s | %s, %s trip, every %s | %d delivered + %d pending | %s net/5m (%s/h)",
    moneyCents(item.fareCents), parity, speed, minutes(item.journeySeconds),
    minutes(item.headwaySeconds), item.delivered or 0, item.pendingDelivered or 0,
    moneyCents(item.netRevenueCents), moneyCents(item.projectedHourlyNetRevenueCents))
end

local function companyText(snapshot, view)
  local companyCid = view.activeCompanyCid or snapshot.activeCompanyCid
  local company = companyCid and view.companies and view.companies[companyCid] or {}
  return string.format("TPF2MP ECO  %s %.0f%% | last 5m %s net | %s completed-trip revenue pending | projected %s/h",
    tostring(view.economyDifficultyLabel or "Normal"),
    (tonumber(view.revenueMultiplierPpm) or 1000000) / 10000,
    moneyCents(company.netRevenueCents or company.revenueCents),
    moneyCents(company.pendingGrossRevenueCents),
    moneyCents(company.projectedHourlyNetRevenueCents or 0))
end

function M.update(gui, snapshot)
  if not install(gui) then return false end
  snapshot = snapshot or {}
  local view = snapshot.economyPresentation or {}
  local selectedId = tostring(gui.selectedEntityId or "")
  local text, tooltip
  if gui.selectedEntityKind == "vehicle" then
    local cid = view.localVehicles and view.localVehicles[selectedId]
    local item = cid and view.vehicles and view.vehicles[cid]
    if item then
      text = vehicleText(item)
      tooltip = "Authoritative purchase and upkeep. The annual upkeep is read from the same resolved native component used by the stock vehicle UI, then agreed by every peer. Native trip-income history remains cosmetic."
    end
  elseif gui.selectedEntityKind == "line" then
    local cid = view.localLines and view.localLines[selectedId]
    local item = cid and view.services and view.services[cid]
    if item then
      text = lineText(item)
      tooltip = string.format(
        "Faster service lowers time and waiting cost, increases departures/capacity, and competes even without a rival against the %s outside option. Current fare reaches outside-cost parity near %s; this is a diagnostic, not a guaranteed optimal fare.",
        moneyCents(item.outsideCostCents), moneyCents(item.fareAtOutsideParityCents))
    end
  end
  if not text then
    text = companyText(snapshot, view)
    tooltip = "Authoritative synchronized five-minute accounting. Economy difficulty is selected when the world is created, stored in the save, and locked after match initialization. Passenger revenue becomes pending only after a synchronized completed trip and is paid at the next tick. Stock floating trip income and vanilla history are cosmetic."
  end
  if util.isCallable(gui.economyHud.text.setText) then
    pcall(gui.economyHud.text.setText, gui.economyHud.text, text)
  end
  if util.isCallable(gui.economyHud.root.setTooltip) then
    pcall(gui.economyHud.root.setTooltip, gui.economyHud.root, tooltip)
  elseif util.isCallable(gui.economyHud.text.setTooltip) then
    pcall(gui.economyHud.text.setTooltip, gui.economyHud.text, tooltip)
  end
  return true
end

return M
