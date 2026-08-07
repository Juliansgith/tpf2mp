local ssu = require "stylesheetutil"

function data()
  local result = {}
  local add = ssu.makeAdder(result)

  add("TPF2MPAuthoritativePanel", {
    backgroundColor = ssu.makeColor(18, 55, 65, 235),
    padding = { 8, 14, 8, 14 },
    margin = { 0, 0, 2, 0 },
  })
  add("TPF2MPAuthoritativePanel TPF2MPAuthoritativeTitle", {
    fontSize = 15,
  })
  add("TPF2MPAuthoritativePanel TPF2MPAuthoritativePrimary", {
    fontSize = 13,
    padding = { 3, 0, 0, 0 },
  })
  add("TPF2MPAuthoritativePanel TPF2MPAuthoritativeSecondary", {
    fontSize = 12,
    padding = { 2, 0, 0, 0 },
  })

  return result
end
