# Real native UI regression harness — 2026-09-05

## Why another test layer

The existing two-game construction corpus exercises prepared proposals and
replay. It cannot establish that a player can choose a stock item, generate a
preview, click to commit, open the depot, and press Buy. Those entry paths have
regressed while the prepared-action tests remained green.

The new `tools/run_live_ui_suite.ps1` supervisor and `tools/live_ui/` driver use
physical Windows input, fresh disposable two-peer worlds, and native GUI
rectangles. The opt-in Lua observer reads physical/canonical state; it does not
dispatch commands or repair the world. Camera positioning is fixture setup,
not a construction shortcut. Full details: [live UI testing](../docs/LIVE_UI_TESTING.md).

## Proof contract

Each positive case requires physical objects on both peers, exact count delta,
new shared checkpoint, native and authored fingerprint equality, ownership and
wallet assertions where specified. Equal unchanged worlds cannot pass a build.
One-sided changes, duplicate output, placeholders, missing inventory, and stale
checkpoints fail. Blocked/unrun cases do not count as coverage. A source change
invalidates a report. The UI suite closes its exact games and companions on
success or failure.

## Integration findings during development

- A new top-level `local` exceeded Lua 5.1's 200-local entry-script limit. The
  observer now uses inline `require`, with an actual Lua 5.1 entry-script parse
  as a mandatory prelaunch gate, even when the longer static suite is skipped.
- Windows DPI virtualization and denied foreground activation can target the
  wrong menu rectangle. Input uses per-monitor DPI awareness, pinned process
  handles, foreground and point-ownership checks, and a verified title-bar-only
  activation fallback. No fullscreen/maximization or arbitrary fallback click.
- `AttachThreadInput` can hang the driver with a stalled native window. It is
  not used. Short-lived input workers and the full suite have watchdogs.
- The game's Lua sandbox lacks `os.remove` and `os.rename`. Observer responses
  use bounded direct writes; readers reject partial JSON and stale request IDs.
- The structural probe performs binding discovery. The observer runs that
  probe on private copies, avoiding repairs masquerading as test success.
- Whole UI-tree walks exhausted their node budget on hidden catalogue rows
  before reaching the toolbar. Exact-ID observation and hidden-subtree pruning
  keep selection bounded without guessing a target.
- The initial runner call was in the wrong supervisor branch. It executes
  after `MANUAL LAB READY`; a missing UI report makes the parent run fail even
  if bootstrap and checkpoint validation succeeded.
- Rail toolbar `isSelected()` stayed false even with its native menu visibly
  open. The smoke recipe now checks the real settings-window visibility.
- The native save list can report a row as visible while its rectangle is
  thousands of pixels outside the scroll clip. The test loader observes the
  actual ScrollArea rectangle and performs bounded physical wheel scrolling.
- The native FIFO rewind unit test used `Sleep(12)` even though the production
  bridge uses adaptive idle polling. It intermittently failed before a poll
  was due. The test now waits up to 500 ms for the same exact record/counters;
  production transport behavior was not changed to make the test green.

## Completed smoke proof

`localhost-ui-20260905-234233-39667c`: PASS, two physical-UI toolbar cases,
30.93 seconds for the UI portion. P1 PID 704 and P2 PID 22276 loaded the pinned
map automatically, bootstrapped and converged, opened and closed the stock
rail menu, verified both worlds/balances unchanged, and were cleaned up.
The post-run journal audit was valid (four commits, four converged, no pending
or faulted construction/operation/checkpoint barriers). Source fingerprint at
that run: `306d0b3abb86a689446765b0df2dd754c10e1cd96ad19ec1d341dbe8f30ac058`.
This is historical smoke evidence; subsequent source changes require a new
receipt for the coverage gate.

## Coverage honesty

### 2026-09-06: first gameplay regression found and verified

`localhost-ui-20260906-000543-c691e9` physically selected a vanilla station,
waited over its ghost, and clicked once. No station appeared on either peer.
The UI suite failed on physical count zero despite a healthy, equal pair.
Logs: `suppressed build has no preview with its native correlation token`,
then `builder.apply has no generation-bound preview`.

`gui_build_correlation.lua` pruned even the currently armed stationary ghost
after 600 GUI frames. At 200+ FPS this is only a few seconds. An unchanged ghost
need not emit another preview. The active correlation/generation is now retained
until replacement, cancellation or consumption; superseded history remains
age-bounded. Ownership, tag, source/family and generation protections remain.
Offline tests cover long stationary holds, replacement, consumption and cancel.

`localhost-ui-20260906-001358-d2a441`: PASS two physical station builds, P1
through and P2 terminus, 56.81 seconds of UI tests. The five-second hover
produced preview ages of 1,791/2,061 frames in the P1 GUI evidence. Both peers
had two native station groups; charges were $174,943 to P1 and $169,434 to P2,
each exclusively for its own build. Shared boundary 13, native digest
`0a3da365`. Final journal audit: two completed proposals, four completed
checkpoint barriers, no pending/faulted work. Games and companions cleaned up.
Source fingerprint: `d9525b9a5521dfb84df17774241559bbbab7def8e84bdb3789f030d6d5af8068`.

