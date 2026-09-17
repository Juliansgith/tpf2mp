local ssu = require "stylesheetutil"

-- TPF2MP in-game styling. Style classes are set from Lua with
-- setStyleClassList and addressed here with the game's "!class" selector.
-- One restrained palette: a dark translucent panel, teal for live/positive
-- state, amber for attention, muted grey for everything secondary.

function data()
  local result = {}
  local add = ssu.makeAdder(result)

  local muted = ssu.makeColor(152, 166, 178)
  local body = ssu.makeColor(214, 222, 228)

  -- Authoritative company/vehicle/line/station panels injected into stock windows.
  add("TPF2MPAuthoritativePanel", {
    backgroundColor = ssu.makeColor(14, 40, 48, 235),
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

  -- The multiplayer window.
  add("!tpf2mp-root", {
    padding = { 6, 8, 8, 8 },
  })
  add("!tpf2mp-root BoxLayout", {
    innerSpacing = { 4, 4 },
  })
  -- Header: one status badge per fact, tinted by state.
  add("!tpf2mp-header", {
    padding = { 2, 4, 2, 4 },
  })
  add("!tpf2mp-badge", {
    fontSize = 12,
    padding = { 3, 10, 3, 10 },
    margin = { 0, 3, 0, 3 },
    backgroundColor = ssu.makeColor(255, 255, 255, 18),
    color = body,
  })
  add("!tpf2mp-badge-ok", {
    backgroundColor = ssu.makeColor(52, 190, 130, 70),
    color = ssu.makeColor(160, 240, 195),
  })
  add("!tpf2mp-badge-warn", {
    backgroundColor = ssu.makeColor(235, 181, 71, 70),
    color = ssu.makeColor(252, 222, 150),
  })
  add("!tpf2mp-badge-info", {
    backgroundColor = ssu.makeColor(45, 190, 168, 70),
    color = ssu.makeColor(160, 236, 222),
  })
  add("!tpf2mp-badge-muted", {
    backgroundColor = ssu.makeColor(255, 255, 255, 14),
    color = muted,
  })
  -- The one-line summary that carries every fact in plain text.
  add("!tpf2mp-summary", {
    fontSize = 11,
    color = muted,
    padding = { 2, 10, 6, 10 },
  })
  -- Uppercase section captions above each button row.
  add("!tpf2mp-section", {
    fontSize = 11,
    textTransform = "UPPERCASE",
    color = muted,
    padding = { 6, 10, 1, 10 },
  })
  add("!tpf2mp-note", {
    fontSize = 12,
    color = muted,
    padding = { 2, 10, 2, 10 },
  })
  -- Sentence-case, compact buttons inside the window only.
  add("!tpf2mp-root Button::Text", {
    fontSize = 12,
    textTransform = "NONE",
    padding = { 4, 12, 4, 12 },
  })
  add("!tpf2mp-root Button", {
    margin = { 2, 2, 2, 2 },
    backgroundColor = ssu.makeColor(255, 255, 255, 22),
  })
  add("!tpf2mp-root Button:hover", {
    backgroundColor = ssu.makeColor(45, 190, 168, 90),
  })
  add("!tpf2mp-root Button:active", {
    backgroundColor = ssu.makeColor(45, 190, 168, 140),
  })
  -- The social channel: chat lines and pings from the other player. Quiet
  -- surface, same measure as the details block, so it reads as a transcript
  -- rather than as authoritative match state.
  add("!tpf2mp-chat", {
    fontSize = 12,
    color = body,
    padding = { 8, 10, 8, 10 },
    margin = { 4, 4, 2, 4 },
    backgroundColor = ssu.makeColor(0, 0, 0, 70),
  })
  -- The stock TextInputField has no minimum width, so an empty chat field
  -- would collapse to a sliver next to the Send button.
  add("!tpf2mp-chat-input", {
    fontSize = 12,
    minSize = { 260, -1 },
    margin = { 2, 2, 2, 4 },
  })
  -- The details block: secondary text on its own quiet surface.
  add("!tpf2mp-details", {
    fontSize = 12,
    color = body,
    padding = { 8, 10, 8, 10 },
    margin = { 4, 4, 4, 4 },
    backgroundColor = ssu.makeColor(0, 0, 0, 70),
  })
  -- The next-action line: the one sentence that says what to do now, so it
  -- reads as an instruction rather than as one more diagnostic.
  add("!tpf2mp-next", {
    fontSize = 13,
    color = body,
    padding = { 4, 10, 4, 10 },
    margin = { 2, 4, 2, 4 },
    backgroundColor = ssu.makeColor(45, 190, 168, 38),
  })
  -- Section captions are clickable headers; the marker plus the caption stays
  -- uppercase even though the Lua caption is written in sentence case.
  add("!tpf2mp-section-header", {
    backgroundColor = ssu.makeColor(255, 255, 255, 10),
    margin = { 4, 0, 1, 0 },
    padding = { 0, 0, 0, 0 },
  })
  add("!tpf2mp-section-header::Text", {
    fontSize = 11,
    textTransform = "UPPERCASE",
    color = muted,
    padding = { 4, 10, 4, 10 },
  })
  add("!tpf2mp-root !tpf2mp-section-header::Text", {
    fontSize = 11,
    textTransform = "UPPERCASE",
    color = muted,
    padding = { 4, 10, 4, 10 },
  })
  add("!tpf2mp-compact::Text", {
    fontSize = 11,
    textTransform = "NONE",
    color = muted,
    padding = { 3, 10, 3, 10 },
  })
  -- Notices: the rejection feed, and the floating toast that carries the
  -- newest one where a player is actually looking.
  add("!tpf2mp-notices", {
    fontSize = 12,
    color = body,
    padding = { 4, 10, 6, 10 },
    backgroundColor = ssu.makeColor(0, 0, 0, 55),
  })
  add("!tpf2mp-toast", {
    padding = { 6, 12, 6, 12 },
    backgroundColor = ssu.makeColor(14, 40, 48, 235),
  })
  add("!tpf2mp-toast-text", {
    fontSize = 13,
    color = ssu.makeColor(252, 222, 150),
  })
  add("!tpf2mp-scoreboard", {
    fontSize = 12,
    color = body,
    padding = { 4, 10, 6, 10 },
    backgroundColor = ssu.makeColor(0, 0, 0, 55),
  })

  return result
end
