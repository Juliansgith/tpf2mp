# Alpha qualification: all fourteen gates

Date: 2026-09-01 (Europe/Amsterdam)

Candidate: development tree after `0.42.5-alpha`, based on Git commit
`ea58885`, state schema `35`, checkpoint format `5`, operation schema `4`,
native hook `0.19.0`, Transport Fever 2 Windows x64 build `35924`.

## Result

The candidate passed every gate that can be exercised safely and repeatably on
this machine. The result is suitable for a **fresh physical two-PC alpha
candidate**, not a claim of production readiness. No release was packaged or
published as part of this qualification run.

The strongest new evidence is a 604.9-second populated, two-process network
run with a real routed vehicle, automatic settlements, authored calendar
progression, exact checkpoint convergence, station-release synchronization,
automatic paired recovery capture, and a successful restore. Across 1,168
samples it recorded zero vehicle faults, at most one pending vehicle round,
and 0.315 seconds maximum world-time skew.

Evidence classes used below:

- **native pair**: two real Transport Fever 2 processes and two companions;
- **native**: one real game process with the exact-build hook;
- **model/parity**: independent Lua and Python execution of canonical rules;
- **static/regression**: strict fixtures, protocol validators, or launcher
  lifecycle tests without a human operating a second physical computer.

## Gate summary

| # | Gate | Result | Strongest evidence |
|---:|---|---|---|
| 1 | Shared calendar progression | PASS, native pair | Native date froze at bootstrap; the authored calendar advanced `1940-01-02` to `1940-05-31` by one scheduled epoch on both peers. |
| 2 | Second-station regression | PASS, exact native pair | The two exact relay-captured station transactions replayed sequentially, including both collateral construction removals, and converged at core `c9bb51b1` / structure `87478bad`. |
| 3 | Construction compatibility | PASS for the supported alpha matrix | All 52 stock non-building resources are inventoried; rail/road/tram facilities, passenger/cargo terminals, airport/harbor families, unusual asset roots, headquarters, junction graphs, buoys, edits, removals, ownership, collateral, connected helpers, arbitrary assets, and data-only resource identity were exercised across native, native-pair, and strict matrix tests. |
| 4 | Vehicle lifecycle and ordering | PASS | Purchase/assign/move/replace/sell paths passed for rail, road, air, and water; eight rapid assignments serialize as one in-flight action plus FIFO work with coalesced line registration and no livelock. |
| 5 | Passenger networks | PASS, model/parity plus native presentation | Through demand, intermediate stops, transfers, road/tram feeders, queues, vehicle loads, completed-leg revenue, capacity overflow, and anti-phantom access all passed. |
| 6 | Cargo networks | PASS, cross-language stress | Destination gating, production, inventory, transfers, two physical legs, capacity, cursor monotonicity, conservation, pinned routes, pre-movement replanning, and line deletion passed 256 stress steps at digest `057c3068`. |
| 7 | Save/load/rehost | PASS, native pair | A receipt-bound v6 save pair was restored, paused, saved again through the stock UI, verified, assigned a new boundary, and reloaded into another converged session. |
| 8 | Automatic recovery | PASS, native pair | The soak paused both worlds, captured peer saves at boundary `18`, published plan `4c780a79`, resumed both worlds, and reached a fresh checkpoint. Tamper, mixed-receipt, stale-boundary, and interrupted-watcher cases also pass. |
| 9 | Populated endurance and drift | PASS for the ten-minute gate | 604.9 seconds, 1,168 samples, checkpoints `1` to `10`, four releases, zero vehicle faults, no pending tail, maximum skew 0.315 seconds. |
| 10 | Runtime performance | PASS for idle/running script overhead | A 30-second populated sample measured 172.684 FPS on Player 1 and 175.871 FPS on Player 2, with at most one pending vehicle round. Human build-preview and dense-station camera spikes remain a separate UX gate. |
| 11 | Launcher, installer, updater, relay, cleanup | PASS | Quoted-path CMD entry points, transactional installation, semantic update selection, rollback, autosave restoration, stale-session replacement, save sync, local relay streams, deployed TLS relay streams, diagnostics redaction, and room teardown passed. |
| 12 | Automated regression expansion | PASS | The suite now pins the live second-station bytes and required proof check, exercises state schema `35`, the authored calendar in both languages, every stock construction resource, and construction hard bounds. It finishes green: 153 Lua, 7 transport-network, 3 alpha-readiness, 227 Python, 109 economy vectors, 256 freight steps, 214 Lua syntax files, 9 investigation Lua files, and 80 PowerShell files. |
| 13 | Documentation and limits | PASS | Public quick-start, alpha checklist, architecture, status, remaining-brief, README, and investigation index now describe the shared calendar, recovery behavior, exact station gate, soak requirement, and supported boundary. |
| 14 | Consolidated decision | COMPLETE | This document records the result, evidence paths, and the remaining external gates without upgrading localhost evidence into a two-computer claim. |

