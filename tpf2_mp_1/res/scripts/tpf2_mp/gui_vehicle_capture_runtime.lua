local M = {}

local function boundedInteger(value, low, high)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) or number < low or number > high then
    return nil
  end
  return number
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
    local tagText, targetText, secondaryText, valueText =
      raw:match("^V1|(-?%d+)|(-?%d+)|(-?%d+)|(-?%d+)$")
    local tag = boundedInteger(tagText, 0, 36)
    local target = boundedInteger(targetText, 0, 2147483647)
    local secondary = boundedInteger(secondaryText, 0, 2147483647)
    local value = boundedInteger(valueText, -1, 4095)
    if (tag ~= 6 and tag ~= 13) or not target or not secondary or not value then
      return nil, "native vehicle envelope contains invalid scalar fields"
    end
    if tag == 13 and value ~= 0 then
      return nil, "native BuyVehicle envelope has an unexpected value"
    elseif tag == 6 and (value < -1 or value >= maxStops) then
      return nil, "native SetLine envelope has an invalid stop index"
    end
    return {
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
      if decoded.tag == 6 then
        queueAction({
          type = "operation.capture",
          companyCid = snapshot.activeCompanyCid,
          capture = {
            kind = "vehicle.assign",
            targetLocalId = decoded.targetLocalId,
            lineLocalId = decoded.secondaryLocalId,
            stopIndex = decoded.value,
          },
        })
        gui.nativeVehicleCapture.assignments =
          (gui.nativeVehicleCapture.assignments or 0) + 1
        table.remove(gui.pendingNativeVehicleCommands, index)
        queued = queued + 1
      elseif #gui.pendingNativeVehicleGuiCaptures > 0 then
        -- Pair BuyVehicle attempts FIFO. The native depot/player fields are
        -- authoritative; selectedDepotId is only a GUI hint and may be stale.
        local guiCapture = table.remove(gui.pendingNativeVehicleGuiCaptures, 1)
        guiCapture.capture.depotLocalId = decoded.secondaryLocalId
        guiCapture.capture.nativePlayerId = decoded.targetLocalId
        queueAction({
          type = "operation.capture",
          companyCid = snapshot.activeCompanyCid,
          capture = guiCapture.capture,
        })
        gui.nativeVehicleCapture.buys = (gui.nativeVehicleCapture.buys or 0) + 1
        table.remove(gui.pendingNativeVehicleCommands, index)
        queued = queued + 1
      elseif gui.frames >= pending.maximumFrame then
        gui.nativeVehicleCapture.invalid = (gui.nativeVehicleCapture.invalid or 0) + 1
        gui.lastError = "native BuyVehicle was rejected because its stock GUI consist was not captured"
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
        gui.lastError = "vehicle-manager accept did not reach the pinned BuyVehicle visitor"
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
