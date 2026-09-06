# Transport UI qualification — work in progress, 2026-09-06

This tracks the requested player-input regression matrix, not merely native
command replay. A historical PASS is tied to its source fingerprint and must
be rerun after implementation changes. Missing cells are **not qualified**.
The reference map includes the official legacy-vehicles overlay.

| Family | Real UI proof recorded | Still required |
| --- | --- | --- |
| Passenger rail station | P1 through / P2 terminus, free one-track placement using native defaults; length was not independently asserted | Track/road attachment, terrain, houses, road + houses, every size/platform/module variant |
| Cargo rail station | None in this physical-UI suite | All applicable construction and operational scenarios |
| Rail track | Free build and public-road crossing after capture fix | Long curves, slope, bridge, tunnel, houses, junction removal, actual crossing traversal |
| Rail depot / train | Free depot, native manager/catalogue, replicated Buy | Connected exit, native route, multi-assignment, return/sale/replacement |
| Bus station | Free placement | Road attachment, terrain, houses, road + houses, sizes and terminals |
| Truck station | Free placement | Road attachment, terrain, houses, road + houses, sizes and terminals |
| Road depot | Full fixed bus (P1) and truck (P2) suites passed, including road-snapped placement, native Buy/assignment, depot exits, two-stop travel and final audit/cleanup. Separate terrain-height run `104133-a5521f` also passed final audit/cleanup | House and road+house combinations; additional depot variants |
| Tram depot | Fixed 20-case run `113005-ed86b4`: road-snapped depot, both road electrification upgrades, native Buy/assignment, depot exit and both-peer two-stop journey; final audit/cleanup passed | Terrain, houses, road+house combinations and additional depot variants |
| Bus / tram / unload edge stops | Both curb sides passed in complete bus, truck unload and electric tram suites (`095548-2b51e4`, `100519-7e87ec`, `113005-ed86b4`), with actual two-stop travel on both peers | Upgrades, replacement and freight loading/delivery |
| Passenger airfield | Fixed ten-case run `102425-563748`: two airfields, hangar NAME/catalogue, Buy, two-stop line/assignment, native arrivals at both stops on both peers and final audit/cleanup | Terrain, road/house combinations, variants and upgrades |
| Large / cargo airport | No new physical-UI proof | All applicable placement, native buying/assignment and flight scenarios |
| Passenger harbor / shipyard | Fixed 14-case run `101441-ec3b71`: two shore harbors, shipyard NAME, native Buy/line/assignment, native two-stop journey on both peers and final audit/cleanup | Road/terrain/house combinations and variants |
| Cargo harbor / ships | No new physical-UI proof | Cargo terminals, native route and delivery accounting |
| Road / tram road | Native electrification of both public-road sections, followed by actual electric tram traversal and depot exit, in `113005-ed86b4` | Free/long/curved/graded builds, crossings, houses and additional road variants |
| Signals / waypoints | Earlier separate stock signal-capture evidence only | Fresh two-instance physical placement/replacement/bulldoze cases on this candidate |
| Ownership / persistence | Buyer-only charges and output ownership in recorded build/Buy cases | Rival editing, matched ordinary save/load ownership and finances, recovery and rebuy |

## Bugs already reproduced and repaired in this task

- Stationary native preview expiry at high render rates.
- Mixed rail/public-road crossing: canonicalize the correlated processed
  topology before ordering, rather than silently cleaning an agreed graph.
- Airfield edge-object vector identity, transform rebasing and processed-object
  materialization; then missing hangar NAME exposed by actually opening it.
- Test isolation: periodic recovery could compete for UI input and maximize a
  test window. The disposable UI fixture now excludes that competing driver.
- Physical key scan codes, scoped modifiers, and parent-side release if a
  killed input worker cannot run its cleanup.
- Right-side bus stop capture: native STOP_LEFT/STOP_RIGHT reference enums are
  not identical to the processed stop category. Both sides are now proven
  by physical clicks, complete native counts, ownership and buyer-only charges.
- Journey proof pins owner, native model where needed, both vehicle identities,
  unchanged line stops, motion and distinct destinations. Checkpoint-only waits
  retain route observations; pending gameplay still fences native reads.

## Current unresolved blockers / evidence limits

- Intermittent native Load Game page stalls, before world initialization.
  Failed launches, stack-only dumps and cleanup receipts are retained. Their
  root cause is not established, and retries are not counted as startup proof.
- Harbor stop-click calibration is resolved: opening the native manager changes
  the map view. An explicit camera reset frames both harbor icons above the
  manager, and the native two-stop route completed on both peers.
- The same calibration then exposed an incomplete inventory oracle: a bus stop
  built on both peers, but the signal-only edge-object inventory reported zero.
  Full inventory schema 3 now enumerates attached BASE_EDGE objects separately
  from bootstrap kind discovery. Failed/partial reads cannot report completeness.
  The original run remains FAIL, with all cleanup checks satisfied.