## Detailed evidence

### 1. Shared authored calendar

The native calendar is frozen before network bootstrap. Match rules carry a
canonical start date and integer milliseconds-per-day, while scheduled
`economy.settle` actions advance a leap-safe authored date. The default
five-minute epoch at 2,000 ms/day advances 150 days without adding another
network round. The date is checkpointed, save-owned, displayed in the panel,
validated in Lua and Python, and applied to the native UI through an authorized
date command.

- Standalone native freeze/advance/restore proof:
  [`runtime/live-validation/20260901-014350`](../runtime/live-validation/20260901-014350)
- Native-pair terminal/calendar proof:
  [`run-status.json`](../runtime/localhost-live/localhost-alpha14-terminal-calendar-20260901--terminal-calendar/run-status.json)

### 2. Exact sequential station regression

The historical relay fault `mp-2b831d5eac67c488` was reduced to its exact two
captured transactions. The fixture pins transaction digests `7fbee410` and
`bcc7bc62`, including the second station's collateral constructions
`construction:pre:8d3528af` and `construction:pre:8d4028a5`. The fixture is
compressed but SHA-verified, and the live runner refuses to call the slice a
pass unless `second-station-collateral-retired` is present.

- Pinned fixture:
  [`second_station_transactions.json.gz.b64`](../tests/fixtures/live/second_station_transactions.json.gz.b64)
- Native-pair result:
  [`run-status.json`](../runtime/localhost-live/localhost-alpha14-second-station-20260901b--exact-second-station/run-status.json)

### 3. Construction matrix

Fresh evidence in this run covered:

- headquarters, asset builder, field decoration, ground texture, a track
  asset, roundabout, T interchange, and a buoy, including exact native entity
  shapes and removal:
  [`20260901-091506`](../runtime/live-validation/20260901-091506);
- an exact inventory of all 52 non-building `.con` resources (33 public) and
  all 35 street, 2 track, 6 bridge, and 3 tunnel resources:
  [`CONSTRUCTION_EDGE_CASE_QUALIFICATION_2026-09-01.md`](CONSTRUCTION_EDGE_CASE_QUALIFICATION_2026-09-01.md);

- rail depot, passenger and cargo rail stations, electrification/editing,
  compound removal, arbitrary asset placement, and ownership cycles:
  [`20260901-022941`](../runtime/live-validation/20260901-022941);
- passenger/cargo airfield and airport construction/removal plus a Junkers
  purchase, assignment, and 546.935-metre movement:
  [`20260901-023202`](../runtime/live-validation/20260901-023202);
- two passenger harbors, a cargo harbor, shipyard, removal, and a Rigi
  purchase, assignment, and 622.9-metre movement:
  [`20260901-023454`](../runtime/live-validation/20260901-023454);
- connected road depot plus bus across two native processes:
  [`run-status.json`](../runtime/localhost-live/localhost-alpha14-road-depot-vehicle-20260901--road-depot-bus/run-status.json);
- connected electrified tram depot across two native processes:
  [`run-status.json`](../runtime/localhost-live/localhost-alpha14-tram-depot-20260901--tram-depot/run-status.json).

The compatibility manager is resource-driven for data-only vanilla/modded
resources; it is not a promise to execute arbitrary third-party Lua callbacks
identically on both machines.

### 4. Vehicle lifecycle and FIFO pressure

The native construction slices above prove physical purchases, assignments,
and movement for road, air, and water, while the broader integration suite
covers rail purchase, consist portability, assignment, replacement, sale,
line deletion, and divergent local entity IDs. The adversarial eight-assign
case produces one in-flight ordered action and seven FIFO entries, while all
duplicate automatic `line.register` requests coalesce. The 50-vehicle station
slot test assigns unique release slots without overflow.

### 5. Passenger network behavior

`tests/run_transport_network_tests.lua` proves A-B/B-C through demand,
intermediate transfers, and feeder effects. Passenger presentation separately
proves queue/load conservation, exact capacity overflow, completed-leg revenue,
reassignment cleanup, vehicle-sale cleanup, and cargo exclusion. Access is
derived from the native street catchment and fails closed when that API is not
available, preventing disconnected stations from earning phantom revenue.

### 6. Freight behavior

The freight run produced independent Lua/Python parity for three authored
steps and 256 deterministic multi-cargo stress steps:

