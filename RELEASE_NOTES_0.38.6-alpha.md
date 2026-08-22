# TPF2MP 0.38.6-alpha

This follow-up fixes connected station placement and prevents suppressed
construction clicks from appearing later as unexpected queued work.

## Connected stations

- The companion now accepts the same canonical existing-track boundary
  endpoints as the Lua station codec.
- The proof still requires one open, non-branching path per selected platform
  track and requires every existing boundary node to be a degree-one endpoint.
- New cross-language regressions cover the exact live attached-station shape,
  boundary reuse, and invalid canonical identities.

## Construction input

- Station/depot/asset placement, edits, and bulldozing are single-flight while
  another multiplayer physical or checkpoint barrier is active.
- The stock builder displays why it is temporarily locked and explicitly says
  the input was not queued.
- An engine-side backstop rejects any construction capture that races the GUI
  snapshot, so old clicks cannot materialize later.
- Road, track, signal, and waypoint inputs keep their bounded ordered FIFO.

## Verification

The complete source-boundary, Lua, Python, cross-language parity, game-script,
two-company mapping, GUI, native-profile, packaging/updater, launcher, recovery,
and long-replay suite passes: 137 Lua model checks, 7 transport-network checks,
3 alpha-readiness checks, and 181 companion checks plus all integration gates.

## Updating

Close every Transport Fever 2 instance, then use **CHECK / INSTALL UPDATE** in
the multiplayer launcher or run `%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd`.
Start a fresh session; already queued construction input in an older running
process cannot be removed by updating files on disk.
