# TPF2MP 0.41.1-alpha

This hotfix completes the signal/waypoint correlation repair from 0.41.0.
State remains schema 32, checkpoint format 5, operation format 4, economy
model 10, and native hook 0.19.0.

## Signal and waypoint capture

- Build 35924's stock `streetTerminalBuilder` can project an edge-object-only
  ghost but expose the clicked carrier-edge rewrite as `mixed-transport`.
  `0.41.0-alpha` admitted only the first shape and still rejected live signals.
- The exception is now exact to that stock source ID and admits construction,
  edge-object, or mixed-transport shapes. Other terminal, station, depot,
  construction, and asset builders remain construction-only.
- The regression now models the captured mixed topology and requires that the
  real GUI path leaves a nonzero native correlation token. The previous weak
  nil-return assertion would not detect a visible stale-preview rejection.

Both players must install `0.41.1-alpha` and create a fresh session. Running
games cannot hot-load this Lua change, and mixed versions remain unsupported.
