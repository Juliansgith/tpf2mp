# Real in-game regression tests

This is a separate acceptance layer from `run_construction_corpus.ps1`.
The corpus submits prepared actions inside real games. The UI runner instead
uses Windows mouse/keyboard input against the stock game widgets and tools.
It does not construct proposals, call `operation.execute`, invoke a Buy
callback, paste console commands, or repair bindings to make a case pass.

## Current coverage boundary

The runner, observation protocol, bilateral assertions, evidence output and
coverage gate are implemented. `content/live-ui/ui-smoke.json` is the initial
toolbar smoke recipe; it is explicitly **not** station or purchase coverage.
The construction/lifecycle matrix in `content/live-ui/required-coverage.json`
is a list of required proofs, not a claim that those UI recipes have all been
calibrated or executed. Missing coverage fails the separate UI coverage gate.

The entry/observation/input smoke passed on both players in local run
`localhost-ui-20260905-234233-39667c`. The pinned `station-free.json` scenario
also passed both-origin real station placement in
`localhost-ui-20260906-001358-d2a441`, after first reproducing and fixing
stationary-preview expiry at high FPS. Each case waits five seconds over the
ghost, clicks once, and checks native stations, ownership, company debit and a
new shared checkpoint. `depot-catalogue.json` includes real rail-depot building
and native catalogue inspection; inspection alone is not purchase coverage.
`buildings-and-buy.json` passed all seven cases in
`localhost-ui-20260906-022618-0a0569`, and repeated on that harness revision in
`localhost-ui-20260906-025700-0e68ef`: free rail depot, bus station, truck station,
road depot, tram depot, native depot opening, and a native train purchase.
This proves native selection/double-click/Buy, replication, ownership and a
debit exclusively to the buyer; it does not prove a connected depot exit,
assignment, route operation, or exact equality with the UI's price estimate.
Further construction and operational recipes are still being calibrated.
Two physical stock airfields, including their hangars and internal terminals,
passed in `localhost-ui-20260906-045634-7e4671`. This followed fixes for object
identity ordering, preview object-transform rebasing, and the distinct native
processed-object type. Both proposals and four checkpoints completed without
rejection or fault. Aircraft purchase/flight remains a separate requirement.
Extending that test to native hangar selection found a missing NAME component
and reproduced a native crash. Preserving the captured construction name fixed
it: `localhost-ui-20260906-053514-94354e` passed both airfields, hangar NAME
presence on both peers, native hangar/catalogue opening and empty line creation.
See [the airfield incident](../investigation/REAL_UI_AIRFIELD_CAPTURE_2026-09-06.md).
`airfield-purchase-route.json` passed native aircraft buying and two native
line stops in `localhost-ui-20260906-054443-215c7b`. Assignment then passed in
`localhost-ui-20260906-060549-c60537`. Both aircraft completed a flight to the
second airport, but the full journey assertion was blocked by competing
automatic recovery UI input; that isolation bug was corrected. The fixed
`aircraft-native-route.json` subsequently passed all ten cases, both-peer
arrivals at two distinct airfields, final audit and cleanup in
`localhost-ui-20260906-102425-563748`. This does not qualify large airports,
cargo aircraft or other variants absent from the 1940 fixture.
`track-build.json` exposed a failing public-road crossing from P2. After
repairing the raw-versus-processed topology selection, both cases passed in
`localhost-ui-20260906-042819-1a6bfc`: native mutation, ownership, buyer debit
and four completed checkpoint barriers, with no rejected/faulted proposals.
This does not yet prove road/rail traversal across the crossing. See
[the crossing incident](../investigation/REAL_UI_TRACK_CROSSING_REJECTION_2026-09-06.md).
Air/water catalogue discovery passed separately; discovery is not placement
or vehicle-operation proof. Real airfield placement then exposed object-order
and cached-object-transform defects. Keep airport/plane coverage incomplete
until both placement and actual native route operation pass.
Never promote an unexecuted recipe
or a scripted native probe to a UI PASS. Native save-menu startup can still
fail independently of gameplay; those runs stop with retained evidence.

