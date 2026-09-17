-- Social channel inside the game GUI state: chat, pings and build previews.
-- See docs/SOCIAL_CHANNEL.md. Registers itself as guiView.social so the game
-- script needs no new local (Lua 5.1 caps a chunk at 200 locals).
local guiView = require "tpf2_mp/gui_view"

local M = {}

-- Called from guiHandleEvent after the existing handlers; must never return
-- a value (a returned table would alter the builder's own validation).
function M.observeBuilderEvent(gui, id, name, param) end

-- Called every GUI frame; throttles itself to five hertz internally.
function M.tick(gui) end

-- Adds the chat and ping controls to the panel.
function M.addSection(gui, rootLayout, chrome) end

guiView.social = M
return M
