local M = {}

function M.verify(command, materialisation, safeField)
  if type(safeField) ~= "function" then
    return nil, "processed BuildProposal verifier has no safe field reader"
  end
  local construction = type(materialisation) == "table"
    and materialisation.construction or nil
  local expected = type(construction) == "table" and construction.removalIds or nil
  if type(expected) ~= "table" or #expected == 0 then return true end
  local processed = safeField(command, "proposal")
  local removals = safeField(processed, "toRemove")
    or safeField(processed, "constructionsToRemove")
  if removals == nil then
    return nil, "processed BuildProposal lost its construction-removal vector"
  end
  local lengthOk, length = pcall(function() return #removals end)
  if not lengthOk or tonumber(length) ~= #expected then
    return nil, "processed BuildProposal changed its construction-removal count"
  end
  local observed = {}
  for index = 1, #expected do
    local readOk, entity = pcall(function() return removals[index] end)
    entity = readOk and tonumber(entity) or nil
    if not entity or entity < 0 or entity ~= math.floor(entity) or observed[entity] then
      return nil, "processed BuildProposal contains an invalid construction removal"
    end
    observed[entity] = true
  end
  for _, entity in ipairs(expected) do
    if not observed[entity] then
      return nil, "processed BuildProposal omitted construction removal " .. tostring(entity)
    end
  end
  return true
end

return M