## Running

For the existing-road-node depot regression, use
`content/live-ui/depot-existing-node.json` with its pinned 1940 save. This is
separate from the mid-road split exercised by `bus-native-route.json` and
`tram-native-route.json`. It requires exactly one net native node and edge,
not just a visible depot: a detached building or a residual micro-connector
must fail. The fixed candidate passed on both peers in
`localhost-ui-20260906-165104-29a35a`, including finance, native geometry,
checkpoint, supervisor audit and cleanup. See the
[incident and verification record](../investigation/DEPOT_EXISTING_ROAD_JUNCTION_2026-09-06.md).
This does not expand the claimed coverage to every construction variant.

Use an unlocked interactive Windows desktop, Windows Python with Pillow,
Lua 5.1, Steam and the supported game binary. Close existing games first.
Do not use the mouse/keyboard during an unattended run. No fullscreen or
maximization is requested. The driver verifies exact process and window
identity before input, and fails if it cannot safely activate the window.

From the repository:

```powershell
.\tools\run_live_ui_suite.ps1 -StartingSave 'C:\path\fixture.sav'
```

For a calibrated gameplay suite:

```powershell
.\tools\run_live_ui_suite.ps1 -StartingSave 'C:\path\fixture.sav' -Suite 'C:\path\suite.json'
```

For independent suites in automatically restarted pairs:

```powershell
python tools/run_live_ui_batch.py --save 'C:\path\fixture.sav' --suite content/live-ui/station-free.json --suite content/live-ui/buildings-and-buy.json --suite content/live-ui/track-build.json
```

Every suite is prevalidated before the first launch. The batch retains each
failed attempt and continues in a fresh world only after cleanup is proven.
An absent cleanup receipt stops the batch. Overall success requires every run
to pass on the same source fingerprint; one later success never erases an
earlier failure. Use `--stop-on-failure` to stop after the first failed suite.

To stop after the currently running suite safely finishes, create an empty
`STOP` file in that batch's `runtime/live-ui-batches/<run>/` directory. The
current supervisor still audits and closes its pair; later suites become
`NOT_RUN`, not passing coverage. This is not an immediate keyboard/input pause.

Fixed `bus-native-route.json` and `truck-native-route.json` passed complete
player-input journeys and supervisor audit/cleanup on 2026-09-06, runs
`095548-2b51e4` and `100519-7e87ec`. The truck uses unload stops and drives empty;
its PASS does not claim producer/consumer loading or freight settlement.
`ship-native-route.json` also passed all 14 fixed cases and final audit/cleanup
in `101441-ec3b71`: P2 harbor/shipyard construction, native small passenger ship
Buy, two-stop line, assignment and arrivals independently on both peers.
This is not cargo ship or all harbor-variant qualification.

`tram-native-route.json` is a frozen recipe for the road-connected tram depot,
native road electrification, both curb stops, Halle electric tram purchase,
line assignment and native arrivals. Its complete workflow passed calibration
in `localhost-ui-20260906-110756-a8900d`; a later focus-handoff failure makes
that overall run failed calibration, not current acceptance proof. Require a
fresh passing supervisor receipt for this fixed recipe. That fresh replay
subsequently passed all 20 cases and final audit/cleanup in
`localhost-ui-20260906-113005-ed86b4`, with 48 native movement/arrival samples
on each peer, 38 converged commits and zero rejected or pending physical work.

The current fixture is a 1940 map with the multiplayer mod and the official
legacy-vehicles overlay, not a pure-vanilla content claim. Reports from the
sessions above are historical evidence tied to their source fingerprint, not
qualification of later source edits.

## Matrix to complete

