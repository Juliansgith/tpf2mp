# TPF2MP 0.41.3-alpha

This release fixes a paired native crash when a populated or previously used
save is hosted as a new multiplayer session. State schema 33, checkpoint format
5, operation format 4, economy model 10, and native hook 0.19.0 are unchanged.

## Populated-save initialization

- Network initialization no longer mutates a native wallet and then reads its
  PLAYER entity again inside the same ordered commit. Authoritative starting
  accounts are staged first; native wallet presentation is reconciled after
  the initial checkpoint, one company and one journal command per update.
- The pre-existing-world manifest and structural snapshot no longer call the
  broad `game.interface.getEntity` projection. Build 35924 could access-violate
  while materialising a loaded station with a null optional native string, and
  Lua `pcall` cannot contain that engine fault.
- Loaded towns, industries, station groups, stations, depots, lines, vehicles,
  edge objects, assets, constructions, and private topology now use a narrow,
  component-only identity reader during the authority boundary.
- Initialization emits bounded stage evidence so any future native failure can
  be placed before or after company binding, finance staging, manifesting,
  vehicle-cost backfill, and the structural snapshot.

## Verification

- A regression makes every broad loaded-station projection fatal and proves
  both manifesting and structural snapshots remain component-only.
- Wallet tests prove there is no same-update post-journal PLAYER read and at
  most one native wallet correction is issued per update.
- The original 53.8 MB failure save was loaded into two separate hooked game
  processes. Both completed a 60,502-entity manifest, a 425-object structural
  snapshot, match initialization, shared-clock coordination, and checkpoint
  consensus without reproducing the crash.
- The complete automated suite passes 142 Lua checks plus network, hot-seat,
  replay, cross-language parity, launcher/updater, relay, recovery, packaging,
  syntax, and architecture-boundary gates.

Both players must install `0.41.3-alpha`. Mixed versions remain unsupported;
stop active games and multiplayer helpers before updating.
