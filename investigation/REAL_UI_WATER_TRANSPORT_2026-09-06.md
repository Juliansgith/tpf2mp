# Water transport native-UI qualification, 2026-09-06

## First shoreline run

`localhost-ui-20260906-064446-9a1f01`, unchanged fixture SHA256
`47fbd37409d999392301a884ef3caa6297c682c58cdfda604b1f89ce79f0f5e3`.
Camera (-1800,-1000), distance 1500, angle 0, pitch .82; 1920x1040 client.

- P2 passenger harbor at (.582,.65): PASS, bilateral physical construction,
  owner company:2, P2-only debit 185925.
- P2 second passenger harbor at (.586,.72): PASS, P2-only debit 198734.
- P2 shipyard at (.596,.68): native placement completed on both peers, but the
  case FAILED because the recipe asked for nonexistent `depotUi.missingNames`
  instead of `missingName`. No acceptance credit: fixed recipe must rerun.
  Actual observation: depot 81527, carrier 4, NAME `Coleford Shipyard` present.
- Audit: valid, 11 commits, 3 complete proposals, 5 complete checkpoint
  barriers, zero rejected/faulted/pending proposals; source/install match.
  Both games/companions closed and all six temporary-state cleanup flags true.

Invalid red shoreline previews were not clicked. The collision-free points
above are separated from the nearby public road. This is not road-connection
or house-demolition proof. Neither shipyard opening nor buying/sailing a ship
was tested in that run.

## Harness corrections before rerun

Native Carrier includes WATER=4, not only ROAD=0 through AIR=3; the journey
schema now admits all five native carriers, with invalid/bool values rejected.
See [native enum reference](https://wiki.transportfever2.com/api/modules/api.type.html#enum.Carrier).
Journey proof pins line identity and stop sequence across the entire test,
and counts distinct destination CIDs, not merely different indices that can
refer to the same station. Regression tests reproduce both false-pass risks.

Current corrected physical recipe: `runtime/live-ui-recipes/water-native-route-calibration.json`.
Calibration reports cannot satisfy the release gate. Export the final fixed
recipe and rerun it before claiming water transport qualification.

## Corrected building/buying run

`localhost-ui-20260906-065803-a3822e`: eight cases passed, including both
harbors, the shipyard's native NAME/ownership/debit, opening its vehicle manager
and Buy Ships catalogue, selecting a small Schaffhausen, purchasing exactly
one replicated ship, and native empty line creation. The ship debit was
1109694, exclusively company:2. Native catalogue estimate was 1109892; the
test currently asserts the correct charged company, not exact estimate parity.

Case nine FAILED with no physical change: the line-manager window covered the
two harbor icons, so the coordinate clicks hit its title/body, not the map.
This is a recipe-layout defect, not a ship line-operation rejection. Audit
remained valid: 13 commits, 3 complete proposals, 2 complete operations, 7
complete barriers, zero rejected/faulted/pending operations. All processes
cleaned and source/install matched. The next recipe moves the native line
window upward by physical title-bar drag before clicking harbor icons.

Native model lists are now observed from transportVehicleConfig using the
existing read-only vehicle postcondition projector. ROAD journey recipes must
pin those model names, so a bus cannot accidentally qualify a truck case.

## Line-window calibration and startup failure retained

`localhost-ui-20260906-071340-27bd67` repeated all eight building/catalogue/
purchase/empty-line cases successfully. The title-bar-drag variant still failed
to add stops. Reviewing the before image shows the map had already changed
after opening the shipyard manager; the old harbor coordinates were invalid
even before the drag. Do not attribute this failure to native line replication.
Next calibration explicitly resets the camera after creating the line, with
the harbors above the native manager. Audit: 13 converged commits, three
completed proposals, two completed operations, seven completed barriers, no
rejected/faulted/pending work; both games and companions cleaned up.

`localhost-ui-20260906-072421-d05014` failed before gameplay: P1's native Load
Game page did not open within 120 seconds. The stack-only dump is retained in
that run's `native-save-load-player1` directory. Several loader threads were
in native table/value conversion work while the main thread waited. This is
not sufficient to identify a root cause; no launcher fix or successful water
test is claimed from that attempt. The partial game and companions were closed.
# Full native sailing journey, 07:37 run

`localhost-ui-20260906-073748-29cfcd` completed the Schaffhausen route through
physical native UI input: two P2 harbors, shipyard, Buy, both native line stops,
assignment, and sailing. Each peer contributed 37 journey observations with
movement and arrivals at both distinct station groups. No injected gameplay
commands were used. The fixed recipe is `content/live-ui/ship-native-route.json`;
it still needs a fresh non-calibration qualification after source changes.

Opening the depot manager had changed the camera. The successful reset after
creating the line was x=-1000, y=-1000, distance=1500, angle=0, pitch=0.82.
Harbor icon clicks were [0.592, 0.195] and [0.595, 0.249] in the pinned viewport.
The selected native model was `vehicle/ship/ds_schaffhausen_v2.mdl` (small ship,
compatible with small harbors), not the first, large Klondike catalogue entry.

The run later FAILED a separate bus-stop oracle: the stop and its owned bindings
existed on both sides, station inventory increased, and only P1 paid $900, but
the SIGNAL_LIST-only edge-object inventory counted zero. This failure is
retained. Both games and companions exited; all six cleanup flags passed.
