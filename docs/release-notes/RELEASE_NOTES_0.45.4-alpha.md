# TPF2MP 0.45.4-alpha

A visual refresh of every TPF2MP surface: the launcher, the world lobby and
the in-game multiplayer window. No protocol, schema or native hook change.
This remains an experimental two-player testing release.

## Changes

- The launcher and the world lobby share one WinForms look through
  `tools\launcher_theme.ps1`: a dark palette with a single teal accent, one
  type scale, cards with hairline borders and uppercase headings, one primary
  action per window, ghost buttons for secondary tools, status pills, flat
  tabs and framed inputs. The theme ships inside the release bundle.
- Launcher: rebuilt as four cards (Connection, Session, Launch, Recovery and
  tools) with labels above inputs and sentence-case captions. Every control,
  handler, worker command and log line is unchanged, so scripted and manual
  flows behave exactly as in 0.45.3. The window fits a 1080p display at 100%
  scaling and no longer relies on font auto-scaling.
- World lobby: notice bar with an accent edge, a three-column settings grid,
  a nested Terrain card with flat sliders, dark owner-drawn combo boxes and
  spinners, a dark mods list, and peer state pills. The stray non-ASCII
  separators that rendered as mojibake are gone.
- In-game window: tinted status badges (mode, peer, link, match, company and
  proxy), a two-line muted summary, uppercase section captions above each
  button group, sentence-case buttons with a visible surface and hover state,
  button rows wrapped at five so the window keeps a readable width, and the
  session details on their own quiet surface. Styling lives in the mod's
  style sheet and `res/scripts/tpf2_mp/gui_window_chrome.lua`; the game
  script only registers that module.
- Fixed in the theme while restyling: a pill paint handler that threw on
  construction, enable/disable handlers that stacked on every state change,
  and pill captions drawn twice.
- The localhost live-validation harness now quotes the companion's manifest
  path, so it works from a checkout whose path contains spaces.

## Verification and limits

- Full automated gate passed (core Lua suites, Python suites and the
  1,024-event cross-language replay), plus the documentation and
  source-boundary checks, the launcher smoke test and the lobby dialog tests.
- Three two-instance localhost live runs converged with the restyled window
  on both peers; the game log shows no style-sheet or GUI script errors.
- The in-game window is tall. On a 1080p display its lowest section can sit
  under the bottom toolbar depending on where the game opens the window;
  drag it up. Everything else in the window is reachable.
- No new live two-player construction or transport qualification accompanies
  this patch. Earlier coverage gaps, the intermittent native Load Game stall
  and the lobby's two-computer path remain as in the
  [0.45.3 notes](RELEASE_NOTES_0.45.3-alpha.md).

## Update

Back up your saves, close active sessions and update both players to
**0.45.4-alpha** before starting a new session. Windows x64, Build 35924 and two
trusted players remain required. Protocol/state schema versions are unchanged.
Report bugs in #bugs-logs with the session support ID and what you were doing.
