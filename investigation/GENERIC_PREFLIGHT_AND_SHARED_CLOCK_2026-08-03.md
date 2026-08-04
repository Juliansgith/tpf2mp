# Generic construction preflight and shared clock

Date: 2026-08-03 (Europe/Amsterdam)  
Prototype: `0.18.0-alpha`  
State schema: `17`

## Triggering live failure

In `lan-station-perf3-live-20260803-2318`, Player 2 drew a public road from a
town-owned road with **Player ownership: No**. The road committed in Player 2's
world but did not appear in Player 1's world. Player 1 rejected replay because
the canonical pre-existing junction was not in its local binding map:

```text
canonical node is not mapped locally: node:pre:52591204
```

The host then faulted the old post-mutation proposal barrier. That explains all
three observations: one road existed only on Player 2, later builds were
rejected, and changing the ownership toggle did not repair the session.

The transaction also carried a local street repository index without a stable
resource name. That was a second portability fault waiting behind the first.

## Construction protocol change

Network construction is now two phase:

1. The issuing game captures a canonical `proposal.prepare`. Numeric entity IDs
   remain local. Road/track resources must include their repository name.
2. Every game validates the payload, resolves all named resources, lazily binds
   any referenced pre-existing road/track nodes by exact canonical geometry,
   and checks logical ownership. No native build command is issued.
3. Each game acknowledges readiness and its unchanged core digest.
4. Only if every pinned peer agrees does the host emit `proposal.build`.
5. Native results, canonical outputs, finance and the subsequent checkpoint
   still require all-peer agreement.

A failed prepare emits a non-fatal rejection. Neither world mutates, the
session does not become permanently faulted, and the player may correct the
placement and try again.

Pre-existing base-node identity is now position-based and base-edge identity is
endpoint-geometry-based. Names and engine-local IDs are excluded because they
are neither required for reconstruction nor stable across independently loaded
processes. An ambiguous geometric match is rejected rather than guessed.

## Data-driven resources and mod compatibility

Road and track types are no longer replayed by their numeric repository index.
The wire payload names the resource (for example a `.lua` repository path), and
each peer resolves that name to its own local index during prepare. This covers
vanilla and mod-added road/track resources without adding a hardcoded list to
TPF2MP, provided every peer has byte-identical match content.

This is not a claim that arbitrary script mods are automatically multiplayer
safe. A mod that only contributes data-driven road/track resources can use the
generic graph codec. A mod that issues a new command shape, stores private
state, mutates the world from `update`, or depends on local entity IDs needs a
versioned canonical adapter and deterministic postcondition. Unknown command
categories remain blocked. The match manifest must eventually fingerprint the
complete enabled mod pack, not merely the TPF2MP files and pinned save.

## Shared simulation clock

The overlay now exposes Pause and speeds 1-4 as `clock.request` actions. The
host converts a request into a generation-numbered `clock.set` commit; both
games authorize and issue the same native `SetGameSpeed` command, then
acknowledge it. Local, unsequenced native speed commands remain gated.

Every game periodically reports:

- requested, effective and observed native speed;
- clock generation;
- engine tick and game time;
- last consumed commit;
- whether physical construction is pending.

The host chooses the effective speed from the slowest peer. Persistent commit
backlog, stale heartbeats, poor peer tick-rate ratio, or an observed-speed
mismatch steps the shared speed down. Severe lag pauses at zero so ordered work
can drain. After a healthy hysteresis window it raises the effective speed one
step at a time toward the players' requested speed.

This is bounded command/checkpoint resynchronization, not deterministic native
lockstep. It cannot make local passenger IDs or individual train positions
identical. Pause/resume behavior and the threshold tuning still require a fresh
two-process live run.

## Verification completed offline

- Canonical pre-existing road nodes resolve across deliberately divergent local
  IDs; ambiguous stacked nodes fail closed.
- Network proposals without stable resource names are rejected.
- Resource names resolve independently on each peer.
- A failed prepare never emits a build and does not fault the session.
- A successful prepare emits exactly one host-generated build.
- Shared-clock protocol fields are strict and bounded.
- A simulated slow peer reduces requested speed 4 to effective speed 3.
- The game script authorizes native command tag 0 and issues the committed
  effective speed.
- The complete offline test suite passes.

## Required live proof

Start a fresh state-schema-17 localhost session. Verify, in order:

1. Public road from a town road, initiated by Player 2, appears once on both
   peers and charges only Company 2.
2. A disconnected/free-standing road appears once on both peers.
3. A deliberately unsupported placement is rejected on both peers, after which
   a supported road still succeeds without restarting.
4. A non-default vanilla road and track resource resolve on both peers.
5. Request speeds 1, 4, and Pause from alternating peers; both games display the
   same effective generation and native speed.
6. Artificially burden one process and confirm the host steps down, later
   recovers, and does not lose or duplicate construction commands.

