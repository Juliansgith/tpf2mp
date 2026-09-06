# Real UI airfield failures and repairs — 2026-09-06

The physical two-instance UI harness, not a prepared proposal probe, reproduced
three defects while placing the first stock passenger airfield with hangar.
The pinned fixture is a 1940 save with TPF2MP and official legacy vehicles.

## Evidence and causes

1. `localhost-ui-20260906-043745-970b43`: codec rejected the stock 25-node,
   25-edge, 11-object proposal with `edge-object vector order does not match its
   edge reference`. Object -1 belongs to edge -33; object -2 belongs to -32.
   Traversing edges sorts these differently from the object vector. Processed
   objects have a separate vector-local negative index identity. Explicit
   object identities remain supported, but both identity and carrier must
   match; mismatches, duplicate identities and category conflicts reject.
2. The same captured proposal exposed a separate cache defect. Moving the
   construction ghost rebased nodes/tangents but not `modelInstance.transf`.
   Internal objects remained hundreds of metres from their carrier graph.
   Rebasing now includes object rotation, translation and elevation on the
   isolated click copy, leaving the cached template immutable.
3. `localhost-ui-20260906-045009-2c89f6`: capture/normalization succeeded, but
   replay rejected on both peers before mutation. The exact topology handler
   treated processed `EdgeObject` as `SimpleStreetProposal.EdgeObject`.
   The former exposes `segmentEntity` and `modelInstance`, not writable
   `edgeEntity`, `param`, and `model`. The extracted processed-object helper
   validates carrier, model, category, side, direction and recovered spline
   parameter before changing only public ownership/name metadata. Unknown or
   mismatched geometry still rejects before sending the command.

## Verification

- Captured 11-object fixture retained in
  `tests/fixtures/live-ui/airfield-edge-objects.json`; it intentionally retains
  the original stale transforms. Unit tests isolate the identity defect with
  explicit test parameters and separately exercise transform rebasing.
- Strict userdata tests reject writes of Simple-only fields, wrong model,
  carrier, category, direction, and spline position.
- `localhost-ui-20260906-045634-7e4671`: **both airfields passed** real mouse
  placement. Both native worlds contain their stations/hangars; company 1 owns
  them and only company 1 was charged. Two completed physical proposals, four
  completed checkpoint barriers, no rejection/fault/pending proposal. Source
  and installed content matched; games and companions were closed afterwards.

This proves placement, not aircraft buying, takeoff, arrivals, passenger delivery,
all airport sizes, road connection or demolition. Those remain separate UI
qualification cases. Previous synthetic aircraft probes are not a substitute.

The full offline gate subsequently passed: 279 Python tests, 162 main Lua tests,
additional Lua and PowerShell checks, and the 1,024-event cross-language replay
(`runtime/live-ui-static-20260906-0503.log`). Live receipts bind exact source
fingerprints and must be rerun after further code/harness changes.

## Extended native hangar interaction — unresolved

`localhost-ui-20260906-050702-3768d6` repeated both airfield placements, then
clicked the first hangar icon through the normal UI. P1 stopped answering GUI
observations; native stdout emitted thread-ping warnings. The native crash
dump `69763eef-6e5f-405d-b312-3bf989babb0f.dmp` belongs to P1 PID 12972 and
records an access violation at game RVA `0x117a611`, reading address `0x10`.
The faulting instruction reads a `std::string` length through null RSI in a
native selection-data function (range `0x1179200..0x117ad92`). Missing naming
data is a hypothesis, not yet a confirmed cause or implemented repair.

A local-only stack dump was also retained as `hangar-thread-p1.dmp` in the run
directory. The screenshot helper itself stalled in `BringWindowToTop`; after
retaining the dump, the exact disposable P1 was stopped to release the test
driver. The supervisor closed the remaining owned processes and retained a
failed case. The batch correctly kept that failure while starting a fresh
water-calibration pair. That pair failed at native Load Game before gameplay;
it is infrastructure-blocked, not a water transport result.

Follow-up harness changes isolate each physical input/screenshot in a
20-second worker, never retry a possibly issued click, capture a local dump on
timeout, and expose read-only depot NAME presence before risking selection.

## Hangar NAME root cause and live repair

The next run (`localhost-ui-20260906-052319-648f1c`) confirmed a native depot
without NAME on both peers. The new pre-selection assertion failed safely
instead of opening it. The player's captured construction had `name =
"Coleford Airport"`; canonical construction records dropped it, and the typed
materializer explicitly passed `name = ""`. That omitted the compound
airfield's child hangar naming component. Standalone depots use a different
helper path, which explains why their UI tests did not reveal this.

Named construction schema 9 now carries and digests the original bounded name.
Lua and Python validate the same UTF-8 byte bound/control-character policy;
unnamed schema 8 and prior 7 remain accepted unchanged. Schema 9 retains all
schema 8 street features. Native materialisation restores and round-trip
checks the name before expansion, with no post-build rename command.

`localhost-ui-20260906-053514-94354e` PASS: two physical airfields, NAME present
on each hangar on both peers, native hangar click, aircraft catalogue open,
and native empty line creation. Nine converged commits, two complete proposals,
one complete operation, five complete checkpoint barriers, zero rejected,
faulted or pending physical work; installed source matched and cleanup ran.
This is not yet buying, assigning or flying an aircraft; the following recipe
extends those separate assertions.

`localhost-ui-20260906-054443-215c7b` PASS: the extended seven-case physical
recipe purchased one Junkers F13 through the native catalogue, verified the
aircraft on both peers with carrier 3/company 1 and a buyer-only debit, and
created a native line with two distinct airfield stops on both peers. Thirteen
commits, two proposals, four operations and eight checkpoint barriers completed;
no rejected, faulted or pending work. Installed source and replay audit matched.
All disposable processes closed. Assignment and actual flight are still a
separate, unqualified requirement.

Subsequent calibration attempts `055240-7131fd` (P2) and `060152-f3f695` (P1)
stalled before the native Load Game page opened. Local stack-only dumps show
deep native UI layout/style work, but do not yet establish the cause. These
are failed infrastructure attempts, not airfield test passes or failures.
Do not remove user saves or count a later successful retry as their repair.

## First native flight and an interfering save driver

`localhost-ui-20260906-060549-c60537` passed the nine build/open/buy/line/assign
cases. One actual airport-to-airport flight completed on both peers. Fresh
TRANSPORT_VEHICLE/MOVE_PATH_AIRCRAFT observations show moving state 1, arrival
state 2 at stop 1, bilateral departure round 2, and departure back toward stop 0.
The initial taxi to stop 0 completed before the first journey sample because
the recipe waited/took screenshots after unpausing; that arrival correctly did
not count as movement proof. The full two-arrival assertion was NOT passed.

At 06:21:29 local, the 15-minute recovery scheduler invoked the independent
stock-UI save helper for P1, boundary 57. Its `01-maximize` step changed the
viewport; the input guard stopped the case as INFRA_BLOCKED after 532 seconds.
The helper subsequently reported the game window closed by supervisor cleanup.
This was our background test infrastructure, not an external user's input.
The final audit was valid: 39 converged commits, two completed proposals,
five completed operations, nine complete barriers and zero faults/rejections.

Fix: UI fixtures now explicitly set automatic recovery interval 0 and disable
watcher UI fallback. Ordinary sessions keep their existing defaults. Journey
sampling starts before screenshot capture, collects transient arrivals during
consensus convergence, and still requires agreed/fault-free final state.
`aircraft-native-route.json` preserves the discovered native inputs as a fixed
recipe; it requires its own fresh successful run before it qualifies coverage.
