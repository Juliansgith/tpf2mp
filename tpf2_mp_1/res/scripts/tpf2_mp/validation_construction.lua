local M = {}

function M.year()
  local currentYear = 1850
  if type(game.interface.getGameTime) == "function" then
    local timeOk, gameTime = pcall(game.interface.getGameTime)
    local observedYear = timeOk and type(gameTime) == "table" and type(gameTime.date) == "table"
      and tonumber(gameTime.date.year) or nil
    if observedYear then currentYear = math.floor(observedYear) end
  end
  return currentYear
end

function M.stationModules(currentYear, catenary)
  local era = currentYear < 1920 and "a" or (currentYear < 1980 and "b" or "c")
  local prefix = "station/rail/modular_station/"
  local eraIndex = era == "a" and 0 or (era == "b" and 1 or 2)
  local passengerCapacity = era == "a" and 20 or (era == "b" and 25 or 30)
  local function stationModule(name, metadata)
    return { name = prefix .. name, metadata = metadata }
  end
  local trackModule = catenary and "platform_track_catenary.module" or "platform_track.module"
  return {
    [3400020] = stationModule("main_building_1_era_" .. era .. ".module", {
      era = eraIndex,
      level = 1,
      span = { 1, 2 },
      moreCapacity = { cargo = 0, passenger = passengerCapacity },
      snapPoint = {
        0, -1, 0, 0,
        1, 0, 0, 0,
        0, 0, 1, 0,
        -14, 0, 0, 1,
      },
    }),
    [7400000] = stationModule("platform_passenger_era_" .. era .. ".module", {
      platform = true, passenger_platform = true,
    }),
    [7400010] = stationModule("platform_passenger_era_" .. era .. ".module", {
      platform = true, passenger_platform = true,
    }),
    [8401000] = stationModule(trackModule, { track = true }),
    [8401010] = stationModule(trackModule, { track = true }),
    [10400000] = stationModule("platform_passenger_roof_era_" .. era .. ".module", {
      platform_roof = true,
    }),
    [10400010] = stationModule("platform_passenger_roof_era_" .. era .. ".module", {
      platform_roof = true,
    }),
    [10800000] = stationModule("addon_platform_passenger_stairs_era_" .. era .. ".module", {
      underground = true,
    }),
  }
end

function M.spec(kind, currentYear, edited)
  if kind == "depot" then
    return {
      fileName = "depot/train_depot_era_a.con",
      params = { trackType = 0, catenary = 0, year = currentYear },
    }
  elseif kind == "station" then
    return {
      fileName = "station/rail/modular_station/modular_station.con",
      params = {
        templateIndex = 0,
        tracks = 0,
        length = 0,
        trackType = 0,
        catenary = edited and 1 or 0,
        year = currentYear,
        modules = M.stationModules(currentYear, edited == true),
      },
    }
  elseif kind == "asset" then
    return {
      fileName = edited and "asset/default_multi_bench_new.con"
        or "asset/default_multi_bench_old.con",
      params = { paramX = 0, paramY = 0, seed = 0, year = currentYear },
    }
  end
  return nil
end


return M