For station variants, `expect.geometry: true` records and compares bounded
physical edge descriptors on both peers. `expect.railLayout` additionally
checks the newly created physical tracks, independently of preview parameters:
`{"axis":[1,0],"tracks":8,"span":160,"tolerance":0.25}`. The axis is a unit
vector in world XY; span/tolerance are metres. This is a straight station-rail
layout oracle, not a general curved-track pathfinding test. It rejects gaps,
overlaps, wrong track counts and wrong lengths even when both worlds agree.
Calibrate each native variant before assigning it coverage; initial observer
tests alone are not native geometry qualification.

Qualify each applicable building family independently: passenger/cargo rail
stations, bus/tram stations, truck stations, rail/road/tram depots, passenger/
cargo airfields and airports, passenger/cargo harbors, and shipyards. Cover
open land, terrain changes, road attachment, house demolition, and combined
road attachment plus demolition; rail buildings also need track attachment.
Harbors and shipyards require valid navigable shore rather than arbitrary
open land. Native-invalid placements are rejection tests, not build tests.

For building variants, cover sizes/platform counts, rotation, era-specific
resources, station modules and upgrades. Separate fixtures must cover long
curves, gradients, bridges, tunnels, road crossings, demolition with roads/
rails, junction bulldozing, signals, waypoints, and bus/tram/truck edge stops.

For each vehicle family, cover depot opening after line creation, native Buy,
single and multi-select assignment, both-peer operation, owner-only editing,
return to depot, replacement/sale, and save/load ownership/finance. Road
carrier alone cannot distinguish a bus from a truck: verify the selected
resource and payload as well. Cargo delivery and passenger feeder economics
need additional model/settlement assertions beyond movement evidence.

These are required scenarios, not a statement that each currently has a
calibrated physical recipe. Never use catalogue enumeration or synthetic
construction corpus counts as completion of this matrix.
Batch reports and separate launcher logs live in `runtime/live-ui-batches/`.
The default runs the full static gate once before game startup. Do not run
the full gate concurrently with games: overlay/install isolation tests require
all game processes closed. Focused pure Lua/Python tests do not have that need.

`-ExtraActiveMod` uses the existing manifest-bound localhost mod activation.
`-SkipStaticGate` skips the slow offline suite, not the mandatory Lua
entry-script/observer preflight, native compatibility checks, or UI assertions.

For recipe discovery only, a suite may set `calibrationIdleSeconds` (10..120).
After its last successful case the same disposable pair briefly waits for the
next numbered case JSON under `ui-suite/followups/` (`0009.json` after eight
cases). The ordinary closed recipe validator still applies; no shell, console,
native callback or custom gameplay injection is available. Write `STOP` there
to end early; inactivity and the overall watchdog also close the pair.
Any gameplay failure terminates the sequence, without retries. The accumulated
recipe is preserved in `suite.json`, but all reports from this mode are marked
`physical-ui-calibration` and cannot satisfy release coverage. Remove the
calibration field, pin the finished recipe and replay it in a fresh pair to
qualify it.

The committed map-coordinate recipes require the reference fixture whose hash
is embedded in each recipe. On this development PC its source is
`runtime/localhost-live/localhost-tram-route-20260904z19--tram-electric-lifecycle-e2e/starting-save/starting-world.sav`.
The native save is not committed or bundled: another test machine must receive
that exact fixture (and matching attested content) as a test artifact. An
arbitrary new map cannot reuse these coordinates. The toolbar-only smoke can
use a different suitable starting save. Run gameplay suites in separate fresh
pairs; simply concatenating their cases can overlap their building footprints.

The supervisor stages a copy of the save, starts two companions and two
windowed games, loads the exact save via native controls, waits for manual
network authority and a common checkpoint, executes the UI suite, then closes
only its recorded games/companions and restores temporary loader/settings
changes. It refuses `KeepGamesOpen` for UI suites. Original saves are not
overwritten. Like the existing live harness, it installs the current development
mod; the prior installation is backed up under `runtime/install-backups`.

## Recipe contract