- Small passenger aircraft full journey passed after the isolation fixes;
  this does not qualify larger airports or cargo aircraft.
- The initial station recipe did not explicitly set or verify a length. Its
  captured UI actually selected the 160 m button; the earlier 80 m table label
  was incorrect and is withdrawn. Size/platform combinations need explicit
  selection plus an independent native geometry postcondition, not merely
  identical peer counts or a successful click on a parameter button.
- Exact native purchase-window estimate versus charged amount is not yet
  asserted; current checks prove positive charge to the correct company.
- Passing placement/inventory checks alone cannot prove a usable attachment.
  Connected-building coverage requires the corresponding native vehicle path.

## Running and evidence

See [LIVE_UI_TESTING](../docs/LIVE_UI_TESTING.md) for the suite and batch commands.
`tools/check_live_ui_coverage.py` deliberately remains red until all required
physical proofs are present on the same candidate fingerprint. Calibration
reports cannot satisfy it. The broader table above exceeds the initial
44-label gate. The expanded requirement file now names 412 individual coverage
labels; these are requirements, not claims of successful testing. Most still
need calibrated recipes and real two-instance qualification.

Latest completed offline gate: `runtime/live-ui-static-20260906-1128.log`.
It includes 361 Python tests (116 focused UI harness tests), Lua/PowerShell/native checks and the
1,024-event cross-language replay. This does not substitute for the live matrix.

The `083315-2c5647` bus calibration stopped before sending its assignment click:
the authored follow-up omitted a mandatory `changed` postcondition. That is a
test-authoring failure, not a game fault. Its 12 passed prerequisites remain
calibration evidence; the corrected fixed bus recipe is being replayed fresh.

Load-menu hang `084535-5929d2` is retained separately. Its dump reports suspend
count zero for all 79 threads, so an unbalanced injector SuspendThread is **not
supported** by this evidence. Root cause remains open.

## 09:43 continuation: native terrain and road vehicle evidence

- `localhost-ui-20260906-091440-9b58d4`: all 14 truck UI cases passed,
  including P2 buying the Opel Blitz dump truck through the native catalogue,
  assigning a two-stop line, and native motion/arrivals at both stops on both
  peers (28 observations each). The overall run FAILED at shutdown: it waited
  for a newer recovery-save checkpoint although ordered actions had settled.
  Empty truck travel is **not** cargo loading, delivery or revenue proof.
- `localhost-ui-20260906-093522-1d153e`: both depot terrain cases passed.
  49/81 sampled points changed by at least 0.05 m; maximum change 1.9375 m;
  no peer disagreement above the 0.01 m tolerance. The initial API-read failure
  was the observer rejecting native callable wrappers as non-functions.
  The overall run FAILED at shutdown because the initially paused fixture had
  no acknowledged network pause generation. All exact-process cleanup passed.
- The harness now physically clicks Pause before shutdown, preserves readiness
  checks for pending work and peer health, and replays the full audit with
  `require_settled=True` against the fresh host sequence. Only checkpoint age
  relative to a **save** boundary may be ignored; production save-readiness rules
  are unchanged. Full supervisor audit and cleanup still gate every final PASS.
- These failed overall runs are retained as failed evidence, not relabeled as
  release acceptance. Fresh fixed recipes are being replayed.
- Creating `STOP` in the batch output directory prevents further launches after
  the current suite's supervisor finishes audit and cleanup. It does not abort
  an in-flight construction or silently skip remaining coverage.

## 10:06: complete fixed bus acceptance PASS

`localhost-ui-20260906-095548-2b51e4` passed all 14 fixed bus UI cases and the
outer supervisor (`supervisorVerified=true`, `shutdownSettled=true`). This
includes a road-connected depot, left/right roadside stops, stock Saurer Buy,
native two-stop line creation/assignment, native motion and both distinct
arrivals on both peers, buyer-only debits and matching physical checkpoints.

Final audit: 31 commits, all 31 converged, zero awaiting peer digests;
3 completed physical proposals, 5 completed operations, 10 completed checkpoint
barriers; no rejected/faulted/pending physical proposals or operations. Both
games and companions were closed and all six fixture cleanup flags passed.

Source fingerprint:
`f64e1a6a4438771371f3476a82f0959b18461ef3b9086f59c71d64b89c3cf0db`.
This is one bus route/vehicle/fixture, not blanket bus or all-building coverage.
The truck, ship, aircraft and terrain recipes are being tested independently.

Initial-only pause follow-up: clicking an already-selected native Pause toggle
does not emit a command. Generation-zero fixture shutdown now physically selects
normal speed, verifies the ordered all-peer transition, and then selects Pause.
No synthetic clock intent is used, and ordinary game/save rules are unchanged.

