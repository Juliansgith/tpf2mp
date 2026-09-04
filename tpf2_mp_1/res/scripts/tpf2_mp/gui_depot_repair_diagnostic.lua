local M = {}

function M.emit(log, proposalId, geometry)
  if type(log) ~= "function" then return end
  geometry = type(geometry) == "table" and geometry or {}
  local source = geometry.sourceInternalPosition or {}
  local internal = geometry.helperInternalPosition or {}
  local external = geometry.helperExternalPosition or {}
  local sourceTangent = geometry.sourceTangent or {}
  local tangent = geometry.derivedTangent or {}
  local dx, dy, dz = tonumber(tangent.x) or 0,
    tonumber(tangent.y) or 0, tonumber(tangent.z) or 0
  log("depot-connection-repair-geometry", {
    proposalId = proposalId,
    sourceInternalX = tonumber(source.x), sourceInternalY = tonumber(source.y),
    sourceInternalZ = tonumber(source.z), helperInternalX = tonumber(internal.x),
    helperInternalY = tonumber(internal.y), helperInternalZ = tonumber(internal.z),
    helperExternalX = tonumber(external.x), helperExternalY = tonumber(external.y),
    helperExternalZ = tonumber(external.z), sourceTangentX = tonumber(sourceTangent.x),
    sourceTangentY = tonumber(sourceTangent.y), sourceTangentZ = tonumber(sourceTangent.z),
    derivedTangentX = dx, derivedTangentY = dy, derivedTangentZ = dz,
    derivedLength = math.sqrt(dx * dx + dy * dy + dz * dz),
  })
end

return M
