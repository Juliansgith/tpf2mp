local M = {}

function M.automatic(value)
  value = type(value) == "table" and value or {}
  local age = tonumber(value.lastCompletedAgeSeconds)
  local ageText = "-"
  if age then
    ageText = age < 60 and (tostring(math.floor(age)) .. "s")
      or (tostring(math.floor(age / 60)) .. "m")
  end
  local nextDue = tonumber(value.nextDueInSeconds)
  return string.format(
    "Automatic recovery: %s | latest %s | age %s | next %s%s",
    tostring(value.status or "unavailable"),
    value.lastBoundarySeq and ("boundary " .. tostring(value.lastBoundarySeq)) or "none",
    ageText, nextDue and (tostring(math.max(0, math.floor(nextDue))) .. "s") or "-",
    value.lastError and (" | " .. tostring(value.lastError)) or "")
end

return M
