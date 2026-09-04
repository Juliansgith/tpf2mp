local M = {}

function M.new(generate, stationLayout)
  return function(params, cargo, head)
    if type(params) ~= "table" or type(cargo) ~= "boolean"
      or type(head) ~= "boolean" then
      return nil, "stock station template arguments are invalid"
    end
    local canonical = stationLayout.params(params)
    if not canonical.year or canonical.year < 1850 or canonical.year > 3000
      or not canonical.seed or canonical.seed < 0 or canonical.seed > 2147483647
      or not stationLayout.inRange(canonical) then
      return nil, "stock station layout parameters are outside the supported range"
    end
    local generated = generate(canonical, cargo, head)
    if not generated then return nil, "stock station template could not be generated" end
    local copy = {}
    for slot, name in pairs(generated) do copy[slot] = name end
    return copy
  end
end

return M
