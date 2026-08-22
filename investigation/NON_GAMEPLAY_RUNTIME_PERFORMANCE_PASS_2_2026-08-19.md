# Behavior-preserving runtime performance pass 2

Date: 2026-08-19 (Europe/Amsterdam)

Scope: remove remaining per-frame, per-engine-update, and idle filesystem work
without changing authored simulation, command ordering, economy, ownership,
vehicle synchronization, station barriers, or visual content.

## Outcome

This is a deeper follow-up to `NON_GAMEPLAY_RUNTIME_PERFORMANCE_2026-08-19.md`.
It targets work that survived the first scheduler/index pass: repeated runtime
configuration construction, empty protected calls, unconditional native queue
drains, diagnostic native-agent enumeration, anchor-directory rescans, and a
fixed-rate native inbox poll.

No live FPS figure is claimed. The implementation and automated gates were run
without launching Transport Fever 2; a fresh two-instance session is the
measurement gate.

## Changes

### Runtime configuration

- The complete launcher/mod/environment configuration is now built once per
  game-script VM and source-table identity. Previously, common engine and GUI
  paths repeated dozens of environment lookups and up to three marker-file
  opens each time they asked for configuration.
- The only values allowed to change after startup are the three existing
  one-way launcher markers. They are sampled at a bounded cadence and stop
  touching their files after becoming true.
- Tests replace the game configuration table to model a new VM/configuration;
  in-place mutation is intentionally no longer a production contract.

### Engine update path

- A due-work scheduler now enters clock, construction, finance, and housekeeping
  protected calls only when their underlying worker can make progress.
- The guaranteed no-op standalone vehicle synchronizer call was removed.
- Manual bootstrap maintenance sleeps until its launcher/restore preconditions
  and retry tick are satisfied.
- Network pump error callbacks are persistent functions rather than closures
  allocated on every update.
- Vehicle-list discovery is invalidated by vehicle buy/sell transactions, not
  by every unrelated canonical registry revision. Existing save vehicles still
  receive the required initial full discovery scan.
- Vehicle synchronization reads scalar native game time rather than building a
  complete calendar/clock table.
- The measured-task wrapper no longer allocates packed argument/result tables
  and recursive unpack frames around every network task.

### GUI and native command capture

- The native hook exposes a suppressed-command pending bit mask. An idle GUI
  checks that mask once and does not drain the speed, line, and vehicle queues
  unless the corresponding bit or an existing correlation is pending.
- Older hooks remain supported through the prior polling fallback.
- Shared-speed button traversal occurs immediately on an authored speed change
  and otherwise only at the repair cadence.
- Stock toolbar/window projection now has a cheap due predicate. An unchanged
  snapshot no longer enters the protected projection path every frame, and one
  company projection is reused across all toolbar fields.
- Public GUI snapshots use three seconds of monotonic wall time rather than 180
  frames. A high-refresh client therefore no longer refreshes the same heavy
  projection three times as often as a 60 FPS client.

### Diagnostic and retained state

- Passenger cosmetic requested totals remain current, but the expensive native
  `SIM_PERSON`/vehicle/terminal enumeration is now an infrequent diagnostic
  sample or an explicit research probe. This does not drive authoritative
  passengers, station counts, vehicle loads, revenue, or settlement.
- Finalized checkpoint consensus history is bounded to the newest 128 records;
  pending records and `lastAgreed` are always retained. This prevents long
  sessions from growing checkpoint saves and periodic scans without bound.

### Companion and native bridge

- Anchor requests/results have directory-mtime and file-signature indexes.
  Repeated readiness polls no longer glob, sort, and parse every historical
  JSON file.
- Client receipt sequence allocation is O(1) after initial discovery, and the
  pending sequence-to-request map makes acknowledgements O(1), with a restart
  scan fallback.
- The native async bridge caches the next inbox path and uses the Win32 file
  attribute query for existence checks.
- Inbox discovery adapts from 10 ms after traffic to 50 ms when idle, then
  immediately returns to 10 ms after traffic. Ordered consumption, durability,
  and sequence rules are unchanged; worst-case discovery added by an idle poll
  is 40 ms.
- Localhost launch policy disables Windows execution-speed power throttling for
  both game processes, in addition to the existing balanced affinity and normal
  priority. This specifically prevents the unfocused peer from being treated
  as background work by Windows.

## Preserved invariants

- Every authored network message is still consumed in sequence and every
  native command is still captured; no bridge, consensus, or replay cadence was
  weakened.
- Economy boundaries, fares, demand, costs, town/industry development, cargo,
  passengers, and finance calculations are unchanged.
- Native vehicle routes, holds, releases, schedules, and all-peer station
  rendezvous are unchanged.
- Build acceptance, ownership checks, canonical IDs, and physical proposal
  replay are unchanged.
- The only lower-frequency native-agent operation is a research/cosmetic
  diagnostic that is outside authoritative gameplay and digest state.
- The 128-record checkpoint limit affects finalized history only. The current
  pending boundary and recoverable last-agreed boundary cannot be evicted.

## Automated proof

- 136/136 Lua core tests, 7/7 transport-network tests, and 3/3 alpha-readiness
  tests passed.
- Game-script, network mapping, hot-seat, GUI, launcher, package/update/install,
  recovery, cross-language replay, and source-boundary suites passed.
- 181/181 Python tests passed, including new indexed-anchor assertions.
- Both native CTests passed and the rebuilt hook passed all 17 exact Build 35924
  signature checks against the installed executable.
- `git diff --check`, Lua syntax for 150 files, investigation-Lua syntax for 9
  files, and PowerShell syntax for 59 files passed.

## Fresh two-instance measurement checklist

Use a newly launched pair; an old process cannot load the rebuilt hook.

1. Pause both peers for 60 seconds with all TPF2MP and stock entity windows
   closed. Record stable Player 1/Player 2 FPS and the host/client ratio.
2. Run speed 3 for five minutes with two or three trains. Record FPS while
   following a train and verify normal station holds/releases and settlement.
3. Open a train, station, line manager, and Multiplayer window for 20 seconds
   each. Watch for constant resizing/re-layout and record the lowest stable FPS.
4. Place and edit one station, a road/track crossing, signals, and a depot.
   Preview geometry may remain a stock-engine spike; verify FPS recovers after
   placement and every result appears once on both peers.
5. Burst several line/vehicle actions. Capture should remain immediate despite
   the idle queue optimization, with no deferred FIFO or consensus fault.
6. Pause the non-host peer with Escape for 30 seconds, resume, and verify train
   barriers recover exactly as before.
7. Leave speed 3 running for at least 20 minutes, then Export Research on both
   peers. Compare performance task counters, native queue depth, checkpoint
   agreement, drift, and companion health.

The native status field `inboxPollMs` should settle near 50 while idle and reset
toward 10 around traffic. That is expected and is not network lag.
