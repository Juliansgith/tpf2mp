local M = {}

function M.rows(kind, values, options)
  options = options or {}
  if options.exact then
    if #(values or {}) > 1 then
      return nil, "exact construction produced multiple indistinguishable " .. kind .. " outputs"
    end
    local rows = {}
    for index, localId in ipairs(values or {}) do
      rows[index] = { localId = localId, fingerprint = options.proposalDigest
        .. ":" .. kind .. ":" .. tostring(index) }
    end
    return rows
  end
  local rows, seen = {}, {}
  for _, localId in ipairs(values or {}) do
    local ok, fingerprint = pcall(options.fingerprint, localId, kind)
    if not ok or type(fingerprint) ~= "string" or fingerprint == "" then
      return nil, "construction output fingerprint is unavailable for " .. kind
    end
    if seen[fingerprint] then
      return nil, "construction produced ambiguous duplicate " .. kind .. " outputs"
    end
    seen[fingerprint] = true
    rows[#rows + 1] = { localId = localId, fingerprint = fingerprint }
  end
  table.sort(rows, function(a, b) return a.fingerprint < b.fingerprint end)
  return rows
end

return M
