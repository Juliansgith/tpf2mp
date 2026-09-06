-- BASE_EDGE.objects uses EdgeObjectType: STOP_LEFT=0, STOP_RIGHT=1,
-- SIGNAL=2. The processed object's category is a different enum: a stock
-- passenger stop remains category 0 on BOTH sides (cargo stops use 1).
-- Its model identity must be checked separately; side is carried by `left`.
local M = {}

function M.matches(referenceType, processedCategory, left)
  if referenceType == 0 or referenceType == 1 then
    return (processedCategory == 0 or processedCategory == 1)
      and type(left) == "boolean" and referenceType == (left and 0 or 1)
  end
  return processedCategory == referenceType
end

return M