Each case has explicit `player1`/`player2` steps, bounded waits and an expected
outcome. Selectors match unique visible/enabled UI IDs, exact text or tree paths;
`selected` can assert toggle state. Duplicate matches fail, rather than choosing
an arbitrary control. A button click must be followed by a UI or physical
postcondition; sending input is not evidence of acceptance.

Map clicks/drags and camera setup require `saveSha256` and a calibrated
`viewport: {"w": 1920, "h": 1040}` (use the actual calibration dimensions).
The runner checks the fixture hash before launching and the native viewport
before each case. Coordinates are normalized to the real client
area; selectors use the current GUI rectangle and viewport. Camera setup is
allowed solely to make a fixture reproducible and cannot mutate the world.

Supported input: click, explicit native double-click, move, drag, wheel, allowlisted keys, ordinary label
text, wait-for-control, observation, bounded wait, camera setup. There is no
shell/Lua/console/custom-command escape hatch.

Ground-level targeting also supports `moveGround`, `clickGround`, and
`dragGround`, with a `world: [x,y]` target (`toWorld` for a drag). These require
the pinned fixture/viewport too. The harness physically moves the cursor,
reads the main renderer's terrain position on fresh GUI frames, and converges
within a bounded tolerance/read budget before issuing one mouse press. Every
sample and the final physical input are saved in `ground-input-*.json`.
Missing/stale/nonfinite readbacks or offscreen targets fail without a click.
This is ground-plane targeting, not projection onto elevated bridges/roofs.
Choose a tolerance compatible with the viewport's world-units-per-pixel scale;
the default is 0.15 m and recipes may explicitly allow up to 1 m.

`observe` records the native GUI tree and a screenshot of that peer. The tree
also includes read-only correlation IDs/preview ages, so an expired preview
can be distinguished from a click that never reached the native tool.
It additionally captures the current projected preview when one exists. This
is evidence for calibrating scenarios, not a substitute for checking actual
demolition, terrain or connectivity after construction.

Physical postconditions support:

- exact native object additions/removals by kind and canonical identity;
- new common canonical checkpoint, authored/native fingerprint equality;
- both companies' balances and expected debit/credit/no-charge policy;
- ownership metadata, existence in the native world, explicit field/delta checks;
- unchanged worlds for previews/cancellations/rejections;
- two fresh stable samples, with pending/deferred work rejected.

Journey cases additionally require the specified native carrier, matching line
and vehicle identities, correct owners, and movement followed by arrivals at
two distinct stops independently on both peers. Assignment or changing stop
indices while stationary cannot pass. `checks` can assert collection `length`
to distinguish a real two-stop line from an empty native UI line.

An equal pair where **neither** station built is a failure. Two stations from
one click is a failure. A placeholder CID without a physical object is a
failure. No automatic retry of a failed gameplay click is permitted: save the
failure, stop dependent tests, and start a new disposable pair for a new attempt.

The observer is active only with a per-run capability in `localhost-ui-*`
processes. It accepts bounded, session-bound observation requests under that
peer's bridge. Structural discovery uses private copies of the registry/world,
so observing cannot silently bind or repair the real session. Ordinary games
perform no observer file IO or native test scans.
It also projects the last two already-captured native factory option records;
this is diagnostic evidence, not permission to bypass build validation.

A new failed proposal/operation outcome fails its case promptly once the
bilateral state is settled, even when the session remains healthy. Earlier
rejections must not poison later cases. `changed` requires native mutation
and a newer checkpoint in addition to its explicit checks. Truncated GUI
trees cannot prove that a text label is unique or a control is absent.

Some existing native fingerprints deliberately use attested metadata for unsafe
engine objects. An existence/fingerprint test alone does not prove that a bus
can exit a depot or that a visually aligned station is connected. Those cases
also require the actual native purchase/assignment/route lifecycle, with
explicit postconditions. Keep screenshots for placement/orientation review.

## Results and release gates

