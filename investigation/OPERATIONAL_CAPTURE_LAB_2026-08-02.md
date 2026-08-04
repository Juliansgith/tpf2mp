# Populated operational capture lab

Date: 2026-08-02 (Europe/Amsterdam)  
Prototype baseline: 0.16 / state schema 13 / native hook 0.8.0 / exact Build 35924

## Purpose and safety boundary

The previous 600-tick localhost soak was a useful structural/finance proof, but
it was not an operational railway proof: it had no lines or vehicles, did not
record effective game speed, sampled only the ends of the soak, and could not
retest the passenger/cargo readers under real load.

`tools/start_operational_capture_lab.ps1` starts two exact game processes as
**independent standalone hot-seat worlds**. Native BuildProposal and
consequential-command gates are explicitly disabled, so ordinary stations,
lines, vehicles, signals, upgrades and running services remain playable. No TCP
companion is started and the UI says `OPERATIONAL CAPTURE ONLY (not
synchronized)`. This mode must not be cited as network convergence.

The separation is deliberate. It gives the hook real player traffic to observe
without either blocking unsupported commands or allowing unsynchronized actions
inside a session presented as connected multiplayer.

## New observation envelope

Every configured interval (120 engine updates by default), each process emits a
signed `operational` bridge record containing:

- effective `game.interface.getGameSpeed()`, pause state, game time and date;
- authored-model, canonical-core, structural, mobility, autonomy, journal and
  account digests at the same intermediate sample;
- all company balances/loans plus the active turn-desk account;
- towns' `developmentActive` readback and bounded primitive
  `SIM_BUILDING` fields, including `manualDevelopment` when exposed;
- line/vehicle structure and the five earlier passenger/cargo availability
  probes (`getCount`, persons-for-line, cargos-for-line, terminal info/free
  places), with aggregate counts and protected errors;
- the compact native pipeline state, tag counts, completed commands, direct
  applies, unknown tags and mismatches.

The in-save history retains 64 summaries. Full samples are written to the local
bridge instead of bloating canonical state.

## Command-origin and payload capture

The hook's synchronous pre-issue callback now projects every observed
`api.cmd.sendCommand` command, not only BuildProposal. The bounded allow-list
includes line, stop, station, depot, vehicle, assignment, replacement,
maintenance, departure, name, color, speed, journal and proposal fields.

Commands issued through TPF2MP use a same-Lua-state marker and receive a
specific origin such as `mod.finance.book-journal-entry` or
`mod.network.replay-build-proposal`. Unmarked traffic is conservatively labeled
`unmarked-player-or-engine`; it is not overclaimed as human input. Each envelope
gets a deterministic digest, a 64-record local history, and an immediate
`operational-command` bridge record in capture mode.

This is an observation/correlation layer, not yet a canonical codec. Native
`CommandList::Swap`/`ApplyCommand` records remain the authoritative tag and
success evidence. An apply with `batch=0` still identifies the direct path.

Because a real GUI action can bypass the Lua `sendCommand` wrapper, capture mode
also records a parallel, non-blocking `operational-gui` envelope for mutation
events involving lines, vehicles, depots, stations, terminals, constructions,
maintenance and replacement. It includes a bounded payload projection,
referenced entity IDs and a deterministic digest. Repeated identical UI events
within two GUI frames are deduplicated. These records never veto, replay or
claim authority over the action; local IDs and payloads stay in the 64-record
capture ring and bridge evidence and are stripped from the persistent event
action. The analyzer reports both issuing-path commands and GUI envelopes.

## Automatic lifecycle

The launcher:

1. runs the full offline suite, installs current sources, verifies Build 35924
   and builds the native artifacts unless explicitly skipped;
2. backs up shared settings and injects only the disposable bootstrap/game
   script/library under validated game-resource targets;
3. starts and hooks each process sequentially to avoid shared-cache races;
4. requires observer-active native status with both mutation gates disabled;
5. auto-initializes two companies with 50,000,000 each, enables the local turn
   proxy, disables pause-on-switch, and freezes town/industry development;
6. requires a complete initialized operational sample from both processes
   before printing `OPERATIONAL CAPTURE LAB READY`;
7. collects both bridge trees and native/log evidence, produces JSON/Markdown
   operational analysis, restores settings/resources, and stops only the two
   disposable PIDs.

The analyzer reports per-process speed coverage, reader availability, maxima,
balance deltas, digest changes, command origins, native tag counts and direct
applies. It also reports first/final cross-instance equality as diagnostic data,
never as consensus.

## Empty-world launcher proof

