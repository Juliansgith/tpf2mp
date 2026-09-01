# TPF2MP 0.38.5-alpha

This follow-up prevents a successful automatic multiplayer bootstrap from
being faulted by a second **Initialise Match** action.

## Match bootstrap hardening

- Launcher-managed network matches now have one initializer: the automatic
  host bootstrap after both peers and native authority gates are ready.
- The multiplayer panel no longer exposes **Initialise Match** in that mode.
- A stale local duplicate is acknowledged without entering host ordering.
- A duplicate already ordered by an older client is a deterministic audited
  no-op on both peers and does not open a redundant checkpoint barrier.
- The panel separates match state (`waiting for peer`, `starting
  automatically`, or `ready`) from canonical company assignment.

## Verification

- The exact live sequence—successful initialization followed by a second
  panel action—has a game-script regression.
- A compatibility regression injects an ordered duplicate and proves success,
  no session fault, and no extra checkpoint.
- The full Lua, Python, PowerShell, replay, parity, freight-stress,
  release-install, and recovery suite passes.

## Updating

Close every Transport Fever 2 instance, then use **CHECK / INSTALL UPDATE** in
the multiplayer launcher or run `%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd`.
Start a fresh session; an already-faulted `0.38.4-alpha` match cannot be
repaired in place.
