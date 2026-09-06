-- Processed EdgeObject is not SimpleStreetProposal.EdgeObject. Validate the
-- regenerated geometry/model before touching only its public metadata fields;
-- never write Simple-only param/edgeEntity/model fields into native userdata.
local M = {}
function M.rewrite(observed, expected, edgeMap, facts, nodes, edges, field, assign)
  local original = field(expected, "edgeEntity")
  local mappedEdge = edgeMap[tostring(original)] or original
  local processedEdge = field(observed, "segmentEntity")
  if processedEdge ~= nil then
    if tonumber(processedEdge) ~= tonumber(mappedEdge) then
      return nil, "generated edge-object topology does not match the captured graph prefix"
    end
    local instance = field(observed, "modelInstance")
    if type(facts) ~= "table" or tonumber(field(instance, "modelId")) ~= facts.modelIndex
      or not require("tpf2_mp/edge_object_reference").matches(
        facts.category, tonumber(field(observed, "category")), field(observed, "left"))
      or field(observed, "left") ~= facts.left then
      return nil, "generated edge-object model/category/side differs from capture"
    end
    local oneWay = field(observed, "oneWay")
    if oneWay ~= nil and oneWay ~= facts.oneWay then
      return nil, "generated edge-object direction differs from capture"
    end
    local segment = edges[tonumber(mappedEdge)]
    local param, err = require("tpf2_mp/proposal_codec").nativeEdgeObjectParam(
      observed, segment, function(id) return nodes[id] end)
    if not param or math.abs(param - facts.param) > 0.001 then
      return nil, err or "generated edge-object position differs from capture"
    end
    for _, name in ipairs({ "playerEntity", "name" }) do
      local value = field(expected, name)
      if value ~= nil then
        local ok, writeError = assign(observed, name, value, "generated edge object " .. name)
        if not ok then return nil, writeError end
      end
    end
    return true
  end
  if tonumber(field(observed, "edgeEntity")) ~= tonumber(mappedEdge) then
    return nil, "generated edge-object topology does not match the captured graph prefix"
  end
  for _, name in ipairs({ "edgeEntity", "param", "oneWay", "left", "model", "playerEntity", "name" }) do
    local value = name == "edgeEntity" and mappedEdge or field(expected, name)
    if value ~= nil then
      local ok, err = assign(observed, name, value, "generated edge object " .. name)
      if not ok then return nil, err end
    end
  end
  return true
end
return M
