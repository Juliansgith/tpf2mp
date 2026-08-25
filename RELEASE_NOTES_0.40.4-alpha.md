# TPF2MP 0.40.4-alpha

This hotfix prevents replicated rail depots from crashing Transport Fever 2's
stock depot UI when selected. It remains compatible with state schema 31 and
does not change the network, checkpoint, proposal, operation, passenger,
cargo, freight, or native-hook protocols.

## Depot selection correction

- Fresh rail depots no longer use the typed `ConstructionEntity` replay path.
- Depots use the established `game.interface.buildConstruction` helper, which
  has prior human proof for opening, using, ownership enforcement, and removal.
- The canonical resource, parameters, transform, generated graph, ownership,
  finance, physical consensus, and checkpoint consensus remain authoritative.
- Stations and ordinary constructions retain their faster typed replay path.

Relay support session `mp-dda56d8502e0fc3c` supplied the decisive evidence.
The same replicated depot rendered and passed consensus on both machines, but
selecting it terminated each game independently in stock `contexthelper.lua`
with `mainView/select`. Player 2 reproduced the crash more than 200 mod ticks
after its replay completed, ruling out relay transport and a transient replay
race.

## Regression coverage

- Runtime coverage prevents every `kind="depot"` build from re-entering typed
  exact replay.
- Network company-mapping integration builds the depot through the helper and
  verifies its construction, depot, nodes, edge, ownership, finance, physical
  result, and checkpoint result.
- The complete deterministic Lua/model suite, 1,024-event replay, transport
  and cross-language parity checks pass.
- All 168 packaged Lua files and 72 PowerShell files pass syntax validation.
- All 197 Python tests pass.
- Updater integrity, transactional installation, rollback, launcher, relay,
  save-sync, recovery, and restore tests pass.

## Compatibility note

Do not reuse an alpha world that already contains a depot created by
`0.38.3-alpha` through `0.40.3-alpha` typed replay: that native depot remains
unsafe to select and cannot be repaired reliably in place. Start a fresh match
and build a new depot after both players install `0.40.4-alpha`.

Both players must install `0.40.4-alpha` before creating the fresh match.
