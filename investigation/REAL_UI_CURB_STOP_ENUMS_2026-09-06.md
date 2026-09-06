# Opposite-side curb stop regression caught by real UI, 2026-09-06

Run: `localhost-ui-20260906-081329-f5a461`.

P1 placed a road depot snapped to a public road, then a bus stop on the left
side. Both existed and were owned/charged correctly on both peers. A second
bus stop on the opposite side was rejected without mutation. The run is FAIL;
the unused depot/catalogue follow-up was not executed. Both games/companions
closed and all cleanup flags passed.

## Exact cause

The airfield object-identity guard added during this work compared two different
native enums. The new real UI capture has `edgeObjectsToAdd[1].category = 0`,
`left = false`, and `BASE_EDGE.objects[1] = {-1, 1}`. The reference value is
STOP_RIGHT, not a cargo/model category. The first, left-side stop had reference
0, so the incorrect equality happened to pass there.

The official [EdgeObjectType documentation](https://wiki.transportfever2.com/api/modules/api.type.html#enum.EdgeObjectType)
defines STOP_LEFT=0, STOP_RIGHT=1 and SIGNAL=2. The recorded processed passenger
stop category remains 0 on both sides. This was a regression in the new guard,
not a failed relay delivery or a stale preview.

`edge_object_reference.lua` now checks stop side separately from processed
category, while model identity and carrier-edge identity remain independently
checked. Both normalization and exact generated-construction verification use
the same helper. No safety rejection was globally disabled.

## Evidence and tests

- Raw snapshot: `tests/fixtures/live-ui/bus-stop-right-side.json`.
- `tests/run_curb_stop_capture_tests.lua` preserves the captured mismatch and
  exercises side/category/carrier negatives. It supplies parameter 0.5 only in
  a copied unit-test input: the original capture lacks existing-node positions.
  This is not a substitute for the fresh native UI replay.
- Strict processed-userdata replay tests cover a right-side stop and still
  reject changed model, side and topology; the airfield fixture remains tested.
- The full native inventory bug from the previous calibration is live-proven
  fixed: the left-side stop increases edge-object and station inventory on
  both peers, using schema 3, with a P1-only $900 debit.
- A harness bug also surfaced: rejection counters live under
  `snapshot.probes.capture`, not `snapshot.capture`. The oracle and fixtures
  now use the actual shape; missing counters fail closed. The original run
  failed on timeout rather than detecting the rejection promptly.

Fresh run `localhost-ui-20260906-083315-2c5647` has now passed both physical
bus-stop placements, including the exact opposite-side failure, and opened the
connected road depot's native catalogue. Vehicle/route calibration is ongoing;
this does not yet qualify the complete road lifecycle.

The intervening run `082957-ae20b0` was INFRA_BLOCKED before gameplay by the
intermittent native Load Game page stall. Its dump and cleanup are retained.

## Diagnostic correction

At launch I initially misread mixed PowerShell table formatting and recent
native crash-report files as both processes having exited. Explicit JSON
process inspection disproved that: both exact PIDs remained responsive and
finished initialization. No startup failure is claimed for this run. Its
actual failure was the later rejected right-side stop.
