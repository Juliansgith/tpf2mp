# Removal-only town road with attached-building collateral

Date: 2026-08-10 (Europe/Amsterdam)

Prototype: `0.37.0-alpha`, state schema `30`

Status: live failure reproduced and preserved; correction is fully automated;
fresh two-process proof remains required.

## Live finding

Session `flat-medium-soak-20260810` remained healthy through a large modular
station build. Proposal `player1:60` created the station and its generated
topology on both peers, then checkpoint `61` converged at core digest
`a1f99340`.

The later bulldozer click, proposal `player1:64` with transaction digest
`e8afa391`, removed one public town-road edge, one road node, and two attached
autonomous constructions. It added no replacement topology. Capture was
portable and identical, but the runtime treated its canonically first generic
construction as a standalone construction bulldoze. That selected the
multi-tick construction helper instead of one atomic `BuildProposal`. Native
replay eventually rejected on both peers with result digest `43f630ba`.

Resolving the previously unbound road, node, and buildings for replay had also
created lazy canonical bindings. Those bindings changed the prepared core from
`a1f99340` to `4a8f8109`, so the companion correctly classified the rejection
as `native-rejection-mutated-prepared-core` and faulted the session. Every
later station click was then blocked by the fail-closed physical lane. The
station codec was not the cause.

The complete first-fault bundle is preserved under
`%LOCALAPPDATA%\TPF2MP\sessions\flat-medium-soak-20260810\player1\fault-evidence\20260810-121648-410-attempt-1`.

## Correction

Construction capture now retains a stable semantic kind derived from the
loaded construction resource. A removal-only transaction with explicit
road/track edge or node removal plus generic autonomous-building collateral is
classified as a topology transaction and materialized as one native
`BuildProposal`. Finalization requires every explicit edge, node, edge object,
construction, and asset in that transaction to have disappeared before any
binding retirement or finance settlement.

The boundary remains deliberate:

- town roads/tracks plus ordinary attached buildings use the atomic topology
  path, even when no replacement edge is added;
- station and depot roots keep the established asynchronous construction
  helper because the engine retires their generated graph over later ticks;
- any partial or ambiguous native result still faults closed.

## Rejected-command recovery

GUI replay now snapshots exact `BASE_EDGE`, `BASE_NODE`, `CONSTRUCTION`, and
available `ASSET_GROUP` entity sets plus both relevant native wallets before
issuing a proposal. A native rejection is recoverable only when those sets and
wallets remain byte-for-byte equivalent at the observable boundary.

The proposal runtime separately records only the lazy bindings created while
resolving that command. For an attested unchanged rejection it removes those
bindings and restores the prior canonical revision, reproducing the exact
PREPARE core. This permits unanimous no-mutation rejection and its checkpoint
without poisoning the session. A rejection with any observed world or finance
change remains a hard consensus fault.

## Automated evidence

The exact live shape is now a codec regression: one road edge, one node, two
autonomous construction removals, and zero additions. It proves atomic
classification and exact local materialization. Runtime coverage proves the
generic topology route, the separate station-helper boundary, disappearance
postconditions, and exact digest/revision restoration after a verified
no-mutation rejection. GUI coverage proves the removal route and unchanged
world attestation.

The complete repository gate passes: 129 core Lua tests, 108 cross-language
economy scenarios, freight parity and stress, GUI/game/network integrations,
Python companion/recovery tests, syntax and source boundaries, packaging,
fault-watcher fixtures, and install verification.

## Fresh live acceptance

1. Build a station and confirm it reaches both peers.
2. Bulldoze a town-road segment attached to one or more houses.
3. Confirm the road/node and attached buildings disappear together on both
   peers and only the issuer pays.
4. Immediately build another station; it must synchronize normally.
5. Bulldoze a station separately to confirm it still uses and completes the
   asynchronous helper path.
6. Also try one native-invalid bulldoze/build. If the engine changes nothing,
   both peers must reject it, checkpoint, and accept the next valid build.
