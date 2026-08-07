# Clock indicator projection and native pause fence

Date: 2026-08-06 (Europe/Amsterdam)

Implementation status: the immediate pause fence and speed-indicator repair are
human-live-proven. The same run exposed a pre-acknowledgement Esc edge case;
its connected-quiescent correction is implemented and automated but requires a
fresh companion restart for live acceptance.

## Live trigger and preserved state

Session `second-train-human-state22-20260806-1200` ran two assigned passenger
trains at UI Speed 3.  The station barrier correctly held Player 1 while
Player 2 spent a long interval behind an Escape pause, and both native copies
ultimately released at game time `1418.4`.  The host nevertheless recorded a
maximum station-round latency of `43,625 ms`.

The clock trace explains the delay.  A single native pause first flowed through
the generic adaptive governor: generations 13-16 capped and recovered speed,
17-18 used missing-time failsafes, and generation 19 finally armed an absolute
skew rendezvous after the gap had reached `25.6` game-time units.  Later player
speed requests recovered the worlds.  The safety invariant held, but the
control path was needlessly indirect.

The visual symptom was independent.  Player 1 sometimes showed Pause and
Speed 3 selected together, or briefly showed no selected speed, while the game
continued.  These were stale stock ToggleButton states during ordered native
speed changes, not evidence of two simultaneous engine speeds.

The populated world was saved as
`tpf2mp_two_train_soak_20260806_1219.sav`.  Its verified recovery archive is
under the local session recovery directory with manifest SHA-256
`0411e94596e7eeafc37918a3d82914c127135f324bb36f97d706cbf38b774480`;
the source-tree recovery plan is
`runtime/localhost-live/second-train-human-state22-20260806-1200/two-train-recovery-plan.json`.

The save dialog itself later held Player 1 long enough to produce a separate
clock acknowledgement timeout and vehicle barrier timeout.  That post-save
fault is useful negative evidence, but it is not part of the earlier valid
two-train result and must not be represented as a passing soak endpoint.

## Exact Build 35924 GUI evidence

The stock `menu.gameSpeed` component contains exactly four
`Clock::SpeedButton` children:

- `menu.speedButton0`: Pause;
- `menu.speedButton1`: native speed 1;
- `menu.speedButton2`: native speed 2;
- `menu.speedButton3`: UI Speed 3, native speed 4.

Each is a `sol.UI::ToggleButton*` with `isSelected()` and
`setSelected(value, emit)`.  There is no fifth stock Speed 4 button.  Native
speed 3 remains useful as an adaptive intermediate cap but projects onto the
same fastest stock button as native speed 4.

## Implemented correction

`network_speed_indicator.lua` now projects the ordered
`world.networkClock.effectiveSpeed` onto those four stock buttons every GUI
frame.  It explicitly selects exactly one button with `emit=false`, so a
repair cannot become a synthetic player request.  A stock Pause selection
observed while authority is still running also schedules an immediate paused
snapshot wake before the projection clears the optimistic widget state.

The prototype window now exposes only Pause and UI Speeds 1-3; its Speed 3
button requests native speed 4.  Native 3 remains valid on the wire for the
adaptive governor.

The GUI bridge no longer treats `requestedSpeed == capturedSpeed` as a complete
duplicate when `effectiveSpeed` differs.  In particular, authority may retain
requested speed 4 while a safety fence temporarily applies effective speed 0;
the next captured request for 4 is the resume signal that must start catch-up.

The host now recognizes a fresh same-generation heartbeat with observed native
speed 0 while ordered effective speed is nonzero.  With no clock control already
in flight it immediately emits `native-peer-pause-fence:<peer>` at effective
speed 0, preserving both the requested speed and the pre-pause release speed.
It does not wait for the generic 3/6/9-second adaptive thresholds.

The fence deliberately remains paused while the native modal pause is open.
A visitor-gated resume becomes the ordinary ordered `clock.request`; a direct
native resume that bypasses the visitor is detected from post-fence telemetry.
Either route arms one speed-1 rendezvous at the current leading game time.  The
leader immediately re-pauses, the lagging world catches up, and only an
all-peer reach releases the saved running speed.

## Automated proof added

