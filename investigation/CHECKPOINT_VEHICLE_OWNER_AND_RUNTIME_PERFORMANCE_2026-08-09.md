# Checkpoint vehicle owner and runtime performance, 2026-08-09

## Outcome

The automatic economy-settlement pause in live session
`restore-handoff-live-20260809-2127` was a real fail-closed checkpoint fault,
not a shared-clock stall. Both games authored the same state, but a
manifest-bound pre-existing train had no `companyCid` in the vehicle-sync
projection while its passenger-presentation entry correctly named
`company:1`. The strict Python verifier rejected both checkpoints with
`checkpoint passenger vehicle has no matching synchronized vehicle`; boundary
29 eventually timed out and ordered the permanent shared pause.

The verifier remains strict. New releases now bind the train company from the
canonical economy service, reject a conflict, and save migration backfills only
an absent field from that same service. This repairs the receipt-bound boundary
11 saves without accepting inconsistent checkpoint data.

## Exact live evidence

The two source checkpoint envelopes are retained at:

- `%TEMP%/tpf2mp_bridge/restore-handoff-live-20260809-2127/player1/game_outbox/000000004570.json`
- `%TEMP%/tpf2mp_bridge/restore-handoff-live-20260809-2127/player2/game_outbox/000000005130.json`

Both contain core/model/structure/convergence digests
`b65b9593` / `655472b0` / `5c15a724` / `a0216c1e`, 518 canonical objects, and
the same `vehicle:pre:e8c0305d` on `line:pre:2820313f` at authorized round 2.
In both envelopes the synchronized vehicle omits `companyCid`; in both the
passenger vehicle has `companyCid=company:1` and `lastRound=2`. The host audit
records the settlement as commit 29 and the later
`checkpoint-consensus-timeout:player1,player2` outcome for boundary 29. The
last verified recovery point remains boundary 11; the faulted worlds must not
be resumed.

## Performance audit

The displayed `native reconciliations` count was not five economy settlements
per second. It counted full native-wallet cache audits. The main update loop
called that audit every engine update, including two native `PLAYER` reads per
company, deep-copy/history work, and possible journal correction. P1 owns the
running native train, so native trip/maintenance drift makes that path
asymmetric. The multiplayer update also ran clock/economy/vehicle sync once
directly and then a second time in the bridge pump. Vehicle discovery sorted
and scanned all 518 canonical bindings on each call. Separately, the GUI
enumerated every native line every rendered frame even with an empty capture
queue.

An eight-second sample of the old, faulted, paused processes consumed 5,953 ms
of CPU on P1 and 3,391 ms on P2 (74.4% versus 42.4% of one core). Earlier
matched samples showed the same main-thread direction. This proves material
host-side overhead, but not the user's worst observed 4-5x FPS ratio; camera,
window, and renderer state were not controlled in the old session.

The implementation now:

- audits an idle native wallet every 15 engine updates, follows a newly issued
  correction after one update, and backs off three updates while a physical or
  checkpoint barrier makes correction unsafe;
- performs one native balance read per company on idle audits instead of two;
- runs clock/economy/vehicle synchronization only once per network update;
- caches canonical vehicle IDs and invalidates the cache on buy/sale;
- avoids full native-line enumeration when the capture queue and pending
  CreateLine ledger are empty;
- checks the stock speed indicator every third render frame unless authority
  changed, preserving immediate clock changes with less GUI lookup pressure.

The adaptive wallet cadence is isolated in
`network_finance_housekeeping.lua`; ordered release validation is isolated in
`vehicle_sync_release_runtime.lua`. `proposal_runtime.lua` is 1,413 lines and
`vehicle_sync_runtime.lua` is 378 lines, both below their enforced budgets.

## Verification

`tools/run_tests.ps1` passes after the change:

- 124/124 Lua tests;
- 144 Python tests;
- 108 cross-language economy scenarios;
- freight vector and 256-step multi-cargo stress parity;
- GUI/native capture, game-script, company mapping, recovery, release,
  installer rollback, syntax, and source-boundary checks.

New focused regressions prove owner backfill, strict rejection when the
checkpoint still lacks a matching owner, one canonical vehicle scan across
repeated idle updates, the 15-update finance cadence, and zero idle line
enumerations after baseline initialization.

## Fresh live gate

Fresh session `perf-ownerfix-live-20260809-2351` loaded the same receipt-bound
populated save in exact Build 35924 processes P1 `40616` and P2 `3888`. Both
native hooks and companions connected, match initialization checkpoint 1
completed, the shared clock ran the real train, and automatic five-minute
settlement committed at sequence 14 without a fault.

The settlement checkpoint envelopes are retained at:

- `%TEMP%/tpf2mp_bridge/perf-ownerfix-live-20260809-2351/player1/game_outbox/000000000322.json`
- `%TEMP%/tpf2mp_bridge/perf-ownerfix-live-20260809-2351/player2/game_outbox/000000000467.json`

The complete post-close copy is durable under
`runtime/manual-network-evidence/perf-ownerfix-live-20260809-2351-20260810-000833`.
Independent audit replay validates 15 commits, 15 converged commit digests, two
complete checkpoint barriers, four station releases, and zero physical,
checkpoint, or vehicle-sync faults.

Both report core/model/structural/convergence values
`453ddda0` / `35c363f2` / `5c15a724` / `4b506d48`. Both project
`vehicle:pre:e8c0305d` on `line:pre:2820313f` with `companyCid=company:1`, and
their passenger-presentation entries independently carry the same company.
The host accepted the checkpoint as `economy-settlement`; `lastError` and
`sessionFault` remained empty.

Controlled eight-second CPU samples used matching minimized windows. Three
paused repetitions averaged 2,057 ms on P1 and 1,979 ms on P2, or 25.7% and
24.7% of one core. Three running repetitions averaged 1,740 ms and 1,734 ms,
or 21.7% on each process, while game-time skew was approximately 0.03 seconds.
This reverses the old measured host penalty instead of merely reducing its
counter display.

The two windows were then restored individually to the same saved camera and
geometry. Stable foreground spot readings were 105 FPS on P1 and 128 FPS on
P2. A spot reading is not a frame-time benchmark, but the remaining 1.22x
difference is qualitatively and quantitatively unlike the reported persistent
4-5x host/client gap. Together with the matched running CPU samples and the
successful settlement, this closes the demonstrated host-hot-loop regression.
A future dense-network benchmark should still record frame-time percentiles;
it is a scalability measurement, not a prerequisite for this fix.
