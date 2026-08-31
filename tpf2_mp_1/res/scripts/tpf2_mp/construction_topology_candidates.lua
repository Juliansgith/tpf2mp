local M = {}

function M.collect(kind, record, added, after)
  local values, seen = {}, {}
  local function add(localId)
    localId = tonumber(localId)
    if localId and not seen[localId] then
      seen[localId] = true
      values[#values + 1] = localId
    end
  end
  for _, localId in ipairs(added[kind] or {}) do add(localId) end
  for _, input in ipairs(record.localInputs or {}) do
    if input.kind == kind and after[kind]
      and after[kind][tonumber(input.localId)] then add(input.localId) end
  end
  table.sort(values)
  return values
end

function M.unexpectedRemoval(record, removed)
  local expected = { node = {}, edge = {}, edge_object = {} }
  for _, input in ipairs(record.localInputs or {}) do
    if expected[input.kind] then expected[input.kind][tonumber(input.localId)] = true end
  end
  for kind, values in pairs(expected) do
    for _, localId in ipairs(removed[kind] or {}) do
      if not values[tonumber(localId)] then
        return kind .. " " .. tostring(localId)
          .. " was removed without a canonical input"
      end
    end
  end
  return nil
end

return M
