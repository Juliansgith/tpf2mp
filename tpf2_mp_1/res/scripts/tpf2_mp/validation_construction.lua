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

function M.cargoStationModules(currentYear, catenary)
  local era = currentYear < 1920 and "a" or (currentYear < 1980 and "b" or "c")
  local prefix = "station/rail/modular_station/"
  local function stationModule(name, metadata)
    return { name = prefix .. name, metadata = metadata }
  end
  local trackModule = catenary and "platform_track_catenary.module" or "platform_track.module"
  return {
    [3400020] = stationModule("main_building_1_cargo.module", {
      era = 5,
      level = 1,
      span = { 1, 2 },
      moreCapacity = { cargo = 20, passenger = 0 },
      snapPoint = {
        0, -1, 0, 0,
        1, 0, 0, 0,
        0, 0, 1, 0,
        -14, 0, 0, 1,
      },
    }),
    [6400000] = stationModule("platform_cargo_era_" .. era .. ".module", {
      platform = true, cargo_platform = true,
    }),
    [6400010] = stationModule("platform_cargo_era_" .. era .. ".module", {
      platform = true, cargo_platform = true,
    }),
    [8402000] = stationModule(trackModule, { track = true }),
    [8402010] = stationModule(trackModule, { track = true }),
  }
end

local function module(name, metadata)
  return { name = name, variant = 0, metadata = metadata or {} }
end

local function airfieldModules(cargo)
  local terminal = cargo and "station/air/airfield_cargo_terminal.module"
    or "station/air/airfield_passenger_terminal.module"
  return {
    [10001000] = module("station/air/airfield_main_building.module", {
      moreCapacity = { cargo = 40, passenger = 100 },
    }),
    [10070002] = module(terminal, cargo and {
      cargo = true, moreCapacity = { cargo = 20, passenger = 0 },
    } or {
      moreCapacity = { cargo = 0, passenger = 20 },
    }),
    -- One terminal means the stock createTemplateFn selects slot +4.
    [10002004] = module("station/air/airfield_hangar.module"),
  }
end

local function airportModules(cargo, currentYear, direction)
  direction = tonumber(direction) == 1 and 1 or 0
  local terminalSlot = cargo and 80006 or 70006
  local terminal = cargo and "station/air/airport_cargo_terminal.module"
    or "station/air/airport_terminal.module"
  return {
    [1002] = module("station/air/airport_main_building.module", {
      moreCapacity = { cargo = 100, passenger = 200 },
    }),
    [terminalSlot] = module(terminal, cargo and {
      cargo = true, moreCapacity = { cargo = 40, passenger = 0 },
    } or {
      cargo = false, moreCapacity = { cargo = 0, passenger = 100 },
    }),
    -- One terminal means the stock createTemplateFn selects slot +10.
    [2010] = module("station/air/airport_hangar.module"),
    [9001 - direction] = module(currentYear > 1980
      and "station/air/airport_era_c_landing_direction.module"
      or "station/air/airport_era_b_landing_direction.module"),
  }
end

local function harborSlot(x, y, facing)
  return 1000000 * (x + 100) + 100 * (y + 100) + facing
end

