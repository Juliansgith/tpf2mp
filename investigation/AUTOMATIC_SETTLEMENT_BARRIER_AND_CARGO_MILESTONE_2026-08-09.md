# Automatic settlement barrier and cargo milestone

Date: 2026-08-09
Prototype: `0.32.0-alpha`
State/checkpoint schemas: `29` / `5`

## Outcome

Automatic economy settlement now fails closed across peer loss and restart,
and strict cargo-aboard evidence no longer depends on a player timing a manual
checkpoint. These are reliability and observability changes; they do not alter
the economy arithmetic, cargo allocation, native vehicle movement, or station
barrier cadence.

## Settlement disconnect boundary

The game-side economy clock is host-only in network mode. It now also requires
the companion to report the peer connected before it may submit
`economy.settle`. If the peer disappears after a settlement was submitted but
before ordering, the stale local pending marker is cleared even while the
engine tick remains frozen. The still-due boundary is retried on the next
connected update.

The game-side ordered lane also retains queued work while its companion status
says the required roster is disconnected. The companion independently gates
every consensus-bound action against its required live roster. The shared set includes match initialization, physical
prepare/operation work, registrations, town development, content/freight
bootstrap, recovery actions, structural probes, economy settlement, and the
cargo milestone. This is the decisive guard: a disconnect race cannot put a
checkpoint-opening commit into history with no second peer available to close
it.

Host status now exposes the pending and last-agreed checkpoint reasons plus
pending/complete/faulted counts. The interactive localhost runner prints a
checkpoint transition only when that state changes, so a long manual session
does not hide a stuck economy boundary in ordinary log noise.

## First-load milestone

The first ordered `vehicle.sync_release` that leaves an authoritative cargo
vehicle with `aboard > 0` causes player 1 to queue exactly one derived action:

```text
freight.milestone {
  stage = "aboard",
  lineCid = <canonical line>,
  vehicleCid = <canonical vehicle>
}
```

It uses the existing non-reentrant FIFO. It cannot be emitted recursively from
inside the station-release commit, cannot bypass another physical/checkpoint
barrier, and cannot be authored by player 2. On ordered application, however,
both peers accept the host-authored action and independently require all of:

- the exact four-field portable envelope;
- valid bounded canonical line and vehicle IDs;
- an active matching cargo line;
- that vehicle bound to that line; and
- a strictly positive exact authored load.

Any disagreement rejects the action and therefore faults closed through the
ordinary generic ordered-action rejection path. A successful application marks
the one-time probe and opens `freight-milestone:aboard` checkpoint consensus.
This is one extra round for the first load in a match, not one round at every
station. The later five-minute settlement checkpoint remains the proof for
delivery cursors, freight stock movement, revenue, and finance.

## Restart and pressure proof

The automated host stress performed 32 consecutive settlements. Every one
committed, collected two matching format-5 checkpoints, emitted its ordered
checkpoint outcome, and left no pending tracker or session fault. The final
audit reloaded into a fresh host with all 32 boundaries complete and replayed
cleanly. A separate interrupted fixture stopped after only player 1's evidence,
reconstructed that exact pending boundary after host restart, and proved that
another settlement, proposal, and operation could not overtake it.

The milestone has independent Lua/Python proof for strict field parity,
host-only authorship, client-side application, local ledger verification,
disconnect refusal, duplicate suppression, FIFO emission, checkpoint creation,
audit reload, portable replay, and freight-report acceptance. The full gate
passes 117 core Lua tests, 75 economy parity scenarios, 2 focused plus 256
stressed freight parity boundaries, 126 Python tests, 107 mod Lua syntax
checks, 42 PowerShell syntax checks, release-manifest checks, launcher smoke,
fault-bundle fixtures, and native-load boundaries.

## Remaining live evidence

No Steam/game process was started for this slice. The next cargo-positive
two-process run should use:

```powershell
.\tools\start_freight_live_acceptance.ps1 -RequireObservedAboard
```

The human only needs to build and run the freight service. The panel's
`Cargo proof` row should progress through waiting, aboard, delivered, and
settled. The companion should briefly report a pending then agreed
`freight-milestone:aboard` boundary at the first load. Closing the run should
pass `-RequireObservedAboard` without any manual checkpoint click.
