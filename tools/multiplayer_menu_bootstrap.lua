-- Console-state main-menu bootstrap for launcher-managed TPF2MP sessions.
--
-- The application API documents app.loadGame(), but Build 35924 asserts when
-- it is called from the interactive console because the load transition
-- re-enters the console's active UI invocation.  This bootstrap deliberately
-- exposes live native-control rectangles to a launcher which performs ordinary
-- physical mouse clicks.  The launcher pins a uniquely named save copy and
-- asks this script to advance one idempotent stage at a time through files in
-- launcher/.
function data()
  local peer = os.getenv("TPF2MP_PEER_ID")
  local session = os.getenv("TPF2MP_SESSION_ID")
  local bridgeRoot = os.getenv("TPF2MP_BRIDGE_DIR")
  if (peer ~= "player1" and peer ~= "player2")
      or type(session) ~= "string" or not session:match("^[%w][%w_.%-]*$")
      or #session > 64 or type(bridgeRoot) ~= "string" or bridgeRoot == "" then
    -- This file is a disposable base-game overlay. If a launcher dies before
    -- removing it, an ordinary Steam launch must not gain a MULTIPLAYER entry
    -- or run any menu automation.
    return { update = function() end }
  end
  local expectedSave = tostring(os.getenv("TPF2MP_STAGED_SAVE_NAME") or "")
  local requireMenuEntry = tostring(os.getenv("TPF2MP_REQUIRE_MENU_ENTRY") or "") == "1"
  local root = bridgeRoot:gsub("\\", "/"):gsub("/+$", "")
  local frames = 0
  local stage = "main-menu"
  local lastPublished = ""
  local entryInstalled = false
  local entrySelected = false
  -- Automated validators may treat a launcher-pinned save as an implicit load
  -- request. Normal Host/Join sessions instead require the human to select the
  -- visible MULTIPLAYER title entry before the launcher drives native loading.
  local loadRequested = expectedSave ~= "" and not requireMenuEntry
  local startClicked = false
  local lastError = nil
  local treeDumped = false
  local newGameTreeDumped = false
  local loadTreeDumped = false
  local networkPumpCount = 0
  local networkPumpError = nil
  local networkPumpLastWall = nil
  local networkPumpFallbackFrame = 0
  local networkPumpLastRegistrationFrame = 0
  local networkPumpReadySource = "none"
  local networkPumpReadyValue = "unchecked"
  local networkPumpNativePresent = false
  local networkPumpLastAttemptFrame = 0
  local networkPumpLastSuccessFrame = 0
  local networkPumpGeneration = ""
  local networkPumpLastSuccessGeneration = ""
  local networkPumpReceiptGeneration = nil
  local networkPumpDispatchSource = "none"
  local networkPumpPausedRequired = true
  local networkWakeIssued = false
  local recoveryPrepareWakeIssued = false
  local lastWorldStatusWall = nil
  local lastWorldStatusFrame = 0
  local publish

  local function quote(value)
    value = tostring(value or "")
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"')
      :gsub('\r', '\\r'):gsub('\n', '\\n') .. '"'
  end

  local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
  end

  local function markerValue(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return tostring(value or ""):match("^%s*(.-)%s*$")
  end

  local function directItem(id)
    local ok, value = pcall(api.gui.util.getById, id)
    if not ok then return nil end
    return value
  end

  -- UI handles can become invalid userdata between a lookup and the next
  -- frame while the native save loader replaces MenuUI. Even reading a
  -- method from such a handle invokes __index and can throw, so method lookup
  -- itself must live inside pcall.
  local function safeMethod(value, name)
    if not value then return nil end
    local ok, method = pcall(function() return value[name] end)
    return ok and type(method) == "function" and method or nil
  end

  local function safeId(value)
    local method = safeMethod(value, "getId")
    if not method then return "" end
    local ok, result = pcall(method, value)
    return ok and tostring(result or "") or ""
  end

  local function childLayout(value)
    local method = safeMethod(value, "getLayout")
    if not method then return nil end
    local ok, result = pcall(method, value)
    return ok and result or nil
  end

  local function childContent(value)
    local method = safeMethod(value, "getContent")
    if not method then return nil end
    local ok, result = pcall(method, value)
    return ok and result or nil
  end

  local function safeStringCall(value, method)
    local callable = safeMethod(value, method)
    if not callable then return "" end
    local ok, result = pcall(callable, value)
    return ok and tostring(result or "") or ""
  end

  local function normalized(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  end

  local function subtreeHasText(value, wanted, seen, depth, budget)
    if not value or seen[value] or depth > 24 or budget.remaining <= 0 then return false end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if normalized(safeStringCall(value, "getText")) == wanted then return true end
    local content = childContent(value)
    if content and content ~= value
      and subtreeHasText(content, wanted, seen, depth + 1, budget) then return true end
    local nested = childLayout(value)
    if nested and nested ~= value
      and subtreeHasText(nested, wanted, seen, depth + 1, budget) then return true end
    local getNumItems, getItem = safeMethod(value, "getNumItems"), safeMethod(value, "getItem")
    if getNumItems and getItem then
      local countOk, count = pcall(getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 255) do
        local childOk, child = pcall(getItem, value, index)
        if childOk and child
          and subtreeHasText(child, wanted, seen, depth + 1, budget) then return true end
      end
    end
    return false
  end

  local function findClickableByText(value, wanted, seen, depth, budget)
    if not value or seen[value] or depth > 32 or budget.remaining <= 0 then return nil end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if safeMethod(value, "click")
      and subtreeHasText(value, wanted, {}, 0, { remaining = 2048 }) then return value end
    local content = childContent(value)
    if content and content ~= value then
      local found = findClickableByText(content, wanted, seen, depth + 1, budget)
      if found then return found end
    end
    local nested = childLayout(value)
    if nested and nested ~= value then
      local found = findClickableByText(nested, wanted, seen, depth + 1, budget)
      if found then return found end
    end
    local getNumItems, getItem = safeMethod(value, "getNumItems"), safeMethod(value, "getItem")
    if getNumItems and getItem then
      local countOk, count = pcall(getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(getItem, value, index)
        if childOk and child then
          local found = findClickableByText(child, wanted, seen, depth + 1, budget)
          if found then return found end
        end
      end
    end
    return nil
  end

  local function findExactTextItem(value, wanted, seen, depth, budget)
    -- Save rows sit below Table -> ScrollArea -> Content -> layout wrappers.
    -- On a high-DPI 2499x1908 UI that is 18 levels deep, so the generic
    -- sixteen-level guard used for ordinary buttons is insufficient.
    if not value or seen[value] or depth > 32 or budget.remaining <= 0 then return nil end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if normalized(safeStringCall(value, "getText")) == wanted then return value end
    local content = childContent(value)
    if content and content ~= value then
      local found = findExactTextItem(content, wanted, seen, depth + 1, budget)
      if found then return found end
    end
    local nested = childLayout(value)
    if nested and nested ~= value then
      local found = findExactTextItem(nested, wanted, seen, depth + 1, budget)
      if found then return found end
    end
    local getNumItems, getItem = safeMethod(value, "getNumItems"), safeMethod(value, "getItem")
    if getNumItems and getItem then
      local countOk, count = pcall(getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(getItem, value, index)
        if childOk and child then
          local found = findExactTextItem(child, wanted, seen, depth + 1, budget)
          if found then return found end
        end
      end
    end
    return nil
  end

  local function findInTree(value, wanted, seen, depth, budget)
    if not value or budget.remaining <= 0 or depth > 32 then return nil end
    if seen[value] then return nil end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if safeId(value) == wanted then return value end
    local nested = childLayout(value)
    if nested and nested ~= value then
      local found = findInTree(nested, wanted, seen, depth + 1, budget)
      if found then return found end
    end
    local content = childContent(value)
    if content and content ~= value then
      local found = findInTree(content, wanted, seen, depth + 1, budget)
      if found then return found end
    end
    local getNumItems, getItem = safeMethod(value, "getNumItems"), safeMethod(value, "getItem")
    if getNumItems and getItem then
      local countOk, count = pcall(getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(getItem, value, index)
        if childOk and child then
          local found = findInTree(child, wanted, seen, depth + 1, budget)
          if found then return found end
        end
      end
    end
    return nil
  end

  local function findAddableAncestor(value, target, ancestors, seen, depth, budget)
    if not value or seen[value] or depth > 16 or budget.remaining <= 0 then return nil end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if value == target then
      for index = #ancestors, 1, -1 do
        if safeMethod(ancestors[index], "addItem") then return ancestors[index] end
      end
      return nil
    end
    ancestors[#ancestors + 1] = value
    local content = childContent(value)
    if content and content ~= value then
      local found = findAddableAncestor(content, target, ancestors, seen, depth + 1, budget)
      if found then ancestors[#ancestors] = nil; return found end
    end
    local nested = childLayout(value)
    if nested and nested ~= value then
      local found = findAddableAncestor(nested, target, ancestors, seen, depth + 1, budget)
      if found then ancestors[#ancestors] = nil; return found end
    end
    local getNumItems, getItem = safeMethod(value, "getNumItems"), safeMethod(value, "getItem")
    if getNumItems and getItem then
      local countOk, count = pcall(getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(getItem, value, index)
        if childOk and child then
          local found = findAddableAncestor(child, target, ancestors, seen, depth + 1, budget)
          if found then ancestors[#ancestors] = nil; return found end
        end
      end
    end
    ancestors[#ancestors] = nil
    return nil
  end

  local function item(id)
    local direct = directItem(id)
    if direct then return direct end
    local rootItem = directItem("menuUI")
    if not rootItem then return nil end
    local found = findInTree(rootItem, id, {}, 0, { remaining = 16384 })
    if not found then
      local labels = {
        ["create-new-game"] = { "free game" },
        ["load-game"] = { "load game" },
        ["next-game-button"] = { "next" },
        ["start-game-button"] = { "start" },
        ["tpf2mp.mainMenuEntry"] = { "multiplayer" },
      }
      if labels[id] then
        for _, label in ipairs(labels[id]) do
          found = findClickableByText(rootItem, label, {}, 0, { remaining = 16384 })
          if found then break end
        end
      end
    end
    return found
  end

  local function dumpMenuTree(fileName)
    local file = io.open(root .. "/launcher/" .. fileName, "wb")
    if not file then return end
    local seen, budget = {}, { remaining = 16384 }
    local function visit(value, path, depth)
      if not value or seen[value] or budget.remaining <= 0 or depth > 32 then return end
      seen[value] = true
      budget.remaining = budget.remaining - 1
      local id = safeId(value)
      local name = safeStringCall(value, "getName")
      local text = safeStringCall(value, "getText")
      file:write(path .. "\t" .. id .. "\t" .. name .. "\t" .. text
        .. "\tclick=" .. tostring(safeMethod(value, "click") ~= nil)
        .. "\t" .. tostring(value) .. "\n")
      local nested = childLayout(value)
      if nested and nested ~= value then visit(nested, path .. ".layout", depth + 1) end
      local content = childContent(value)
      if content and content ~= value then visit(content, path .. ".content", depth + 1) end
      local getNumItems, getItem = safeMethod(value, "getNumItems"), safeMethod(value, "getItem")
      if getNumItems and getItem then
        local countOk, count = pcall(getNumItems, value)
        count = countOk and tonumber(count) or 0
        for index = 0, math.min(count - 1, 511) do
          local childOk, child = pcall(getItem, value, index)
          if childOk and child then visit(child, path .. "[" .. index .. "]", depth + 1) end
        end
      end
    end
    visit(directItem("menuUI"), "menuUI", 0)
    file:close()
  end

  local function visible(value)
    local method = safeMethod(value, "isVisible")
    if not method then return false end
    local ok, result = pcall(method, value)
    return ok and result == true
  end

  local function effectivelyVisible(value)
    if not value then return false end
    local current = value
    local seen = {}
    local checked = false
    for _ = 1, 64 do
      if seen[current] then break end
      seen[current] = true
      local method = safeMethod(current, "isVisible")
      if method then
        local ok, result = pcall(method, current)
        if not ok or result ~= true then return false end
        checked = true
      end
      local getParent = safeMethod(current, "getParent")
      if not getParent then break end
      local ok, parent = pcall(getParent, current)
      if not ok or not parent or parent == current then break end
      current = parent
    end
    return checked
  end

  local function rectJson(value)
    local method = safeMethod(value, "getContentRect")
    if not method then return "null" end
    local ok, rect = pcall(method, value)
    if not ok or not rect then return "null" end
    local fields = {}
    for _, key in ipairs({ "x", "y", "w", "h" }) do
      local readOk, number = pcall(function() return tonumber(rect[key]) end)
      if not readOk or number == nil then return "null" end
      fields[#fields + 1] = '"' .. key .. '":' .. tostring(math.floor(number + 0.5))
    end
    return "{" .. table.concat(fields, ",") .. "}"
  end

  local function topAncestor(value)
    local current, last = value, value
    for _ = 1, 48 do
      local method = safeMethod(current, "getParent")
      if not method then break end
      local ok, parent = pcall(method, current)
      if not ok or not parent or parent == current then break end
      last, current = parent, parent
    end
    return last
  end

  local function clickable(id)
    local value = item(id)
    return safeMethod(value, "click") ~= nil
  end

  local function exactTextItem(text)
    local wanted = normalized(text)
    if wanted == "" then return nil end
    local rootItem = directItem("menuUI")
    if not rootItem then return nil end
    return findExactTextItem(rootItem, wanted, {}, 0, { remaining = 4096 })
  end

  local function expectedSaveItem()
    return exactTextItem(expectedSave)
  end

  local function saveIndexReady()
    -- Build 35924 constructs the save rows before their metadata/index is
    -- usable. Clicking a visible row in this state is ignored and Start then
    -- launches whichever unrelated save was selected on page entry. The
    -- stock status label is the only live UI ownership signal for this race.
    local pending = exactTextItem("Savegame not ready")
    return not (pending and effectivelyVisible(pending))
  end

  publish = function(force, menuVisibilityHint)
    local menuRoot = directItem("menuUI")
    local menuVisible = menuVisibilityHint
    if menuVisible == nil then menuVisible = visible(menuRoot) end
    local inGameSave = directItem("ingameMenu.saveGameButton")
    local inGameRoot = topAncestor(inGameSave or directItem("menu.fileMenuButton"))
    -- Once the world is loaded, the hidden title-menu tree can contain thousands
    -- of retained save-row widgets. Do not repeatedly walk it for controls that
    -- cannot be visible; only the in-game Save surface remains relevant.
    local expectedItem = menuVisible and expectedSaveItem() or nil
    local indexReady = not menuVisible or saveIndexReady()
    local fields = {
      schemaVersion = "4",
      peer = quote(peer),
      session = quote(session),
      stage = quote(stage),
      frames = tostring(frames),
      menuVisible = tostring(menuVisible),
      entryInstalled = tostring(entryInstalled),
      entrySelected = tostring(entrySelected),
      createNewGame = tostring(menuVisible and clickable("create-new-game") or false),
      loadGame = tostring(menuVisible and clickable("load-game") or false),
      startGame = tostring(menuVisible and clickable("start-game-button") or false),
      nextGame = tostring(menuVisible and clickable("next-game-button") or false),
      basicSettings = tostring(menuVisible and item("mainMenu.loadGame.basicSettings") ~= nil or false),
      expectedSave = quote(expectedSave),
      requireMenuEntry = tostring(requireMenuEntry),
      expectedSaveVisible = tostring(expectedItem ~= nil),
      saveIndexReady = tostring(indexReady),
      createNewGameRect = menuVisible and rectJson(item("create-new-game")) or "null",
      loadGameRect = menuVisible and rectJson(item("load-game")) or "null",
      startGameRect = menuVisible and rectJson(item("start-game-button")) or "null",
      nextGameRect = menuVisible and rectJson(item("next-game-button")) or "null",
      multiplayerRect = menuVisible and rectJson(item("tpf2mp.mainMenuEntry")) or "null",
      expectedSaveRect = menuVisible and rectJson(expectedItem) or "null",
      menuRect = menuVisible and rectJson(menuRoot) or "null",
      -- A hidden pause-menu parent leaves the stock Save button's own
      -- isVisible() flag true. Publish effective ancestor visibility so the
      -- recovery watcher cannot click a stale map-space rectangle.
      inGameSaveVisible = tostring(effectivelyVisible(inGameSave)),
      inGameSaveRect = rectJson(inGameSave),
      inGameUiRect = rectJson(inGameRoot),
      startClicked = tostring(startClicked),
      networkPumpCount = tostring(networkPumpCount),
      networkPumpError = networkPumpError and quote(networkPumpError) or "null",
      networkPumpReadySource = quote(networkPumpReadySource),
      networkPumpReadyValue = quote(networkPumpReadyValue),
      networkPumpNativePresent = tostring(networkPumpNativePresent),
      networkPumpLastAttemptFrame = tostring(networkPumpLastAttemptFrame),
      networkPumpLastSuccessFrame = tostring(networkPumpLastSuccessFrame),
      networkPumpGeneration = quote(networkPumpGeneration),
      networkPumpLastSuccessGeneration = quote(networkPumpLastSuccessGeneration),
      networkPumpDispatchSource = quote(networkPumpDispatchSource),
      networkPumpPausedRequired = tostring(networkPumpPausedRequired),
      networkWakeIssued = tostring(networkWakeIssued),
      error = lastError and quote(lastError) or "null",
    }
    local payload = "{" .. table.concat({
      '"schemaVersion":' .. fields.schemaVersion,
      '"peer":' .. fields.peer,
      '"session":' .. fields.session,
      '"stage":' .. fields.stage,
      '"frames":' .. fields.frames,
      '"menuVisible":' .. fields.menuVisible,
      '"entryInstalled":' .. fields.entryInstalled,
      '"entrySelected":' .. fields.entrySelected,
      '"components":{"createNewGame":' .. fields.createNewGame
        .. ',"loadGame":' .. fields.loadGame
        .. ',"startGame":' .. fields.startGame
        .. ',"nextGame":' .. fields.nextGame
         .. ',"basicSettings":' .. fields.basicSettings
        .. ',"expectedSave":' .. fields.expectedSave
         .. ',"requireMenuEntry":' .. fields.requireMenuEntry
        .. ',"expectedSaveVisible":' .. fields.expectedSaveVisible
        .. ',"saveIndexReady":' .. fields.saveIndexReady
        .. ',"createNewGameRect":' .. fields.createNewGameRect
        .. ',"loadGameRect":' .. fields.loadGameRect
        .. ',"startGameRect":' .. fields.startGameRect
        .. ',"nextGameRect":' .. fields.nextGameRect
         .. ',"multiplayerRect":' .. fields.multiplayerRect
        .. ',"expectedSaveRect":' .. fields.expectedSaveRect
        .. ',"menuRect":' .. fields.menuRect
        .. ',"inGameSaveVisible":' .. fields.inGameSaveVisible
        .. ',"inGameSaveRect":' .. fields.inGameSaveRect
        .. ',"inGameUiRect":' .. fields.inGameUiRect .. '}',
      '"launcherPump":{"startClicked":' .. fields.startClicked
        .. ',"count":' .. fields.networkPumpCount
        .. ',"error":' .. fields.networkPumpError
        .. ',"readySource":' .. fields.networkPumpReadySource
        .. ',"readyValue":' .. fields.networkPumpReadyValue
        .. ',"nativePresent":' .. fields.networkPumpNativePresent
        .. ',"lastAttemptFrame":' .. fields.networkPumpLastAttemptFrame
        .. ',"lastSuccessFrame":' .. fields.networkPumpLastSuccessFrame
        .. ',"generation":' .. fields.networkPumpGeneration
        .. ',"lastSuccessGeneration":' .. fields.networkPumpLastSuccessGeneration
        .. ',"dispatchSource":' .. fields.networkPumpDispatchSource
        .. ',"pausedRequired":' .. fields.networkPumpPausedRequired
        .. ',"networkWakeIssued":' .. fields.networkWakeIssued .. '}',
      '"error":' .. fields.error,
    }, ",") .. "}\n"
    if not force and payload == lastPublished and frames % 120 ~= 0 then return end
    lastPublished = payload
    local target = root .. "/launcher/menu_status.json"
    -- The sandboxed menu Console State exposes io.open but not os.remove or
    -- os.rename. The payload is a single short write; readers already retry
    -- transient JSON parse failures, so overwrite the status file directly.
    local file = io.open(target, "wb")
    if not file then return end
    file:write(payload)
    file:close()
  end

  local function selectMultiplayer()
    -- Window is intentionally unavailable in Build 35924's title-screen
    -- Console State even though Button/TextView are exposed. Make the entry
    -- useful without a popup: it advances into the native save-selection flow
    -- and lets the external launcher/status file present session details.
    loadRequested = true
    entrySelected = true
    stage = "multiplayer-entry-selected"
    lastError = nil
    local receipt = io.open(root .. "/launcher/menu-entry-selected", "wb")
    if receipt then
      receipt:write(tostring(frames) .. "\n")
      receipt:close()
    end
    publish(true)
  end

  -- This console-state bootstrap keeps receiving render updates after the
  -- selected world has loaded, including while that world is paused.  Wake the
  -- game script through its harmless snapshot event once the external
  -- launcher has confirmed that both exact processes crossed the save-loader
  -- boundary.  The game script uses that event to emit/consume ordered network
  -- traffic without requiring a simulation tick.
  local function pumpPausedNetwork()
    -- This Console state renders at uncapped FPS even after world load. All
    -- inputs below are durable files or sticky native state; sampling them once
    -- per wall-clock second preserves pause/recovery responsiveness while
    -- removing hundreds of file opens and JSON scans per second across two
    -- local instances.
    local wallOk, wall = pcall(function() return os.time() end)
    wall = wallOk and tonumber(wall) or nil
    if wall then
      if networkPumpLastWall and wall <= networkPumpLastWall then return end
      networkPumpLastWall = wall
    else
      if frames - networkPumpFallbackFrame < 30 then return end
      networkPumpFallbackFrame = frames
    end
    local requestedGeneration = markerValue(root .. "/launcher/network-pump-generation") or "0"
    local generationChanged = requestedGeneration ~= networkPumpGeneration
    networkPumpGeneration = requestedGeneration
    local nativeReady = rawget(_G, "tpf2mp_native_launcher_bootstrap_ready")
    -- The hook is injected after this Console State is already running. A
    -- single print crosses the pinned luaB_print hook and installs the native
    -- API into this exact Lua global table; without it, registration would be
    -- deferred until unrelated console output happened to occur.
    -- pumpPausedNetwork is wall-clock throttled.  A frame-modulo condition here
    -- can therefore miss forever (for example samples at frames 121, 241, ...),
    -- leaving the long-lived Console state without the native API even though
    -- the hook is active.  Retry once per pump sample until luaB_print installs
    -- the API into this exact global table.
    if type(nativeReady) ~= "function"
      and networkPumpLastRegistrationFrame ~= frames then
      networkPumpLastRegistrationFrame = frames
      print("[TPF2MP] registering native launcher bootstrap API")
      nativeReady = rawget(_G, "tpf2mp_native_launcher_bootstrap_ready")
    end
    networkPumpNativePresent = type(nativeReady) == "function"
    local nativeValue = nil
    if type(nativeReady) == "function" then
      local called, value = pcall(nativeReady)
      nativeValue = called and tostring(value or "") or "error: " .. tostring(value)
    end
    local markerReady = markerValue(root .. "/launcher/manual-bootstrap-ready") == "ready"
    local nativeIsReady = nativeValue == "ready"
    local ready = nativeIsReady or markerReady
    networkPumpReadySource = nativeIsReady and "native" or (markerReady and "marker" or "none")
    networkPumpReadyValue = nativeValue or (markerReady and "ready" or "waiting")
    local companionStatus = markerValue(root .. "/companion_state/companion_status.json") or ""
    local hasPausedPolicy = companionStatus:find('"pausedHeartbeatRequired":', 1, true) ~= nil
    networkPumpPausedRequired = not hasPausedPolicy
      or companionStatus:find('"pausedHeartbeatRequired":true', 1, true) ~= nil
    local prepareReady = markerValue(root .. "/launcher/prepare-restore") == "ready"
    local recoveryPrepareWake = prepareReady and not recoveryPrepareWakeIssued
    if not startClicked or not ready then return end
    -- A finite startup burst leaves a deliberately paused peer stale after
    -- roughly one minute. Keep issuing one cheap launcher pulse per second for
    -- the life of the loaded world; generation/recovery changes use that same
    -- bounded cadence and dispatch immediately when observed.
    networkPumpLastAttemptFrame = frames
    local ok, result = pcall(function()
      if not networkPumpPausedRequired and not recoveryPrepareWake then
        networkPumpDispatchSource = "running-world-noop"
        return true
      end
      local nativePump = rawget(_G, "tpf2mp_native_launcher_pump")
      if type(nativePump) == "function" then
        local called, response = pcall(nativePump)
        if not called or response ~= "A1|script-event" then
          error("native launcher pump failed: " .. tostring(response))
        end
        networkPumpDispatchSource = "native-cross-state-script-event"
        networkWakeIssued = true
        return true
      end
      local make = api and api.cmd and api.cmd.make
      local factory = make and make.sendScriptEvent
      local sender = api and api.cmd and api.cmd.sendCommand
      if type(sender) ~= "function" then
        error("no console-state command dispatch API")
      end
      -- The title-screen Console state survives world load, but Build 35924
      -- removes its sendScriptEvent factory. While the shared clock is paused,
      -- a native-authorized one-tick speed command wakes the real game-script
      -- state; that state pumps signed bridge traffic and reasserts the ordered
      -- pause. While running, ordinary updates are the heartbeat and this path
      -- must not perturb the shared speed.
      if networkPumpPausedRequired then
        local setGameSpeed = make.setGameSpeed
        local authorize = rawget(_G, "tpf2mp_native_authorize_command")
        local revoke = rawget(_G, "tpf2mp_native_revoke_command")
        if type(setGameSpeed) ~= "function" or type(authorize) ~= "function"
          or type(revoke) ~= "function" then
          error("no native-authorized console-state speed wake")
        end
        authorize("0")
        local sent, sendError = pcall(sender, setGameSpeed(1))
        revoke("0")
        if not sent then error(sendError) end
        networkWakeIssued = true
      end
      if type(factory) == "function" then
        local command = factory("tpf2_mp.lua", "tpf2mp", "snapshot.request", {
          launcherReady = true,
          launcherHeartbeat = true,
        })
        sender(command)
        networkPumpDispatchSource = networkPumpPausedRequired and "speed-and-script-event"
          or "script-event"
      else
        networkPumpDispatchSource = networkPumpPausedRequired and "authorized-speed-wake"
          or "running-world-noop"
      end
      return true
    end)
    if ok and result ~= false then
      networkPumpCount = networkPumpCount + 1
      networkPumpLastSuccessFrame = frames
      networkPumpLastSuccessGeneration = networkPumpGeneration
      if prepareReady then recoveryPrepareWakeIssued = true end
      networkPumpError = nil
      if networkPumpCount == 1 or networkPumpReceiptGeneration ~= networkPumpGeneration then
        local receipt = io.open(root .. "/launcher/paused-network-pump", "wb")
        if receipt then
          receipt:write('{"schemaVersion":2,"frame":' .. tostring(frames)
            .. ',"count":' .. tostring(networkPumpCount)
            .. ',"generation":' .. quote(networkPumpGeneration) .. '}\n')
          receipt:close()
          networkPumpReceiptGeneration = networkPumpGeneration
        end
      end
    else
      networkPumpError = tostring(ok and result or result)
    end
  end

  local function installEntry()
    if entryInstalled then return true end
    if item("tpf2mp.mainMenuEntry") then
      entryInstalled = true
      return true
    end
    local layout = item("mainMenuLeftLayout")
    if not layout then
      local anchor = item("create-new-game")
      local rootItem = directItem("menuUI")
      if anchor and rootItem then
        layout = findAddableAncestor(rootItem, anchor, {}, {}, 0, { remaining = 4096 })
      end
    end
    if not layout then
      local anchor = item("create-new-game")
      for _ = 1, 6 do
        local getParent = safeMethod(anchor, "getParent")
        if not getParent then break end
        local parentOk, parent = pcall(getParent, anchor)
        if not parentOk or not parent or parent == anchor then break end
        if safeMethod(parent, "addItem") then layout = parent; break end
        anchor = parent
      end
    end
    local addItem = safeMethod(layout, "addItem")
    if not addItem then return false end
    local button = api.gui.comp.Button.new(api.gui.comp.TextView.new("MULTIPLAYER"), true)
    local setId = safeMethod(button, "setId")
    if setId then
      pcall(setId, button, "tpf2mp.mainMenuEntry")
    end
    button:onClick(selectMultiplayer)
    local ok, err = false, "insert unavailable"
    local loadAnchor = item("load-game")
    local insertItem = safeMethod(layout, "insertItem")
    local getNumItems, getItem = safeMethod(layout, "getNumItems"), safeMethod(layout, "getItem")
    if loadAnchor and insertItem and getNumItems and getItem then
      local countOk, count = pcall(getNumItems, layout)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 255) do
        local childOk, child = pcall(getItem, layout, index)
        if childOk and child == loadAnchor then
          -- The binding is item-first on Build 35924; retain a guarded
          -- index-first fallback for compatible API builds.
          ok, err = pcall(insertItem, layout, button, index + 1)
          if not ok then ok, err = pcall(insertItem, layout, index + 1, button) end
          break
        end
      end
    end
    if not ok then ok, err = pcall(addItem, layout, button) end
    if not ok then
      lastError = "main-menu entry: " .. tostring(err)
      return false
    end
    entryInstalled = true
    return true
  end

  local function advanceLoadFlow()
    if not loadRequested and exists(root .. "/launcher/load-request") then
      loadRequested = true
      stage = "open-free-game"
      publish(true)
    end
    if not loadRequested or startClicked then return end
    -- Button:click() is public but invoking native page transitions from a
    -- title-screen script still reaches Build 35924's generic Internal error
    -- path. Publish live component rectangles instead; the launcher sends one
    -- ordinary physical click to the exact process/window, identical to a
    -- human click and independent of resolution/window placement.
    local nextStage
    if clickable("start-game-button") then
      if normalized(expectedSave) ~= "" and not exists(root .. "/launcher/save-selected") then
        if not saveIndexReady() then
          nextStage = "waiting-for-save-index"
        elseif expectedSaveItem() then
          nextStage = "ready-to-click-pinned-save"
        else
          nextStage = "waiting-for-pinned-save"
        end
      elseif normalized(expectedSave) ~= "" and not saveIndexReady() then
        nextStage = "waiting-for-selected-save-metadata"
      else
        nextStage = "ready-to-click-start-selected-save"
      end
    elseif clickable("load-game") then
      nextStage = "ready-to-click-load-game"
    elseif clickable("create-new-game") then
      nextStage = "ready-to-click-free-game"
    else
      nextStage = "await-native-load-controls"
    end
    if exists(root .. "/launcher/start-clicked") then
      startClicked = true
      nextStage = "starting-selected-save"
    end
    local changed = stage ~= nextStage
    stage = nextStage
    lastError = nil
    publish(changed)
  end

  return {
    update = function()
      frames = frames + 1
      -- Console-state updates continue while the simulation clock is stopped.
      -- Pump before the slower menu-discovery cadence so a low render rate
      -- cannot age an otherwise healthy peer beyond the host deadline.
      -- The native page can disappear before the next 30-frame discovery pass
      -- after the launcher clicks Start. Re-read the pre-transition receipt on
      -- every Console-state update so the durable paused-world pump cannot be
      -- disabled by that one-frame race.
      if not startClicked and exists(root .. "/launcher/start-clicked") then
        startClicked = true
      end
      if startClicked then pumpPausedNetwork() end
      if frames % 30 ~= 0 then return end
      local menuVisible = visible(item("menuUI"))
      if menuVisible then
        if not treeDumped and item("create-new-game") then
          treeDumped = true
          pcall(dumpMenuTree, "menu_tree.txt")
        end
        if treeDumped and not newGameTreeDumped and normalized(expectedSave) == ""
          and not item("create-new-game") then
          newGameTreeDumped = true
          pcall(dumpMenuTree, "new_game_tree.txt")
        end
        if not loadTreeDumped and item("start-game-button") then
          loadTreeDumped = true
          pcall(dumpMenuTree, "load_menu_tree.txt")
        end
        if not loadRequested then pcall(installEntry) end
        advanceLoadFlow()
      elseif startClicked then
        stage = "world-transition"
      end
      if not menuVisible and startClicked then
        local wallOk, wall = pcall(function() return os.time() end)
        wall = wallOk and tonumber(wall) or nil
        if wall then
          if lastWorldStatusWall and wall <= lastWorldStatusWall then return end
          lastWorldStatusWall = wall
        else
          if frames - lastWorldStatusFrame < 60 then return end
          lastWorldStatusFrame = frames
        end
      end
      publish(false, menuVisible)
    end,
    handleEvent = function(id, name, param)
      -- Kept for Console-state lifecycle compatibility.
    end,
  }
end
