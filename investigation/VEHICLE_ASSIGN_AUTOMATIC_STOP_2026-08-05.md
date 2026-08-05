# Vehicle assignment automatic-stop sentinel — 2026-08-05

## Live finding

Assigning the newly purchased P1 train to the newly created two-stop P1 line
showed the stock error `unable to find path to stop`. The track connection was
not the cause. The native status for P1 recorded four `SetLine` calls, all four
suppressed, zero captured, and four invalid payloads. Its last error was:

`suppressed SetLine payload did not match the pinned Build 35924 layout`

No `vehicle.assign` operation entered the network, neither world mutated, and
the session remained consensus-clean.

Static inspection of Build 35924 reconfirmed the pinned payload layout. The
visitor at RVA `0x009D5610` reaches the implementation at `0x009D9B10`, which
reads vehicle, line, and stop index as signed 32-bit values at offsets `+0`,
`+4`, and `+8`. The rejected live value was therefore not evidence of another
layout. Stock line assignment uses stop index `-1` as the automatic initial-stop
sentinel; the hook had incorrectly required a non-negative stop index.

## Implemented contract

The complete capture/replay boundary now admits `-1 <= stopIndex < 256` for
`SetLine` / `vehicle.assign` and still rejects `-2` and values at or above 256:

- the Build 35924 native decoder and pinned-profile documentation;
- the GUI `V1` suppressed-vehicle envelope decoder;
- the Lua canonical operation validator and materialiser;
- the Python wire-protocol validator;
- native, GUI, Lua, and Python regression tests.

The `-1` value is deliberately replayed unchanged on both worlds. Each native
simulation chooses its initial stop from identical line topology, and the
existing physical result/checkpoint consensus remains responsible for failing
closed if those results differ.

## Verification completed

- Full Lua suite: 46/46 passed.
- Full Python suite: 46/46 passed.
- Cross-language economy vectors and checkpoint replay: passed.
- GUI, game-script, company-mapping, hot-seat, and long-replay integration:
  passed.
- Native build: passed.
- Native tests: 2/2 passed, including `-1` acceptance and `-2` rejection.
- Build 35924 executable validation: SHA-256 pinned and all 17 signatures
  matched.
- Development mod tree reinstalled after the successful test/build run.

## Live retest still required

The user left before the corrected DLL could be exercised through the stock
vehicle selector. A fresh localhost launch was attempted as session
`vehicle-assign-sentinel30-20260805-1740`; both hooks loaded successfully, but
P2 stayed at the main menu and did not publish launcher stage
`ready-to-click-pinned-save`. The runner failed closed after its 180-second
timeout and both disposable game/companion pairs were closed. This is launcher
startup evidence, not a failure of the assignment codec. See:

`runtime/localhost-live/vehicle-assign-sentinel30-20260805-1740/run-status.json`

Shortest remaining live check:

1. Launch a healthy two-instance session from the route-recovery save.
2. Create a two-stop P1 line and buy one P1 train if the chosen save does not
   already contain them.
3. While paused, assign that train to the line once through the vanilla vehicle
   selector.
4. Require one consumed `SetLine` capture with stop index `-1`, matching
   `vehicle.assign` completion/result digests on both peers, zero invalid
   suppressed vehicle commands, and a converged post-operation checkpoint.
5. Only then unpause through the shared clock and observe the first complete
   route cycle.

