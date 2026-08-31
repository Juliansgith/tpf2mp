# Construction owner-plan regression

Date: 2026-08-31 (Europe/Amsterdam)

Status: fixed in source and fully regression-tested. A packaged two-peer click
remains the native acceptance gate.

## Reported evidence

Relay session `mp-4eda75851212bd35` remained connected and synchronized while
two placements of `station/street/modular_terminal.con` were identically
rejected. Player 2's game log recorded:

`captured construction edge has an unexpected native owner`

Both attempts completed recoverable rejection checkpoints, the second at
ordered sequence 14. Core digest `73b27d9d` and structural digest `dc3ae927`
remained unchanged. The relay, finance path, terrain, and collision handling
were not involved.

## Root cause

The ownership correction added for 0.42.2 correctly distinguished the local
command issuer from the peer-local native representative of the canonical
company. It incorrectly retained the typed `PlayerOwned` component as the
authority source after `api.cmd.make.buildProposal` expanded the construction.

Build 35924 may mutate that same input userdata while producing its native edge
prefix. Consequently a captured private entrance initially materialized for
Company 1 can read back as the local issuer, or the component can be absent, by
the time exact topology reconciliation runs. The 0.42.2 precondition rejected
the valid canonical transaction before it could rewrite the generated edge.

## Corrected invariant

Ownership is now a separate plain-Lua plan derived from the already validated
canonical transaction before native construction expansion:

- every private edge records the mapped peer-local native company player;
- every public edge records `-1`;
- the plan must have exactly one entry for every exact edge;
- a private plan entry must equal the proposal's mapped native company owner;
- generated private ownership is rewritten from that plan;
- a missing private component is recreated through the local typed factory; and
- any generated ownership component on a public road is unconditionally
  cleared to `-1`.

Neither the captured nor generated `PlayerOwned` pre-write value is consulted
as authority. Post-write readback remains mandatory, so an engine binding that
cannot carry the intended result still fails closed.

## Regression proof

`tests/run_construction_exact_ownership_tests.lua` exercises:

- an engine-mutated captured private owner;
- a missing captured and generated private ownership component;
- a public road polluted with the local command issuer;
- a tampered owner plan that disagrees with the canonical company;
- connected passenger-bus, passenger-tram, and cargo-truck terminal modes; and
- private entrance plus public split-road ownership in one exact replay.

The existing runtime test also mutates all twelve generated station-track
ownership components before reconciliation. The existing codec matrix still
covers all 216 vanilla street-terminal type, platform, length, and tram-mode
combinations.

The architecture check rejects any return of the old engine-userdata
precondition or removal of the complete owner plan. The complete repository
suite passes: 147 Lua model/codec tests, 7 transport-network tests, 3 alpha-
readiness tests, the new exact-ownership suite, cross-language parity/stress
replay, launcher/lifecycle/package tests, and 225 Python companion, relay, and
recovery tests.

## Native acceptance gate

In the next same-version two-peer room, place one connected passenger bus/tram
terminal from each origin and one cargo terminal. Confirm the private entrance
belongs to the builder, split town-road edges remain public, the terminal opens
only for its owner, both wallets settle once, and the post-build checkpoint
converges. The source-level regression is closed; this gate confirms Build
35924's live userdata setter accepts the corrected plan.
