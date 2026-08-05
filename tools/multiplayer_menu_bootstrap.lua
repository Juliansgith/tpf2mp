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
  local peer = os.getenv("TPF2MP_PEER_ID") or "unknown"
  local session = os.getenv("TPF2MP_SESSION_ID") or "unknown"
  local expectedSave = tostring(os.getenv("TPF2MP_STAGED_SAVE_NAME") or "")
  local requireMenuEntry = tostring(os.getenv("TPF2MP_REQUIRE_MENU_ENTRY") or "") == "1"
  local root = (os.getenv("TPF2MP_BRIDGE_DIR") or "."):gsub("\\", "/"):gsub("/+$", "")
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
  local loadTreeDumped = false
  local networkPumpCount = 0
  local networkPumpError = nil
  local networkWakeIssued = false
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

  local function safeId(value)
    if not value or type(value.getId) ~= "function" then return "" end
    local ok, result = pcall(value.getId, value)
    return ok and tostring(result or "") or ""
  end

  local function childLayout(value)
    if not value or type(value.getLayout) ~= "function" then return nil end
    local ok, result = pcall(value.getLayout, value)
    return ok and result or nil
  end

  local function childContent(value)
    if not value or type(value.getContent) ~= "function" then return nil end
    local ok, result = pcall(value.getContent, value)
    return ok and result or nil
  end

  local function safeStringCall(value, method)
    if not value or type(value[method]) ~= "function" then return "" end
    local ok, result = pcall(value[method], value)
    return ok and tostring(result or "") or ""
  end

  local function normalized(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  end

  local function subtreeHasText(value, wanted, seen, depth, budget)
    if not value or seen[value] or depth > 12 or budget.remaining <= 0 then return false end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if normalized(safeStringCall(value, "getText")) == wanted then return true end
    local content = childContent(value)
    if content and content ~= value
      and subtreeHasText(content, wanted, seen, depth + 1, budget) then return true end
    local nested = childLayout(value)
    if nested and nested ~= value
      and subtreeHasText(nested, wanted, seen, depth + 1, budget) then return true end
    if type(value.getNumItems) == "function" and type(value.getItem) == "function" then
      local countOk, count = pcall(value.getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 255) do
        local childOk, child = pcall(value.getItem, value, index)
        if childOk and child
          and subtreeHasText(child, wanted, seen, depth + 1, budget) then return true end
      end
    end
    return false
  end

  local function findClickableByText(value, wanted, seen, depth, budget)
    if not value or seen[value] or depth > 16 or budget.remaining <= 0 then return nil end
    seen[value] = true
    budget.remaining = budget.remaining - 1
    if type(value.click) == "function"
      and subtreeHasText(value, wanted, {}, 0, { remaining = 512 }) then return value end
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
    if type(value.getNumItems) == "function" and type(value.getItem) == "function" then
      local countOk, count = pcall(value.getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(value.getItem, value, index)
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
    if type(value.getNumItems) == "function" and type(value.getItem) == "function" then
      local countOk, count = pcall(value.getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(value.getItem, value, index)
        if childOk and child then
          local found = findExactTextItem(child, wanted, seen, depth + 1, budget)
          if found then return found end
        end
      end
    end
    return nil
  end

  local function findInTree(value, wanted, seen, depth, budget)
    if not value or budget.remaining <= 0 or depth > 16 then return nil end
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
    if type(value.getNumItems) == "function" and type(value.getItem) == "function" then
      local countOk, count = pcall(value.getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(value.getItem, value, index)
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
        if type(ancestors[index].addItem) == "function" then return ancestors[index] end
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
    if type(value.getNumItems) == "function" and type(value.getItem) == "function" then
      local countOk, count = pcall(value.getNumItems, value)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 511) do
        local childOk, child = pcall(value.getItem, value, index)
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
    local found = findInTree(rootItem, id, {}, 0, { remaining = 2048 })
    if not found then
      local labels = {
        ["create-new-game"] = "free game",
        ["load-game"] = "load game",
        ["start-game-button"] = "start",
        ["tpf2mp.mainMenuEntry"] = "multiplayer",
      }
      if labels[id] then
        found = findClickableByText(rootItem, labels[id], {}, 0, { remaining = 2048 })
      end
    end
    return found
  end

  local function dumpMenuTree(fileName)
    local file = io.open(root .. "/launcher/" .. fileName, "wb")
    if not file then return end
    local seen, budget = {}, { remaining = 4096 }
    local function visit(value, path, depth)
      if not value or seen[value] or budget.remaining <= 0 or depth > 20 then return end
      seen[value] = true
      budget.remaining = budget.remaining - 1
      local id = safeId(value)
      local name = safeStringCall(value, "getName")
      local text = safeStringCall(value, "getText")
      file:write(path .. "\t" .. id .. "\t" .. name .. "\t" .. text
        .. "\tclick=" .. tostring(type(value.click) == "function")
        .. "\t" .. tostring(value) .. "\n")
      local nested = childLayout(value)
      if nested and nested ~= value then visit(nested, path .. ".layout", depth + 1) end
      local content = childContent(value)
      if content and content ~= value then visit(content, path .. ".content", depth + 1) end
      if type(value.getNumItems) == "function" and type(value.getItem) == "function" then
        local countOk, count = pcall(value.getNumItems, value)
        count = countOk and tonumber(count) or 0
        for index = 0, math.min(count - 1, 511) do
          local childOk, child = pcall(value.getItem, value, index)
          if childOk and child then visit(child, path .. "[" .. index .. "]", depth + 1) end
        end
      end
    end
    visit(directItem("menuUI"), "menuUI", 0)
    file:close()
  end

  local function visible(value)
    if not value or type(value.isVisible) ~= "function" then return false end
    local ok, result = pcall(value.isVisible, value)
    return ok and result == true
  end

  local function rectJson(value)
    if not value or type(value.getContentRect) ~= "function" then return "null" end
    local ok, rect = pcall(value.getContentRect, value)
    if not ok or not rect then return "null" end
    local fields = {}
    for _, key in ipairs({ "x", "y", "w", "h" }) do
      local readOk, number = pcall(function() return tonumber(rect[key]) end)
      if not readOk or number == nil then return "null" end
      fields[#fields + 1] = '"' .. key .. '":' .. tostring(math.floor(number + 0.5))
    end
    return "{" .. table.concat(fields, ",") .. "}"
  end

  local function clickable(id)
    local value = item(id)
    return value ~= nil and type(value.click) == "function"
  end

  local function expectedSaveItem()
    local wanted = normalized(expectedSave)
    if wanted == "" then return nil end
    local rootItem = directItem("menuUI")
    if not rootItem then return nil end
    return findExactTextItem(rootItem, wanted, {}, 0, { remaining = 4096 })
  end

  publish = function(force)
    local fields = {
      schemaVersion = "2",
      peer = quote(peer),
      session = quote(session),
      stage = quote(stage),
      frames = tostring(frames),
      menuVisible = tostring(visible(item("menuUI"))),
      entryInstalled = tostring(entryInstalled),
      entrySelected = tostring(entrySelected),
      createNewGame = tostring(clickable("create-new-game")),
      loadGame = tostring(clickable("load-game")),
      startGame = tostring(clickable("start-game-button")),
      basicSettings = tostring(item("mainMenu.loadGame.basicSettings") ~= nil),
      expectedSave = quote(expectedSave),
      requireMenuEntry = tostring(requireMenuEntry),
      expectedSaveVisible = tostring(expectedSaveItem() ~= nil),
      createNewGameRect = rectJson(item("create-new-game")),
      loadGameRect = rectJson(item("load-game")),
      startGameRect = rectJson(item("start-game-button")),
      multiplayerRect = rectJson(item("tpf2mp.mainMenuEntry")),
      expectedSaveRect = rectJson(expectedSaveItem()),
      menuRect = rectJson(directItem("menuUI")),
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
         .. ',"basicSettings":' .. fields.basicSettings
         .. ',"expectedSave":' .. fields.expectedSave
         .. ',"requireMenuEntry":' .. fields.requireMenuEntry
        .. ',"expectedSaveVisible":' .. fields.expectedSaveVisible
        .. ',"createNewGameRect":' .. fields.createNewGameRect
        .. ',"loadGameRect":' .. fields.loadGameRect
        .. ',"startGameRect":' .. fields.startGameRect
         .. ',"multiplayerRect":' .. fields.multiplayerRect
        .. ',"expectedSaveRect":' .. fields.expectedSaveRect
        .. ',"menuRect":' .. fields.menuRect .. '}',
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
    local nativeReady = rawget(_G, "tpf2mp_native_launcher_bootstrap_ready")
    -- The hook is injected after this Console State is already running. A
    -- single print crosses the pinned luaB_print hook and installs the native
    -- API into this exact Lua global table; without it, registration would be
    -- deferred until unrelated console output happened to occur.
    if type(nativeReady) ~= "function" and frames % 120 == 0 then
      print("[TPF2MP] registering native launcher bootstrap API")
      nativeReady = rawget(_G, "tpf2mp_native_launcher_bootstrap_ready")
    end
    local ready = false
    if type(nativeReady) == "function" then
      local called, value = pcall(nativeReady)
      ready = called and value == "ready"
    else
      ready = markerValue(root .. "/launcher/manual-bootstrap-ready") == "ready"
    end
    if not startClicked or not ready or networkPumpCount >= 30 then return end
    if frames % 120 ~= 0 then return end
    local ok, result = pcall(function()
      local make = api and api.cmd and api.cmd.make
      local factory = make and make.sendScriptEvent
      if type(factory) ~= "function" or not (api.cmd and type(api.cmd.sendCommand) == "function") then
        error("no console-state script-event dispatch API")
      end
      if not networkWakeIssued then
        local setGameSpeed = make.setGameSpeed
        local authorize = rawget(_G, "tpf2mp_native_authorize_command")
        if type(setGameSpeed) ~= "function" or type(authorize) ~= "function" then
          error("no native-authorized console-state speed wake")
        end
        authorize("0")
        api.cmd.sendCommand(setGameSpeed(1))
        networkWakeIssued = true
      end
      local command = factory("tpf2_mp.lua", "tpf2mp", "snapshot.request", {
        launcherReady = true,
      })
      api.cmd.sendCommand(command)
      return true
    end)
    if ok and result ~= false then
      networkPumpCount = networkPumpCount + 1
      networkPumpError = nil
      if networkPumpCount == 1 then
        local receipt = io.open(root .. "/launcher/paused-network-pump", "wb")
        if receipt then
          receipt:write(tostring(frames) .. "\n")
          receipt:close()
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
        if not anchor or type(anchor.getParent) ~= "function" then break end
        local parentOk, parent = pcall(anchor.getParent, anchor)
        if not parentOk or not parent or parent == anchor then break end
        if type(parent.addItem) == "function" then layout = parent; break end
        anchor = parent
      end
    end
    if not layout or type(layout.addItem) ~= "function" then return false end
    local button = api.gui.comp.Button.new(api.gui.comp.TextView.new("MULTIPLAYER"), true)
    if type(button.setId) == "function" then
      pcall(button.setId, button, "tpf2mp.mainMenuEntry")
    end
    button:onClick(selectMultiplayer)
    local ok, err = false, "insert unavailable"
    local loadAnchor = item("load-game")
    if loadAnchor and type(layout.insertItem) == "function"
      and type(layout.getNumItems) == "function" and type(layout.getItem) == "function" then
      local countOk, count = pcall(layout.getNumItems, layout)
      count = countOk and tonumber(count) or 0
      for index = 0, math.min(count - 1, 255) do
        local childOk, child = pcall(layout.getItem, layout, index)
        if childOk and child == loadAnchor then
          -- The binding is item-first on Build 35924; retain a guarded
          -- index-first fallback for compatible API builds.
          ok, err = pcall(layout.insertItem, layout, button, index + 1)
          if not ok then ok, err = pcall(layout.insertItem, layout, index + 1, button) end
          break
        end
      end
    end
    if not ok then ok, err = pcall(layout.addItem, layout, button) end
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
        if expectedSaveItem() then
          nextStage = "ready-to-click-pinned-save"
        else
          nextStage = "waiting-for-pinned-save"
        end
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
      if frames % 30 ~= 0 then return end
      if visible(item("menuUI")) then
        if not treeDumped and item("create-new-game") then
          treeDumped = true
          pcall(dumpMenuTree, "menu_tree.txt")
        end
        if not loadTreeDumped and item("start-game-button") then
          loadTreeDumped = true
          pcall(dumpMenuTree, "load_menu_tree.txt")
        end
        if not loadRequested then pcall(installEntry) end
        advanceLoadFlow()
      elseif startClicked then
        stage = "world-transition"
        pumpPausedNetwork()
      end
      publish(false)
    end,
    handleEvent = function(id, name, param)
      -- Kept for Console-state lifecycle compatibility.
    end,
  }
end
