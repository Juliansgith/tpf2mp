local M = {}

local function digest(value)
  return type(value) == "string" and #value == 8
    and value:match("^[0-9a-f]+$") and value or nil
end

function M.capture(delta, capture, mappings)
  delta.identities = delta.identities or {}
  if type(capture) ~= "function" then return delta end
  local captureKind = {
    construction = true, station = true, station_group = true,
    depot = true, asset = true,
  }
  for _, mapping in ipairs(mappings) do
    local identities = {}
    for _, id in ipairs(captureKind[mapping.kind]
        and (delta.added[mapping.kind] or {}) or {}) do
      local called, value = pcall(capture, mapping.kind, id)
      if called and type(value) == "table" then
        local ordinary = digest(value.fingerprint)
        local topology = digest(value.topologyFingerprint)
        local neighbours = digest(value.topologyNeighbourFingerprint)
        if ordinary or topology then
          identities[tostring(id)] = {
            fingerprint = ordinary,
            topologyFingerprint = topology,
            topologyNeighbourFingerprint = neighbours,
          }
        end
      end
    end
    delta.identities[mapping.kind] = identities
  end
  return delta
end

function M.appendEncoded(rows, delta, mappings)
  for _, mapping in ipairs(mappings) do
    local values = {}
    local identities = delta.identities and delta.identities[mapping.kind] or {}
    for _, id in ipairs(delta.added[mapping.kind] or {}) do
      local identity = identities and identities[tostring(id)] or nil
      if type(identity) == "table" then
        values[#values + 1] = table.concat({
          tostring(id), identity.fingerprint or "-",
          identity.topologyFingerprint or "-",
          identity.topologyNeighbourFingerprint or "-",
        }, "@")
      end
    end
    rows[#rows + 1] = mapping.kind .. ":" .. table.concat(values, ";")
  end
end

function M.decodeRows(rows, mappings, result)
  for index, mapping in ipairs(mappings) do
    local row = rows[#mappings + 1 + index]
    local kind, encoded = row:match("^([%a_]+):(.*)$")
    if kind ~= mapping.kind then return false end
    local values = {}
    for item in string.gmatch(encoded, "[^;]+") do
      local id, ordinary, topology, neighbours =
        item:match("^(%d+)@([^@]+)@([^@]+)@([^@]+)$")
      if not id then return false end
      values[id] = {
        fingerprint = ordinary ~= "-" and ordinary or nil,
        topologyFingerprint = topology ~= "-" and topology or nil,
        topologyNeighbourFingerprint = neighbours ~= "-" and neighbours or nil,
      }
    end
    result.identities[kind] = values
  end
  return true
end

function M.normaliseKind(allIdentities, kind, added)
  local source = type(allIdentities) == "table" and allIdentities[kind] or nil
  if source ~= nil and type(source) ~= "table" then
    return nil, kind .. " identities are malformed"
  end
  local identities, addedSet = {}, {}
  for _, id in ipairs(added) do addedSet[tostring(id)] = true end
  for id, identity in pairs(source or {}) do
    local key = tostring(id)
    if not addedSet[key] or type(identity) ~= "table" then
      return nil, kind .. " identity does not name an added output"
    end
    local allowed = {
      fingerprint = true, topologyFingerprint = true,
      topologyNeighbourFingerprint = true,
    }
    for field in pairs(identity) do
      if not allowed[field] then return nil, kind .. " identity has an unknown field" end
    end
    local ordinary = identity.fingerprint
    local topology = identity.topologyFingerprint
    local neighbours = identity.topologyNeighbourFingerprint
    if (ordinary ~= nil and not digest(ordinary))
        or (topology ~= nil and not digest(topology))
        or (neighbours ~= nil and not digest(neighbours))
        or (ordinary == nil and topology == nil) then
      return nil, kind .. " identity fingerprint is invalid"
    end
    identities[key] = {
      fingerprint = ordinary, topologyFingerprint = topology,
      topologyNeighbourFingerprint = neighbours,
    }
  end
  return identities
end

return M
