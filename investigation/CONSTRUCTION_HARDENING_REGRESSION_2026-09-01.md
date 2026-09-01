# Construction hardening and local regression sweep

Date: 2026-09-01 (Europe/Amsterdam)

Target: Transport Fever 2 Windows x64 build `35924`, development candidate
after `0.43.2-alpha`, construction proposal schema `7`, native hook `0.19.0`.

## Outcome

The current development candidate passed a fresh exact two-process replay, the
complete repository suite, the stock construction inventory, native rail/road
geometry stress, mature facility ownership/edit/removal, and live air and water
vehicle lifecycles. No session fault, asymmetric residue, native crash, or
cleanup leak remained in the final runs.

The sweep found and fixed five defects that were not all visible in the recent
human sessions:

1. A symmetrically rejected track candidate did not increment the validator's
   `completed` counter, so the exact host/client validator could wait forever
   even though the session had checkpointed the safe rejection.
2. Curbside station and station-group replacement bound outputs incrementally
   and depended on its current caller's outer rollback for atomicity. A direct
   reuse or future caller could therefore expose a retired old identity when a
   late replacement binding failed.
3. Native output-delta arrays used `#`/`ipairs` without first proving a dense
   numeric array. A sparse or keyed table could omit a persistent output from
   canonical binding.
4. Persisted connected-depot repair records trusted several helper identities
   and the earlier PREPARE validation. A stale/malformed record could reach
   derived materialisation after a process boundary.
5. The localhost harness could enter impossible retry loops without the exact
   populated fixture or independently captured industry registries, and its
   cleanup assertion misclassified a managed overlay inherited from an
   interrupted earlier run.

## Corrections

- Network validation now identifies each proposal by canonical transaction
  digest, records a symmetric no-residue rejection, waits for its converged
  checkpoint, and deterministically advances to the next terrain candidate.
- Derived transit-stop identity changes are staged against a copied canonical
  registry. Station and station-group removals/additions, custody, and logical
  ownership are committed only after every binding succeeds.
- Construction deltas now reject non-array keys, holes, duplicates, invalid
  IDs, and over-limit arrays before any output is accepted.
- Connected-depot graph repair now validates the persisted source transaction,
  internal/helper node and edge identities, finite positions, endpoint
  orientation, unique node slots, and both possible internal-node ordinals.
- Exact localhost construction slices fail before launch when their populated
  save is absent; empty-world labs fail before launch when their two-peer
  industry artifacts are absent. Managed overlays must be absent after every
  non-interactive run, regardless of which run originally created them.

The extracted modules keep these rules reviewable rather than growing the
already-large runtime files:

- `proposal_derived_station_binding.lua` owns atomic station/group rebinding;
- `validation_track_candidates.lua` owns deterministic build/reject/retry
  validation.

## Exact two-process proof

The final run loaded the same pinned populated save in two independent game
processes with native authority active:

- evidence: [`localhost-20260901-182644--post-hardening-final`](../runtime/localhost-live/localhost-20260901-182644--post-hardening-final);
- final core digest: `2d727c18` on both peers;
- final structural digest: `e0982b55` on both peers;
- ordered commits: `21`, all converged;
- physical proposals: `4` complete, `1` safely rejected, `0` faulted,
  `0` pending;
- checkpoints: `8` complete, `0` faulted, `0` pending;
- industry registry: `edc7a517`, 16 resources and 160 variants on both peers.

The rejected client terrain candidate was intentional evidence for the repaired
path: both worlds rejected it without residue, converged the rejection
checkpoint, selected the next candidate, and completed the rest of the match
flow.

## Native construction matrix

All listed runs used Build 35924 and the active native hook. Each also passed
the 39-check authoritative validator at digest `86bf7792` and restored
`settings.lua` byte-for-byte.

| Evidence | Coverage | Result |
|---|---|---|
| [`20260901-182958`](../runtime/live-validation/20260901-182958) | Rail depot, passenger/cargo rail stations, station electrification/edit, asset build/remove, compound removal, four ownership lease/return cycles | Pass |
| [`20260901-183220`](../runtime/live-validation/20260901-183220) | Passenger/cargo airfields and airports, facility ownership/removal, aircraft purchase/assignment and 560.43 m movement | Pass |
| [`20260901-183515`](../runtime/live-validation/20260901-183515) | Passenger/cargo harbors, shipyard, ownership/removal, ship purchase/assignment and 630.65 m movement | Pass |
| [`20260901-183831`](../runtime/live-validation/20260901-183831) | Headquarters, asset builder, field/ground decoration, track asset, roundabout, T-interchange and buoy build/remove | Pass |
| [`20260901-184048`](../runtime/live-validation/20260901-184048) | 990 m straight, 1,023.87 m curve, terrain grade, 900 m tunnel, public-road crossing, collateral demolition, sloped station and sequential recovery | Pass |

The stock inventories also remained exact: 52 non-building construction
resources, 35 street resources, 2 track resources, 6 bridges, and 3 tunnels.

## Regression suite

The full command was:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_tests.ps1
```

It passed:

- 154/154 focused Lua assertions;
- 227/227 Python tests;
- Lua syntax for 218 runtime files and 10 investigation files;
- PowerShell syntax for 82 files;
- documentation/link/release-identity checks;
- source-size and extracted-module boundaries;
- cross-language economy, freight, proposal and checkpoint parity;
- packaging, updater, launcher, relay, recovery, overlay, autosave and teardown
  regressions.

## Honest remaining boundary

Automation proves the canonical/native transactions and representative stock
geometry, but it does not synthesize every possible real mouse preview. Track
decoration snapping, a GUI-expanded cloverleaf, map-edge placement, exact
maximum-grade cursor feedback, and arbitrary third-party scripted construction
callbacks remain human-facing compatibility tests. These are bounded residual
tests, not known failures in the current candidate.

No release was packaged or published by this sweep.
