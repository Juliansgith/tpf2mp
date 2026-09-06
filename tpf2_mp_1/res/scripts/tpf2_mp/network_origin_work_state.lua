local M = {}

function M.snapshot(queue, awaitingOrder)
  local count = 0
  for _, item in ipairs(queue or {}) do
    local action = type(item) == "table" and item.action or nil
    local capture = type(action) == "table" and action.type == "operation.capture"
      and (type(action.capture) == "table" and action.capture or action) or nil
    if type(action) == "table" and action.originCaptureToken ~= nil
      or type(capture) == "table" and capture.originApplied == true then
      count = count + 1
    end
  end
  local awaiting = type(awaitingOrder) == "table"
    and awaitingOrder.originCaptureToken ~= nil
  return { pending = count > 0 or awaiting, deferredCount = count,
    awaitingOrder = awaiting }
end

return M