- [`freight-parity.json`](../runtime/alpha-qualification/20260901/freight-parity.json)
- [`freight-stress.json`](../runtime/alpha-qualification/20260901/freight-stress.json)

Lines do not ship to nowhere. A valid destination and conserved stock path are
required; multi-hop transfer works through an intermediate stop, established
contracts cannot silently reroute, and a path may replan only before its first
movement. Deleting a freight line now retires its authoritative cursor.

### 7-8. Save continuation and recovery

The first restore accepted source boundary `15` under plan `7da2035d`. A new
paired stock-UI save then produced boundary `8`, plan `72e405f2`, and a second
successful load. The populated soak subsequently created boundary `18` and
plan `4c780a79` automatically.

- First acceptance:
  [`20260901-024628.json`](../runtime/restore-acceptance/20260901-024628.json)
- Fresh capture/reload cycle:
  [`20260901-024800.json`](../runtime/fresh-restore-cycle/20260901-024800.json)
- Second acceptance:
  [`20260901-025017.json`](../runtime/restore-acceptance/20260901-025017.json)
- Endurance capture/restore:
  [`run-status.json`](../runtime/localhost-live/phase-anchor-v6-earlyfreeze-20260811-r15-r8--alpha14-populated-soak-20260901/run-status.json)

### 9-10. Endurance and performance

The populated soak began with one tracked vehicle and one completed release.
It ended with four completed releases, zero faults, zero pending tail, and an
acknowledged shared pause. Progress-rate ratio remained between 0.9747 and
1.0. Checkpoint consensus advanced from `1` to `10` before recovery capture.

- Soak measurements:
  [`populated-soak.json`](../runtime/localhost-live/phase-anchor-v6-earlyfreeze-20260811-r15-r8--alpha14-populated-soak-20260901/populated-soak.json)
- Performance sample:
  [`populated-soak-performance.json`](../runtime/alpha-qualification/20260901/populated-soak-performance.json)

Player 1 used 36.544% of one logical core during the 30-second sample and
Player 2 used 3.373%; working sets peaked around 1.44 GB per process. Private
virtual allocation was about 5.0 GB per process. These measurements cover a
running populated view, not every camera angle or active construction preview.

### 11. Distribution and relay lifecycle

The complete suite exercised the installed-release transaction in temporary
roots, including rollback, same-version archival, stable launcher shortcuts,
private-repository updater handoff, and cleanup after exit/crash. A local relay
room (`mp-e61863bc2ee72e33`) and deployed TLS room
(`mp-c42e5b6116a67495`) both carried gameplay and save streams; the deployed
test also uploaded bounded redacted diagnostics. Both tests closed their own
short-lived rooms. A final base-game-tree scan found one historical disposable
`tpf2mp_localhost_bootstrap.lua` residue. The guarded cleanup inventory now
hash-verifies and removes both menu-bootstrap families, its lifecycle test pins
that inventory, and the final base-game scan and default-port scan were clean.

### 12. Regression result

The exact command was:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_tests.ps1
```

It ended with `All TPF2MP tests passed.` In addition to the totals in the gate
table, it verified a 1,024-event deterministic post-checkpoint replay, source
size/boundary rules, canonical JSON/checksum parity, protocol tamper rejection,
recovery-plan integrity, automatic recovery races, relay credential redaction,
native-hook version binding, and clean launch retries.

## Honest residual gates

These are not failures discovered by this run; they are claims this run cannot
make:

1. Run this exact candidate on two physical PCs over the deployed relay. The
   localhost native-pair runs validate the same protocol and game processes,
   but they do not reproduce WAN scheduling, two operating systems, or two
   GPUs.
2. Let two humans play a populated match for multiple hours. Ten minutes is a
   meaningful deterministic soak, not a longevity certificate.
3. Repeat the full human construction matrix, especially airports, harbors,
   dense modular stations, terrain-heavy junctions, and deletion/edit queues,
   on the physical pair.
4. Measure interactive build-preview, bulldozer, dense-station, and vehicle
   detail-panel frame pacing. The read-only running sample does not replace
   those UX observations.
5. Keep the alpha boundary explicit: Windows x64 build 35924, exactly two
   trusted players, no host migration, identical supported content, and no
   promise of arbitrary script-heavy mod compatibility.

## Decision

Proceed to a **versioned physical two-PC alpha candidate** after review of this
diff. If that fresh run passes, pin the resulting version for external testers.
Do not describe the project as production multiplayer yet: recovery is
fail-closed by design, vehicle position is bounded at station rendezvous rather
than continuously lockstepped, and the supported-content boundary remains
intentional.
