local M = {}

local function boundedInteger(value, low, high)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) or number < low or number > high then
    return nil
  end
  return number
end

local v2Tags = { [6] = true, [7] = true, [8] = true, [9] = true,
  [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [30] = true }
local targetOnlyTags = { [7] = true, [10] = true, [14] = true }
local booleanTags = { [8] = true, [11] = true, [30] = true }

local function lifecycleCapture(decoded)
  local target = decoded.targetLocalId
  if decoded.tag == 6 then
    return { kind = "vehicle.assign", targetLocalId = target,
      lineLocalId = decoded.secondaryLocalId, stopIndex = decoded.value }, "assignments"
  elseif decoded.tag == 7 then
    return { kind = "vehicle.reverse", targetLocalId = target }, "reverses"
  elseif decoded.tag == 8 then
    return { kind = "vehicle.stop", targetLocalId = target,
      stopped = decoded.value == 1 }, "stops"
  elseif decoded.tag == 9 then
    return { kind = "vehicle.maintenance", targetLocalId = target,
      valueBasisPoints = decoded.value }, "maintenance"
  elseif decoded.tag == 10 then
    return { kind = "vehicle.depart", targetLocalId = target }, "departures"
  elseif decoded.tag == 11 then
    return { kind = "vehicle.send_to_depot", targetLocalId = target,
      sellOnArrival = decoded.value == 1 }, "sendToDepot"
  elseif decoded.tag == 12 then
    return { kind = "vehicle.sell", targetLocalId = target }, "sales"
  elseif decoded.tag == 30 then
    return { kind = "vehicle.manual_departure", targetLocalId = target,
      manual = decoded.value == 1 }, "manualDepartures"
  end
  return nil, nil
end

function M.install(gui, deps)
  assert(type(gui) == "table", "GUI vehicle capture state is required")
  assert(type(deps) == "table", "GUI vehicle capture dependencies are required")
  local queueAction = assert(deps.queueAction, "queueAction dependency is required")
  local maxStops = tonumber(deps.maxStops) or 256

  gui.decodeSuppressedNativeVehicleCommand = function(raw)
    if type(raw) ~= "string" or #raw > 128 then
      return nil, "invalid native vehicle envelope"
    end
    local version, tagText, targetText, secondaryText, valueText =
      raw:match("^(V[12])|(-?%d+)|(-?%d+)|(-?%d+)|(-?%d+)$")
    local tag = boundedInteger(tagText, 0, 36)
    local target = boundedInteger(targetText, 0, 2147483647)
    local secondary = boundedInteger(secondaryText, 0, 2147483647)
    local value = boundedInteger(valueText, -1, 10000)
    if not version or not tag or not target or not secondary or not value
      or (version == "V1" and tag ~= 6 and tag ~= 13)
      or (version == "V2" and not v2Tags[tag]) then
      return nil, "native vehicle envelope contains invalid scalar fields"
    end
    if tag == 13 and value ~= 0 then
      return nil, "native BuyVehicle envelope has an unexpected value"
    elseif tag == 6 and (value < -1 or value >= maxStops) then
      return nil, "native SetLine envelope has an invalid stop index"
    elseif tag == 12 and (secondary < 1 or secondary > 256 or value ~= 0) then
      return nil, "native SellVehicle envelope has invalid selection metadata"
    elseif tag ~= 6 and tag ~= 12 and tag ~= 13 and secondary ~= 0 then
      return nil, "native lifecycle envelope has an unexpected secondary value"
    elseif targetOnlyTags[tag] and value ~= 0 then
      return nil, "native target-only lifecycle envelope has an unexpected value"
    elseif booleanTags[tag] and value ~= 0 and value ~= 1 then
      return nil, "native boolean lifecycle envelope has an invalid value"
    elseif tag == 9 and (value < 0 or value > 10000) then
      return nil, "native maintenance envelope has an invalid value"
    end
    return {
      version = version,
      tag = tag,
      targetLocalId = target,
      secondaryLocalId = secondary,
      value = value,
    }
  end

  gui.processSuppressedNativeVehicleCommandCapture = function()
    local snapshot = gui.snapshot or {}
    if snapshot.networkMode ~= "network" then return false end
    local take = rawget(_G, "tpf2mp_native_take_suppressed_vehicle_command")
    if type(take) ~= "function" then return false end

    for _ = 1, 8 do
      local called, raw = pcall(take)
      if not called then
        gui.lastError = "cannot read suppressed native vehicle command: " .. tostring(raw)
        return false
      end
      if raw == nil then break end
      local dropped = type(raw) == "string" and raw:match("^F1|queue%-overflow|(%d+)$") or nil
      if dropped then
        gui.nativeVehicleCapture.dropped = tonumber(dropped) or 0
        gui.lastError = "native vehicle capture queue overflowed; one or more clicks were rejected"
      else
        local decoded, decodeError = gui.decodeSuppressedNativeVehicleCommand(raw)
        if not decoded then
          gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
          gui.lastError = tostring(decodeError)
        else
          gui.pendingNativeVehicleCommands[#gui.pendingNativeVehicleCommands + 1] = {
            decoded = decoded,
            capturedFrame = gui.frames,
            maximumFrame = gui.frames + 240,
          }
          gui.nativeVehicleCapture.captured = (gui.nativeVehicleCapture.captured or 0) + 1
          gui.nativeVehicleCapture.lastTag = decoded.tag
          gui.nativeVehicleCapture.lastTarget = decoded.targetLocalId
          gui.nativeVehicleCapture.lastSecondary = decoded.secondaryLocalId
        end
      end
    end

    local queued = 0
    local index = 1
    while index <= #gui.pendingNativeVehicleCommands do
      local pending = gui.pendingNativeVehicleCommands[index]
      local decoded = pending.decoded
      if decoded.tag == 12 and decoded.secondaryLocalId ~= 1 then
        gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
        gui.nativeVehicleCapture.unsupportedSaleBatches =
          (gui.nativeVehicleCapture.unsupportedSaleBatches or 0) + 1
        gui.lastError = "multi-vehicle stock sale is blocked until atomic batch sale is supported"
        table.remove(gui.pendingNativeVehicleCommands, index)
      elseif decoded.tag ~= 13 and decoded.tag ~= 14 then
        local capture, counter = lifecycleCapture(decoded)
        if not capture then
          gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
          gui.lastError = "suppressed native vehicle command has no lifecycle adapter"
          table.remove(gui.pendingNativeVehicleCommands, index)
        else
          queueAction({
            type = "operation.capture",
            companyCid = snapshot.activeCompanyCid,
            capture = capture,
          })
          gui.nativeVehicleCapture[counter] = (gui.nativeVehicleCapture[counter] or 0) + 1
          table.remove(gui.pendingNativeVehicleCommands, index)
          queued = queued + 1
        end
      elseif #gui.pendingNativeVehicleGuiCaptures > 0
        and gui.pendingNativeVehicleGuiCaptures[1].expectedTag == decoded.tag then
        -- Pair config-bearing commands FIFO. The native scalar fields are
        -- authoritative; GUI entity/depot values are hints and are checked.
        local guiCapture = table.remove(gui.pendingNativeVehicleGuiCaptures, 1)
        local capture = guiCapture.capture
        if decoded.tag == 13 then
          capture.depotLocalId = decoded.secondaryLocalId
          capture.nativePlayerId = decoded.targetLocalId
        elseif tonumber(capture.targetLocalId) ~= decoded.targetLocalId then
          gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
          gui.lastError = "native ReplaceVehicle target did not match the stock GUI target"
          table.remove(gui.pendingNativeVehicleCommands, index)
          capture = nil
        end
        if capture then
          queueAction({
            type = "operation.capture",
            companyCid = snapshot.activeCompanyCid,
            capture = capture,
          })
          local counter = decoded.tag == 13 and "buys" or "replacements"
          gui.nativeVehicleCapture[counter] = (gui.nativeVehicleCapture[counter] or 0) + 1
          table.remove(gui.pendingNativeVehicleCommands, index)
          queued = queued + 1
        end
      elseif gui.frames >= pending.maximumFrame then
        gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
        gui.lastError = "native config-bearing vehicle command was rejected because its stock GUI consist was not captured"
        table.remove(gui.pendingNativeVehicleCommands, index)
      else
        index = index + 1
      end
    end

    local guiIndex = 1
    while guiIndex <= #gui.pendingNativeVehicleGuiCaptures do
      local pending = gui.pendingNativeVehicleGuiCaptures[guiIndex]
      if gui.frames >= pending.maximumFrame then
        gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
        gui.lastError = "vehicle-manager accept did not reach its pinned vehicle visitor"
        table.remove(gui.pendingNativeVehicleGuiCaptures, guiIndex)
      else
        guiIndex = guiIndex + 1
      end
    end
    return queued > 0
  end

  return {
    decode = gui.decodeSuppressedNativeVehicleCommand,
    process = gui.processSuppressedNativeVehicleCommandCapture,
  }
end

return M