`localhost-ui-20260906-001158-d5213a` failed earlier at native Load Game page
startup and was cleaned up. It is not counted as station-fix verification.

`localhost-ui-20260906-001906-6f4a77`: real free rail-depot placement passed
bilateral native existence, owner, exclusive company charge and checkpoint.
Physical selection opened the native vehicle manager (screenshot retained).
The subsequent inspection cases checked unchanged worlds, not a purchase.

### 2026-09-06: native buildings and Buy verified

`localhost-ui-20260906-022618-0a0569`: PASS all seven cases in
`buildings-and-buy.json`, 138.12 seconds of UI tests. P1 built a rail depot;
P2 built a bus station, truck station, road depot and tram depot. Native
existence/counts, authored ownership, buyer-only debits and fresh shared
checkpoints passed. P1 opened the depot, double-clicked the Roter Pfeil in the
native catalogue, then clicked Buy. One vehicle existed on each peer; only P1
was charged ($2,030,442). Shared boundary 28, native digest `366ea2a7`.
Final journal audit: five proposals and one operation complete, eight checkpoint
barriers complete, no pending/faulted work. Exact games/companions cleaned up.
Source fingerprint: `400037787a44e1ba1fbcd9b1b8b6984e47f111477dfed09ceca0f9d3064252ec`.

The previous `021625-8af9fa` run passed all five constructions and depot opening
but the Buy recipe only selected vehicle details, leaving an empty order and
disabled Buy. No purchase command occurred. This was a recipe-calibration
failure, not a product purchase regression. Explicit physical double-click
support was added and unit-tested; the native command factory was not bypassed.

The catalogue's displayed estimate ($2,030,805) differed slightly from the
final debit. This test asserts who pays and a positive charge, not exact UI
price parity. Connected depot exits, assignment and operation remain separate
unproven UI cases. Several fresh attempts also failed at the native Load Game
page or safe pointer-settling checks, before gameplay. Their failed evidence
is retained and is not silently counted as passing startup coverage.

Full offline `tools/run_tests.ps1` passed at 02:13 (259 Python tests, all Lua/
PowerShell gates and cross-language replays); the later explicit double-click
test brings the focused harness unit suite to 22 passing tests.

The 44-label required matrix is a release acceptance target, not 44 completed
GUI tests. The runs above prove the specified toolbar/station/building/Buy
cases only. Remaining variants and operating lifecycles still need calibrated
recipes and successful real-UI evidence. Existing native replay tests must not
be relabelled as that proof.

Live evidence is retained under `runtime/localhost-live/localhost-ui-*`.
Earlier failed harness launches are intentionally not counted as gameplay
passes, even where both games bootstrapped and checkpoints converged.

## Later track sweep (2026-09-06)

`localhost-ui-20260906-024148-1395d2` passed real P1 free-track confirmation,
then correctly failed P2 public-road crossing: both native builders rejected
the ordered command, no track appeared and no money changed. This remains
an open replay defect; see [the retained incident](REAL_UI_TRACK_CROSSING_REJECTION_2026-09-06.md).
The suite must stay red for that crossing until physical completion is proven.

Harness hardening adds prompt rejection detection without mislabelling it a
session fault, mandatory native change/new checkpoint for `changed`, and
fail-closed handling of incomplete GUI trees for text/absence assertions.
The focused Python harness suite now has 27 passing tests; Lua tests also
exercise observer option projection and both UI traversal limits.

## Final repeated construction/Buy proof

`localhost-ui-20260906-025700-0e68ef` passed all seven cases again, in 138.09
seconds of UI execution. Source fingerprint:
`f143cda22fc24ff36a1bec92aa30510417280e8cbdbbf1ab4d2cc434440425be`.
One native vehicle on each peer, buyer-only debit $2,030,442, common boundary
28, native fingerprint `563ba353`. Audit: 15 commits converged, five proposals
complete, one operation complete, eight checkpoint barriers complete, zero
rejected/faulted/pending. Games/companions closed and temporary settings restored.

This repeated pass does not clear the separate red track-crossing recipe or
complete the 44-label UI acceptance matrix.

The final full offline gate completed successfully at 03:06 local on
2026-09-06, including all 27 focused harness tests, the Lua/PowerShell checks,
documentation integrity and the 1,024-event cross-language replay. Log:
`runtime/live-ui-final-static-20260906.log`. `git diff --check` also passed.
The full UI coverage gate was separately exercised and correctly refused the
seven-case report because the remaining required labels are missing; it did
not reject the source fingerprint. No release or commit was made in this task.