Results are under `runtime/localhost-live/localhost-ui-*/`:

- `run-status.json`: launch, authority, cleanup, original evidence paths;
- `ui-suite/report.json`, `junit.xml`, `progress.json`: per-case results/timings;
- per-peer fresh GUI trees/world observations, before/after state, screenshots;
- existing companion/native/game logs collected by the supervisor.

The save-loader input helper also retains before/failure screenshots and
cursor-confinement diagnostics. Native save-menu stalls still occur in some
attempts; do not hide them by counting only the eventual successful launch.
Each physical input/screenshot runs in a bounded 20-second worker. A hung
native window-activation call cannot hold the whole suite indefinitely, and a
possibly issued click is never retried. Timeout stack dumps are local-only
diagnostics; do not upload them automatically as ordinary support logs.
The optional diagnostic dump has its own 10-second process watchdog.

The UI fixture disables periodic companion recovery preparation and the
watcher's stock-UI save fallback. This is an explicit test isolation setting,
not a change to ordinary multiplayer defaults: the recovery helper otherwise
becomes a competing UI driver, can maximize a window, and can type during a
construction test. Save/recovery acceptance remains separate and unqualified
by these construction/vehicle reports. One input owner controls each fixture.

Journey recipes begin observation before switching foreground for screenshots;
keep the final unpause step free of sleeps/screenshots to catch short initial
taxi movements. They retain transient native arrival samples while checkpoints
converge, but still require a healthy, agreed pair to pass. Aircraft/ship
journeys may use a bounded 1,200-second assertion; other cases remain capped at
600 seconds and the whole recipe has a 30-minute watchdog.

`PASS`, `FAIL`, `INFRA_BLOCKED`, `BLOCKED` and `NOT_RUN` are distinct. Only PASS
counts as coverage; the others produce a nonzero result. A launch failure can
occur before `ui-suite` exists; inspect `run-status.json` in that case.

A successful gameplay sequence is provisional. The runner clicks the native
pause button when necessary and waits for both native pause acknowledgements
and the existing ready-boundary checks before cleanup. The supervisor then
finalizes the report/JUnit after replaying the complete audit and checking all
cleanup flags and exact test PIDs. `supervisorVerified: true` is mandatory for
coverage. An inner PASS followed by an unsettled audit is still a failed run.

Terrain cases add an `expect.terrain` assertion with `bounds` (world X/Y min/max),
`grid` (2..9 samples per axis), `minDelta`, `minSamples`, and `tolerance`.
The observer samples native heights only inside this bounded rectangle, before
and after the real click. Both peers must agree at every sampled point, and
the required common points must actually change. Partial/failed native reads
cannot be treated as flat terrain. These cases also require a pinned save and
viewport. A screenshot showing a slope is not terrain-deformation proof.

To require the full matrix before accepting a candidate:

```powershell
python tools/check_live_ui_coverage.py --report 'C:\evidence\ui-suite\report.json'
```

Repeat `--report` to aggregate suites. Reports must be passing physical-UI
results from the current source fingerprint, including dirty source files.
Changing gameplay/harness/recipes invalidates old proof. The ordinary offline
test gate checks the harness itself but cannot substitute for this live gate.
This separate gate is intentionally red until every required recipe is proven.

The expanded `content/live-ui/required-coverage.json` currently names 412
requirements: both origins, 16 building families across free/shore, terrain,
road, house and combined road+house scenarios; rail station size/platform
combinations; and all six vehicle lifecycles. These are **requirements**, not
412 implemented or passing UI tests. See the dated
[qualification matrix](../investigation/TRANSPORT_UI_QUALIFICATION_2026-09-06.md)
for observed results and remaining gaps. A connected-building label requires
usable native vehicle routing, not merely visually aligned placement.

Run game tests on a dedicated licensed Windows desktop, not an ordinary hosted
headless CI worker. Do not expose an unlocked self-hosted desktop or developer
credentials to automatic untrusted pull-request execution.
