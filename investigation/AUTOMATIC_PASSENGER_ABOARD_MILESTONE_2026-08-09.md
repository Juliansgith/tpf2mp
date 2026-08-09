# Automatic passenger-aboard milestone

Date: 2026-08-09 (Europe/Amsterdam)

Implementation target: prototype `0.36.0-alpha`, state schema `29`, checkpoint
format `5`, passenger-presentation schema `2`

## Outcome

The focused local feeder acceptance no longer depends on clicking **Export
Checkpoint** during the short interval in which a bus or tram carries riders.
The first positive authored load on a qualifying local feeder schedules one
host-authored ordered action:

```text
passenger.milestone {
  stage = "aboard",
  lineCid = <canonical line>,
  vehicleCid = <canonical vehicle>
}
```

Both peers independently verify that the exact canonical vehicle is still on
the named line with a positive passenger load. Successful application opens a
`passenger-milestone:aboard` checkpoint barrier. The action is evidence-only:
the preceding ordered `vehicle.sync_release` owns boarding, and the milestone
does not mutate the passenger ledger again.

## Eligibility and false-positive boundary

Unlike cargo, the first passenger train must not consume the one-shot evidence
needed for a later urban feeder. Before scheduling or accepting the action, the
passenger policy therefore requires all of the following authored facts:

- network mode, host peer, connected companion, and a running match;
- a passenger-presentation line and vehicle with at least one rider aboard;
- an enabled economy service with `marketScope = local`;
- carrier `ROAD` or `TRAM`;
- exactly two equal endpoint-town identities;
- at least two distinct canonical station groups.

A rail corridor, disabled service, intercity route, duplicate-stop route, or
malformed binding leaves the milestone available for a later valid feeder.
Only the host can submit it, but both games run the same ledger and eligibility
checks when applying the ordered commit.

## Queue and checkpoint behavior

Passenger and freight milestones share `aboard_milestone_runtime.lua` and the
same bounded follow-up FIFO. Repeated observations coalesce by milestone type,
so a loaded vehicle cannot create a registration-style commit storm. The queue
does not emit consensus-bound work while the peer is disconnected. A successful
commit opens exactly one checkpoint; the per-session probe suppresses later
station rounds after that checkpoint has been authored.

The Python companion recognizes the new action as:

- a network action with strict exact fields and canonical ID bounds;
- host-authority-only;
- consensus-bound, so it cannot begin with a missing peer;
- checkpoint-opening on initial commit and audit restore;
- a no-op in model replay because the ordered release already owns the load.

The shared live-evidence scanner treats the milestone as an expected checkpoint
boundary. Consequently `start_feeder_live_acceptance.ps1` now always requires
`RequireObservedAboard` in its final strict report without asking the player to
time any extra input.

## Automated evidence

Lua runtime tests cover host/client authority, strict wire fields, positive
ROAD feeder acceptance, disconnection suppression, ordered FIFO/coalescing,
automatic checkpoint export, and rejection of rail and duplicate-stop false
positives. Python tests cover strict portable validation, host-only origin,
connected-roster gating, checkpoint creation/restoration/replay, and a complete
two-peer live-report fixture whose reason is `passenger-milestone:aboard`.

The complete repository gate passes 122 core Lua cases, 108 cross-language
economy scenarios, 134 Python tests, 111 mod Lua syntax checks, 8 investigation
Lua syntax checks, 44 PowerShell syntax checks, both deterministic replay
traces, and release-manifest/launcher/recovery tests.

No game was launched for this slice. A real ordinary-UI bus/tram run remains the
decisive proof that Build 35924 produces the expected release/registration facts
and that the milestone commits before the vehicle reaches its opposite endpoint.
Run it with every old game process closed:

```powershell
.\tools\start_feeder_live_acceptance.ps1 -Carrier ROAD
```

Closing either window automatically collects and rejects the run if the aboard,
completed-trip, feeder-benefit, settlement, physical-consensus, or two-peer
checkpoint chain is missing.

## Release verification

The exact `0.36.0-alpha` package contains 282 files and is 7,771,103 bytes:

`SHA-256 8117EBE6129BE7AE235FF03567B907FAA926AE5D87F7E667F4DFEBAFED5D9721`

Its isolated install/verify/uninstall round trip accepted all 111 manifest-bound
mod files, companion `0.10.0`, state schema `29`, checkpoint format `5`, the
three presentation/freight schema versions, and the exact Build 35924 native
profile. The same release directory was then installed successfully into the
normal Steam userdata mod path and versioned local support path.
