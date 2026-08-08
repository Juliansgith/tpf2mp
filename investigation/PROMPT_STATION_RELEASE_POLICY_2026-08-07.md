# Prompt station release after registered-service timeout

Date: 2026-08-07 (Europe/Amsterdam)

Implementation: prototype `0.24.0-alpha`, state schema `24`, checkpoint format `4`

## Verdict

The competitive model's headway must not be enforced as a native departure
timetable at every station barrier. Headway remains a deterministic demand,
wait-cost, and service-capacity input. Physical train synchronization now has
one policy for ordinary and registered lines: hold the native copies until the
full peer roster reports the same vehicle, line, stop, and round, then order a
prompt release after the shared-clock network guard.

This deliberately separates two concerns:

- the authored economy estimates how often a service can carry passengers;
- the station barrier prevents either native copy from beginning the next leg
  before the slower copy reaches the same stop.

Native Transport Fever 2 line operation remains responsible for ordinary
loading and vehicle spacing. The barrier does not add a second timetable.

## Live failure that changed the policy

The human two-process session
`line-alt-vector-live-20260807-143109` registered the one-train `Mainline` with
an authored headway of 778 game seconds. Both games used the exact Build 35924
profile and the same canonical vehicle `vehicle:pre:e8c0305d`.

The audit records:

| Round | Stop | P2 arrival | P1 arrival | Ordered release |
|---:|---:|---:|---:|---:|
| 1 | 0 | 56.8 | 56.8 | 223 |
| 2 | 1 | 373.4 | 373.4 | 492 |
| 3 | 0 | 626.8 | 636.8 | 1001 |

The old allocator selected the next congruent `phase + slot * period` time.
Round 3 therefore added 364.2 game seconds after the slower train had already
arrived. Under the observed native frame rate it exceeded the 180-second
active wall-clock round deadline and correctly faulted closed as
`vehicle-sync-timeout:vehicle:pre:e8c0305d:3`.

This was not ordinary station dwell and not network latency. It was a policy
error: a statistical service headway had become a mandatory per-stop clock.

## Ten-second vehicle lead

Round 3 also gives a clean measurement of the reported visual difference. P2
reached the same canonical stop at game-time 626.8; P1 arrived at 636.8, a
10.0-second simulation-time lead. The host's shared-clock skew was only about
0.4 seconds when inspected. Earlier releases were applied at identical game
times on both peers.

The remaining lead is therefore inside native vehicle execution: independent
agent loading, path/physics updates, and frame scheduling can make one copy
finish a leg first even with the same consist and geometry. Exact coordinate
writing is not a supported Build 35924 control. The intended invariant is
station-leg anchoring: the early copy waits, then both copies receive the same
ordered release after the late copy arrives.

## Implementation and compatibility

`corridor_binding.synchronizationSchedule` now always emits the explicit
disabled schedule policy. `departureSchedule` and `departureSlots` remain
available as pure model queries. The existing scheduled-action validator and
checkpoint reader remain intact so older evidence and interrupted historical
commits can still be verified.

A prompt release clears any persisted line/stop reservation on both the host
and game state. New sessions should consequently report zero scheduled
releases and no active slot reservations. The expected extra dwell after the
second arrival is only the adaptive network guard (historically about 1.5-2.4
seconds of wall time on healthy localhost), plus any native loading behavior
that Transport Fever 2 itself retains.

## Passenger display boundary

The stock train window still displays native Transport Fever 2 agents. Its
seat capacity is the real consist capacity, but its occupied-passenger glyph is
not the authoritative competitive count. The exact synchronized allocation is
the passenger section of the Multiplayer window and projected stock total; that
ledger advances at ordered economy settlement and station release boundaries.
Build 35924 exposes no proven target-addressable
command that can safely write those exact authored people into one selected
train or station, so the stock count remains cosmetic rather than silently
misrepresented as authoritative.

## Next live acceptance

Restart both game and companion processes so they load the new policy. Register
the same line, settle at least one economy epoch, and let the train complete
four station rounds. Each early train may wait for its slower peer, but after
both arrivals the release should be prompt; `scheduledReleases` and
`slotReservations` should stay zero, `pendingRounds` should return to zero, and
the session must not fault. Compare the stock native glyph with the Multiplayer
passenger ledger separately rather than expecting them to match.