- dual-selected and blank stock speed bars are repaired to exactly one button;
- repairs pass `emit=false`;
- native speeds 3 and 4 both map to the fastest stock button;
- standalone UI remains untouched;
- a same-requested-speed capture at effective speed 0 is forwarded as a resume;
- a unilateral same-generation native pause fences immediately even when the
  generic adaptive delay has not elapsed;
- the fence remains stopped while both peers report paused;
- a direct post-fence native resume starts one speed-1 catch-up at the leading
  time and retains release speed 4.

`tools/run_tests.ps1` passes in full after the connected-quiescent correction:
56 Lua core tests, 73 cross-language economy parity vectors, all Lua
integration/runtime suites, syntax and source boundaries, launcher/native-save
tooling checks, and 68 Python tests.

## Immediate-fence live acceptance

Use a fresh/recovered two-process session built from the new source.  At UI
Speed 3, press Escape on the non-host peer for at least 30 seconds, then close
it without manually stepping through speeds.  The acceptance conditions are:

1. the other game pauses after the first paused heartbeat rather than after an
   adaptive cap/failsafe chain;
2. each stock speed bar always shows exactly one selected button;
3. closing Escape produces one catch-up rendezvous and restores UI Speed 3;
4. catch-up starts from a much smaller skew than `25.6` and the affected train
   round is materially below `43,625 ms`;
5. both trains continue through at least two more station rounds with no clock,
   vehicle, lifecycle, or session fault.

The later connected-quiescent run below validates the deadline and recovery
edge case, not every latency target in this earlier list. In particular, its
Escape input landed while a running-speed control was already awaiting an ACK,
so the host could not take the direct same-generation pause-fence path.

## Long real-world pause correction

The post-save fault exposed a second issue independent of the native pause
fence. A station round used a fixed 180-second monotonic deadline. Even after
both games had accepted a legitimate shared pause, that wall-clock deadline
kept advancing. Leaving Escape, Save, or another modal pause open for more than
three minutes could therefore fault a correctly stopped train as
`vehicle-sync-timeout`.

The companion now distinguishes three states: an ordered pause, a strictly
all-peer-acknowledged pause, and a timeout-protected pause. Strict
acknowledgement still requires every required peer to accept the same
`clock.set` control. It remains protected while a resume is pending, and
timeout budget resumes only after every peer acknowledges the
latest-generation running control.

Session `long-pause-deadline-baseline-20260806-1346` showed why protection
cannot depend exclusively on the strict acknowledgement. Player 2 emitted its
last valid running heartbeat at outbox sequence `631`, then entering Escape
stopped the game-script update loop entirely. The host ordered the shared
pause and Player 1 acknowledged it, but Player 2 could neither consume nor
acknowledge that commit while the modal was open. The pre-correction companion
safely paused Player 1 but repeatedly expired and replaced the unacknowledged
pause control. There was no session or vehicle fault in the captured interval,
but this command churn could leave resume unnecessarily difficult.

For that exact condition, a pending zero-speed control becomes
`connected-quiescent-modal` protection when all of the following are true:

- at least one required peer positively acknowledged the control;
- each missing game had a recent valid health sample when the pause was
  ordered and has since gone quiet;
- each missing peer's TCP companion is still connected; and
- no peer sent a negative acknowledgement.

This freezes pending station deadlines and exempts that one pause control from
clock-ack expiry, but deliberately leaves `pauseAcknowledged=false`. When the
modal closes, the game consumes the already-pending pause commit and the mode
upgrades to `acknowledged`; the later all-peer running acknowledgement ends the
same uninterrupted protected interval. A disconnected companion, a stale
uncorroborated peer, or a negative acknowledgement gets no such protection and
retains normal fail-closed timeout behavior. A game process frozen while its
companion remains connected is observationally identical to a long modal; the
chosen failure mode is therefore an honest, visible, safely paused stall rather
than continued simulation or a false acknowledgement.

Each pending round records its own paused interval. On resume its deadline is
extended by exactly that interval, so the train retains the active-time budget
it had before the pause. Barrier latency statistics subtract acknowledged
paused duration rather than reporting a five-minute lunch break as network
latency. New rounds created while paused inherit the same treatment. Public
companion status exposes `pauseAcknowledged`,
`pauseAcknowledgedGeneration`, `pauseProtected`, `pauseProtectionMode`,
`pauseQuiescentPeers`, `timeoutPaused`, and `timeoutPausedRounds` for live
diagnosis.