Loader hang `094321-398d7f` remains INFRA_BLOCKED. Before the timeout/dump,
Windows reported the main thread and most worker threads as Wait/Suspended,
while the external stack dump reports SuspendCount=0. A zero-byte native crash
dump also appeared around the stall. These observations do not establish why
the native loader stopped, or prove an injector suspend imbalance. Do not erase
user save metadata or silently retry an issued gameplay command to conceal it.

## 10:14: complete P2 truck acceptance PASS

`localhost-ui-20260906-100519-7e87ec` passed all 14 fixed truck UI cases and
the outer supervisor, on the same fingerprint as the bus result. The P2-owned
Opel Blitz dump truck was bought and assigned through stock widgets. Both peers
recorded 24 motion/arrival observations and stops 0 then 1 at distinct canonical
unload stations. This proves the road/depot path and P2-origin operational sync.

Final audit: all 30 commits converged, zero awaiting peer digests; 3 completed
physical proposals, 5 completed operations, 10 completed checkpoint barriers,
no rejected/faulted/pending proposals or operations. Pause, exact-process exit
and all fixture cleanup checks passed. **No cargo producer/consumer delivery
or freight settlement is claimed by this empty-vehicle movement test.**

## 10:24: complete P2 passenger ship acceptance PASS

`localhost-ui-20260906-101441-ec3b71` passed all 14 fixed ship UI cases and
the outer supervisor on fingerprint `f64e1a6a...0db`. P2 placed two passenger
harbors and a shipyard, opened the native catalogue, bought the small
Schaffhausen, created a two-stop line, assigned it through the native picker,
and completed movement/arrivals at both distinct harbors on both peers.

Final audit: all 33 commits converged, zero awaiting peer digests; 3 completed
proposals, 5 completed operations and 10 completed checkpoint barriers;
no rejected/faulted/pending proposals or operations. The acknowledged pause,
supervisor verification, exact-process exit and all six cleanup flags passed.
This qualifies the small passenger ship route, not cargo delivery, large ship
compatibility, every harbor variant, or harbor road attachments.

## 10:41: complete passenger aircraft acceptance PASS

`localhost-ui-20260906-102425-563748` passed all ten fixed aircraft cases,
including the supervisor and settled shutdown, on fingerprint `f64e1a6a...0db`.
P1 placed two stock airfields, opened the native hangar/catalogue, bought the
Junkers F13, created a two-stop line, and assigned the aircraft via the native
picker. Both peers recorded 265 samples and movement followed by arrivals at
stops 0 and 1, with matching distinct native/canonical airport identities.
The journey assertion took 540 seconds; requested top speed stepped down under
the existing adaptive clock controller. No test override bypassed that control.

Audit: all 38 commits converged; 2 completed proposals, 5 completed operations,
9 completed checkpoint barriers; zero rejected/faulted/pending physical work
or missing peer digests. All six cleanup checks and exact-process exit passed.
This proves the small passenger airfield route. Large airports are not even
available in this 1940 fixture; cargo aircraft and airport variants remain
unqualified, rather than inheriting this small-airfield PASS.

## 10:46: five-suite batch fully passed and closed

Batch `runtime/live-ui-batches/20260906-095547-0ae043b3` passed all five suites
on the same fingerprint: bus, truck, ship, aircraft and road-depot terrain.
Final terrain run `104133-a5521f` also passed the formerly failing initial-pause
shutdown path using actual 1x then Pause input. Its 10 commits all converged;
one proposal and three checkpoint barriers completed with no outstanding work.
All test game processes are closed. Earlier failed attempts remain failures.

The next harness revision adds bounded physical ground targeting; that revision
needs fresh qualification and does not automatically inherit this batch's PASS.

Offline gate after the ground-targeting addition:
`runtime/live-ui-static-20260906-1048.log` — all checks passed, including
343 Python tests (98 focused UI tests), the Lua/native/PowerShell checks and
the 1,024-event cross-language replay. Ground readbacks reject native callable
failures, nonfinite/stale values, out-of-view targets and unbounded recipes;
presses are still ordinary Windows input with no gameplay injection path.

## 11:06: tram calibration exposed an observation-file handoff race

`localhost-ui-20260906-105049-60f0e0` stopped during P2's native save-page
load, before gameplay input. Its bounded timeout/dump and successful exact
process cleanup are retained as an infrastructure failure, not a gameplay PASS.

The next pair, `localhost-ui-20260906-105436-ec5c37`, passed ten calibration
cases: native terrain-cursor targeting, road-connected tram depot, both public
road electrification upgrades and the first native tram stop. Windows then
rejected atomic replacement of the observation request file while the game's
reader held it open. This happened before case 11's input, not during a build.
The audit converged all 13 commits (four proposals, six checkpoints), with no
pending or rejected operation; all six cleanup checks passed. The run remains
incomplete/failed, and calibration is not acceptance coverage.