`runtime/localhost-live/operational-smoke2-20260802` passed the complete
two-process lifecycle on exact Build 35924 before populated play. Both hooks
were active with both authority gates disabled, both worlds auto-initialized,
and cleanup restored shared settings and every temporary resource. Player 1
emitted seven samples and Player 2 four. Both stayed at speed 1 with two towns
reporting development frozen and five industries reporting
`manualDevelopment=true`; both finished with equal core `38e6631c` and
structure `1be6e32a`, zero unknown tags and zero tag mismatches. The analysis
correctly reports that no vehicles ran and all four mobility readers remained
unavailable in that empty-world condition. That is lifecycle/autonomy proof,
not a passenger/cargo result.

## Guided populated human result

`runtime/localhost-live/operations-20260802-guided50` completed the full
two-hour lifecycle and ended `PASS` on 2026-08-02. The launcher restored shared
settings and all temporary resources and stopped only its two disposable game
PIDs. These remained independent local worlds throughout; none of this result
is network synchronization evidence.

The final collector also correctly reported `sourceInstalledMatch=False`:
the stale-edge recovery patch described below was authored after these two
processes had loaded the launch-baseline scripts. The operational evidence
therefore belongs to the captured installed baseline; the new recovery path is
claimed only from offline integration tests until a fresh process loads it.

The human-play gate passed:

- Player 1 built a two-station passenger railway, depot, line and train. The
  train completed multiple full cycles without a broken path or ownership
  warning and visibly carried `8/30` passengers.
- Player 2 built a producer-to-consumer cargo railway, depot, line and train.
  It also completed multiple full cycles without a broken path or ownership
  warning and visibly carried `8/48` cargo.
- Both worlds ran at UI speed 3, reported by the engine as speed 4. Each peer
  emitted 355 initialized interval samples; Player 1 had 75 speed-4 samples and
  Player 2 had 74. Across those running samples there were no model, autonomy,
  canonical-core or structural digest transitions after construction had
  stabilized.
- Town development remained disabled and all five industries continued to
  report `manualDevelopment=true` on both peers. Model and autonomy digests
  never changed and remained equal between the otherwise intentionally
  different worlds.
- The five supported/documented mobility reads all remained unavailable even
  with real populated lines: total persons, persons for line, cargos for line,
  terminal information and terminal free places. The visual loads prove that
  this is an API-boundary limitation, not evidence that the native simulation
  was empty.
- The GUI-created BuildProposal, CreateLine, UpdateLine, BuyVehicle and SetLine
  work all used the queued command path. No player build/management action was
  observed using direct apply. Player 2's six later direct `Book` applies were
  generated by scripted proxy reconcile/cycle bookkeeping.

The exact Player 2 proxy settlement also passed. Reconcile at tick `38643`
changed Company 1 from its canonical `50,000,000` to its real native result of
`44,120,148` (delta `-5,879,852`), retained all 80 logical assets, and pinned all
70 private edges. Cycling at tick `39380` preserved Company 1 and entered
Company 2 with `50,000,000`; the second settlement had native delta zero.
Research, snapshot and checkpoint exports bracket both transitions.

Player 1 was deliberately not reconciled in the loaded session. Ten edge
replacement observations included six ambiguous split/join or bulldozer
correlations, leaving a stale fail-closed replacement latch even though the
route remained visibly healthy. Source now contains a standalone-only inventory
recovery path that retires missing active-company edge identities, re-adopts
the observed desk/company inventory, preserves remembered rival custody, pins
the replacement edges and validates custody before any money moves. A
live-shaped split-edge integration test and the complete offline suite pass.
The already-loaded Player 1 process could not hot-reload that correction, so a
fresh disposable run is still required to live-prove recovery.

Visual evidence and its provenance are recorded in
`runtime/localhost-live/operations-20260802-guided50/visual-evidence`. The final
machine report is
`runtime/localhost-live/operations-20260802-guided50/operational-analysis/operational-analysis.md`.

## Remaining focused checks

The broad populated-play experiment no longer needs to be repeated. The next
short disposable run should cover only:

1. Build one compact passenger or cargo railway for Company 1 and reconcile it
   after at least one loaded trip. This live-proves the new stale-edge recovery
   path when the native builder performed ambiguous split/join replacements.
2. Cycle to Company 2 and attempt harmless access to Company 1's train, depot,
   each station, and one private-track electrification. Management/configuration
   and private-track replacement must fail before mutation, with no balance,
   asset or structural change.
3. Export Research, Snapshot and Checkpoint after those denials, then close the
   lab and verify automatic cleanup.

After those local proxy checks, the captured CreateLine, UpdateLine, SetLine,
BuyVehicle and related envelopes can be promoted into strict canonical codecs
and enabled one category at a time in network mode. Native passenger/cargo
loads still need a different observation or host-owned replication seam; the
five public readers cannot supply it on Build 35924.