function M.harborModules(cargo, large, terminalIndex)
  cargo = cargo == true
  large = large == true
  terminalIndex = math.max(0, math.min(2, math.floor(tonumber(terminalIndex) or 0)))
  local modules = {}
  local function add(x, y, facing, name, metadata)
    modules[harborSlot(x, y, facing)] = module(name, metadata)
  end
  local commonEntrance = { platform = true, type = 0 }
  add(1, 1, 50, "station/water/pedestrian_entrance.module", commonEntrance)
  add(0, 1, 50, "station/water/pedestrian_entrance.module", commonEntrance)
  add(-1, 1, 50, "station/water/pedestrian_entrance.module", commonEntrance)
  add(-2, 1, 50, "station/water/pedestrian_entrance.module", commonEntrance)

  local mainCapacity = cargo and { cargo = 200, passenger = 0 }
    or { cargo = 0, passenger = 150 }
  add(0, 0, 28, cargo and "station/water/cargo_dock_50_50.module"
    or "station/water/passenger_dock_50_50.module", {
      platform = true, cargo = cargo or nil, passenger = not cargo or nil,
      type = 0, moreCapacity = mainCapacity,
    })

  local platform = cargo and (large and "station/water/cargo_dock_100_25.module"
      or "station/water/cargo_dock_50_12.module")
    or (large and "station/water/passenger_dock_100_25.module"
      or "station/water/passenger_dock_50_12.module")
  local platformCapacity = cargo and { cargo = large and 60 or 30, passenger = 0 }
    or { cargo = 0, passenger = large and 50 or 25 }
  local platformMetadata = {
    platform = true, cargo = cargo or nil, passenger = not cargo or nil,
    type = large and 1 or (cargo and 2 or 0), moreCapacity = platformCapacity,
  }
  local pier = large and "station/water/medium_pier.module"
    or "station/water/small_pier.module"
  local pierMetadata = { pier = true, skipWaterCollision = true }
  local terminals = 2 ^ terminalIndex
  if large then
    if terminals == 1 then
      add(0, -4, 12, platform, platformMetadata)
      add(0, -6, 44, pier, pierMetadata)
    elseif terminals == 2 then
      add(0, -4, 8, platform, platformMetadata)
      add(-2, -7, 47, pier, pierMetadata)
      add(1, -7, 45, pier, pierMetadata)
    else
      add(2, -6, 8, platform, platformMetadata)
      add(3, -4, 11, platform, platformMetadata)
      add(-2, -6, 8, platform, platformMetadata)
      add(0, -9, 47, pier, pierMetadata)
      add(-4, -9, 47, pier, pierMetadata)
      add(3, -9, 45, pier, pierMetadata)
      add(-1, -9, 45, pier, pierMetadata)
    end
  elseif terminals == 1 then
    add(0, -4, 4, platform, platformMetadata)
    add(0, -5, 36, pier, pierMetadata)
  else
    add(-2, -4, 0, platform, platformMetadata)
    add(1, -4, 0, platform, platformMetadata)
    add(-1, -5, 37, pier, pierMetadata)
    add(0, -5, 39, pier, pierMetadata)
    if terminals == 4 then
      add(-3, -5, 39, pier, pierMetadata)
      add(2, -5, 37, pier, pierMetadata)
    end
  end
  return modules
end

function M.spec(kind, currentYear, edited)
  if kind == "depot" then
    return {
      fileName = "depot/train_depot_era_a.con",
      params = { trackType = 0, catenary = 0, year = currentYear },
    }
  elseif kind == "station" or kind == "cargo_station" then
    return {
      fileName = "station/rail/modular_station/modular_station.con",
      params = {
        templateIndex = 0,
        tracks = 0,
        length = 0,
        trackType = 0,
        catenary = edited and 1 or 0,
        year = currentYear,
        modules = kind == "cargo_station"
          and M.cargoStationModules(currentYear, edited == true)
          or M.stationModules(currentYear, edited == true),
      },
    }
  elseif kind == "airfield" or kind == "cargo_airfield" then
    -- Disposable maps start in 1850.  The construction helper will accept an
    -- unavailable .con root at that date, but Build 35924 omits the template's
    -- terminal/hangar outputs and leaves a decorative shell.  Exercise the
    -- stock resource at its real availability boundary instead.
    local availableYear = math.max(1920, tonumber(currentYear) or 1920)
    return {
      fileName = "station/air/airfield.con",
      params = {
        templateIndex = kind == "cargo_airfield" and 1 or 0,
        -- Stock semantics: zero includes a hangar; terminals is zero-based.
        hangar = 0, terminals = 0, seed = 0, year = availableYear,
        -- game.interface.buildConstruction does not run createTemplateFn;
        -- player GUI proposals already carry this materialised module map.
        modules = airfieldModules(kind == "cargo_airfield"),
      },
    }
  elseif kind == "airport" or kind == "cargo_airport" then
    local availableYear = math.max(1950, tonumber(currentYear) or 1950)
    return {
      fileName = "station/air/airport.con",
      params = {
        templateIndex = kind == "cargo_airport" and 1 or 0,
        hangar = 0, terminals = 0, dir = 0, seed = 0, year = availableYear,
        modules = airportModules(kind == "cargo_airport", availableYear, 0),
      },
    }
  elseif kind == "passenger_harbor" or kind == "cargo_harbor" then
    local cargo = kind == "cargo_harbor"
    return {
      fileName = "station/water/harbor_modular.con",
      params = {
        templateIndex = cargo and 1 or 0,
        size = 0, terminals = 0, seed = 0, year = currentYear,
        modules = M.harborModules(cargo, false, 0),
      },
    }
  elseif kind == "shipyard" then
    return {
      fileName = "depot/shipyard_era_a.con",
      params = { seed = 0, year = currentYear },
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
