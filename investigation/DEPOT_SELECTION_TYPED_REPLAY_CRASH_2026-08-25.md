# Typed depot replay selection crash — 2026-08-25

## Outcome

Relay session `mp-dda56d8502e0fc3c` established that a stock rail depot created
through the typed schema-7 `BuildProposal` path is not safe to expose to the
stock depot UI on Transport Fever 2 Build 35924. The depot rendered, its
construction/depot/node/edge outputs passed physical consensus, and later track
connections also converged. Selecting that same depot then terminated both game
processes independently in stock `contexthelper.lua`.

This was not caused by relay transport. The relay remained paired while both
worlds accepted the same ordered construction and topology actions. Player 2
crashed more than 200 mod ticks after its final track replay had completed, so
a transient replay race cannot explain both failures.

## Evidence

The depot was ordered as proposal
`mp-dda56d8502e0fc3c:player1:30`, digest `285b4b9d`:

- resource: `depot/train_depot_era_a.con`;
- one construction and one `VEHICLE_DEPOT` output;
- two nodes and one generated catenary track edge;
- replay result: success on both peers, finance delta `-24779`;
- replay metadata: exact/typed construction (`nativeReadUnsafe=true`).

Track proposals `:34` and `:38` subsequently connected the depot graph and
completed on player 2. Player 1 selected the depot while the final proposal was
crossing physical consensus and produced minidump
`a4c55930-5262-4b76-9996-4c064ae02f61`. Player 2 later selected the already
settled depot and produced minidump
`8555a442-9595-473d-a59d-946ac7dfceae`.

Both native traces identify the same stock handler:

```text
contexthelper.lua - game/res/gameScript/contexthelper.lua_guiHandleEvent()
hints: id = "mainView", name = "select"
```

The second crash is the decisive observation: player 2's depot and connections
had long since finalized, yet selecting it failed identically. A GUI replay
quarantine would only mask the first timing and would leave the persistent
crash on the peer.

## Correction

Fresh depots no longer qualify for typed exact construction replay. They use
the established `game.interface.buildConstruction` helper path, which has
prior human proof for building, opening, using, ownership enforcement, and
removal. The helper still uses the canonical resource name, parameters, and
absolute transform; it still verifies the complete generated component delta,
matches the node/edge graph geometrically, binds stable identities, settles the
quoted finance delta, and crosses ordinary physical/checkpoint consensus.

Stations and ordinary constructions remain on the faster typed path. Only the
depot kind is narrowed because that is the unsupported native boundary the two
crashes proved.

Existing worlds containing a typed-replay depot are not repaired in place.
That native object remains unsafe to select; the live acceptance run must use a
fresh session and a newly built depot.

## Automated regression boundary

- `construction_replay_state.isExact` rejects every fresh `kind="depot"`
  transaction.
- Runtime-module coverage pins that classification alongside the existing
  upgrade, removal, and collateral exclusions.
- Network company-mapping integration now exercises depot construction directly
  through the helper path and still verifies all five canonical outputs,
  ownership, finance, proposal consensus, and checkpoint consensus.

## Fresh live acceptance

In a new two-peer session:

1. build one stock rail depot and wait for the checkpoint to settle;
2. open and close it on its owner's peer before connecting track;
3. connect it to the network, wait for the next checkpoint, and open it again;
4. confirm the rival peer is denied operational access without a native crash;
5. buy one train and confirm it appears in both worlds.

The old relay session must not be reused for this acceptance because it already
contains the unsafe typed depot.