The writer now retries only the same immutable request-file replacement for
at most two seconds. It never reissues a gameplay click. Four new tests cover
transient and permanent contention, unrelated I/O failures, and an actual
Windows reader handle without delete-sharing. All 102 focused UI tests and
the mandatory Lua observer/source-boundary checks passed. A fresh 13-case
tram recipe is rerunning in `localhost-ui-20260906-110756-a8900d`; its result
is not yet an operational qualification.

## 11:21: full tram workflow calibrated; subsequent focus handoff failed

All first 20 cases of `localhost-ui-20260906-110756-a8900d` passed, including
the native Halle electric tram purchase (`vehicle/tram/halle_v2.mdl`, carrier
2), stock two-stop Line 1, assignment, and 46 motion/arrival samples on each
peer. Both peers recorded stops 0 then 1 at the same distinct station groups;
the journey assertion took 84.765 seconds. The request-file contention did
not recur in this rerun.

Additional town-inspection case 21 failed before its first gameplay click:
Windows could not put the cursor on the verified caption during focus handoff.
All six cleanup flags passed and both game PIDs exited. This overall run is
still failed calibration, not a releasable acceptance receipt. The first 20
cases are now frozen as `content/live-ui/tram-native-route.json` for an
independent fresh replay.

Caption positioning now tolerates a bounded test-peer confinement race. It
rechecks confinement and process identity before retrying cursor positioning;
foreign-app confinement, an unexplained cursor move, or a covered title bar
still refuses input. No gameplay/caption click is repeated. Five focused tests
cover these branches. SDL reapplying the clip is a plausible cause of the
original handoff failure, not a proven diagnosis from its sparse error alone.

Native edge-geometry observation was also added behind the disposable-lab
capability and busy fence. It reads physical BASE_EDGE descriptors, without
construction getters, metadata repair or binding discovery. Optional rail
layout assertions independently count parallel contiguous tracks and their
spans. Identically wrong track counts/lengths on both peers fail; equal world
digests do not satisfy the requested shape. The new geometry assertion still
requires native station calibration. All 116 focused UI tests and the Lua
observer preflight passed; the full offline gate is running separately.

## 11:42: complete fixed electric tram acceptance PASS

`localhost-ui-20260906-113005-ed86b4` passed all 20 fixed cases, settled
shutdown and the outer supervisor on source fingerprint
`a0ae110ad5f22336717d573522074c7f3ddf329e2b35cc8d707f36d78923d59c`.
Each peer recorded 48 motion/arrival samples, with stops 0 then 1 at matching
distinct canonical station groups. The native journey took 89.687 seconds.

Final audit: all 38 commits converged, zero awaiting peer digests; five
completed physical proposals, five operations and 12 checkpoint barriers;
no rejected, faulted or pending physical work. All six cleanup flags and
exact game-process exit passed. The ordinary final pause/focus handoff also
completed. This qualifies this electric-tram route and connected depot, not
all tram station sizes, terrain/demolition combinations or the full matrix.

## 12:28: paused for background-input discussion; games closed

New loader evidence is in `NATIVE_SAVE_MENU_DUMP_HANG_2026-09-06.md`.
Rail calibration `120243-ad46ee` failed because a recipe used a collection
where a numeric delta was required. The next run `121116-704c4d` exposed a
native "Too much slope" preview, so the earlier shorter track cannot qualify
a snapped two-station connection. Neither failed run is an acceptance PASS.

Six new numeric-evidence tests reject such invalid recipe paths before input.
The full offline gate passed before `121116-704c4d`; the focused UI suite now
has 122 passing tests. Current source fingerprint is
`4c1f8154e900c784f19cba26e3f616a6660f04dd56a467b99eb586827df7f72a`.

Flatter fixture calibration `122140-02b268` passed its four cases and settled
supervisor cleanup: two P1 one-track 160m stations, camera framing, and a
native track preview. This remains `physical-ui-calibration`, **not** route
qualification. The connecting track was NOT confirmed, and no train or depot
was built in this run. The final preview screenshot shows native `Collision`
with the forestry industry between the stations; the unchanged-world preview
case is not a claim that this route is buildable. Calibrate a route around that
industry, or move the whole corridor farther west, before confirming track.
All 12 commits converged; two physical proposals and
four checkpoint barriers completed, with no rejected/faulted/pending work.

The user asked about contained/background input. A STOP file ended calibration
at its next safe case boundary; both exact game PIDs and companions are closed.
No new foreground launch should occur until that discussion is resolved.
The current input backend uses the user's real foreground mouse/keyboard;
`IsolatedDesktop` isolates helper-process crashes, not desktop input.