Acknowledgement state is generation-ordered. If a newer safety pause completes
while an older resume control is still in flight, late acknowledgements for the
older generation cannot reopen deadlines.

Automated coverage advances a fake monotonic clock through a 400-second pause,
holds it for another 50 seconds with resume acknowledgements outstanding, and
then proves expiry occurs only after the original remaining active budget. It
also proves the connected-quiescent transition, suppression of repeated
clock-timeout pause commits, seamless upgrade to strict acknowledgement,
deadline accounting across the whole interval, denial of protection to a
disconnected peer, stale-generation ordering, and pause-adjusted latency.

## Connected-quiescent live acceptance

Session `modal-pause-protection-20260806-1416` loaded the known-good populated
single-train baseline into exact PIDs `36024` and `45868`; both peers agreed
checkpoint 1 before play. At requested native speed 4/UI Speed 3, Player 2
entered Escape while one station round and an adaptive running-speed control
were in flight.

The live status then showed:

- effective speed `0` on Player 1;
- strict `pauseAcknowledged=false`;
- `pauseProtected=true` with mode `connected-quiescent-modal` and quiescent
  peer `player2`;
- one `waiting-arrivals` station round with `timeoutPaused=true`; and
- zero vehicle faults and no session fault.

Across a further 12-second observation, `nextCommitSeq` remained `8`,
generation remained `5`, and the same pause commit remained pending. This is
the direct live proof that the new mode suppresses the old repeated
clock-timeout pause churn.

After Escape closed, Player 2 consumed the pending controls. A speed-1
rendezvous reduced approximately `30.0` game-time units of skew to zero, the
held station round released, and the governor automatically recovered through
effective speeds 1, 2, 3, and 4. At `14:23:49` both peers were back at requested
and effective native speed 4 with about `0.37` skew; the following sample was
about `0.13`. Four station releases had completed, no round remained pending,
and vehicle/session faults were still zero.

This run also defines two bounded polish items. Because the modal began during
an already in-flight running control, the host first recorded a recoverable
`clock-ack-timeout:player2` and the timeout-derived pause did not retain a
direct release speed. Recovery therefore took the safe multi-step path rather
than the immediate fence's one-rendezvous path. The recovered timeout also
remained in the public `lastError` field. Source now clears that warning only
after fresh healthy telemetry reaches the retained requested speed; the audit
still preserves the historical timeout. Promoting in-flight running-control
quiescence into a pre-timeout pause fence remains optional latency polish, not
a correctness gate.

## Adjacent-generation skew correction (2026-08-07)

The coordinated-restore gameplay proof exposed a different source of command
churn. Raw health showed the two worlds repeatedly at the same game time (or
within 0.4), yet seven `absolute-skew-rendezvous` rounds were ordered with
reported spans from 2.4 to 3.2. The audit makes the ordering window explicit:
for example, Player 2 reported generation 8 running at `3124.8` while Player
1's latest retained sample still described generation 7 paused at `3122.2`.
Player 1's generation-8 `3124.8` sample arrived immediately after the false
order. The same shape repeated after every resulting release.

Health reports are asynchronous, so samples from adjacent authority
generations are not a meaningful clock-skew pair. The host now maintains two
values: `projectedGameTimeSkew` remains a raw diagnostic, while actionable
`gameTimeSkew` is populated only when every required peer has a fresh sample
for the host's current clock generation. Station release and adaptive
correction consume only the actionable value. Missing or stale samples still
flow through the existing fail-closed health governor; this change cannot hide
a peer that genuinely stops reporting.

Automated coverage reproduces the live generation-8/generation-7 transition,
asserts that its projected span exceeds the two-second threshold without
emitting a control, then advances the second sample to generation 8 and proves
zero actionable skew. The existing same-generation staggered-heartbeat and
real three-second-skew tests continue to pass.

Live re-acceptance passed in the exact-build restored session archived at
`runtime/manual-network-evidence/anchor-button-20260806-2211-r6-20260807-001633`.
After the requested resume, 35 seconds of service produced no absolute-skew
control at all. The only clock actions were generations 1/2 for requested
resume and generations 3/4 for requested pause. Comparable actionable skew
fell from approximately `0.127` to `0.031`; four station barriers released;
the final pause reached acknowledged generation 4 with zero pending rounds,
no companion error, and no session fault. Audit replay passed, and both game
processes were removed after evidence capture.
