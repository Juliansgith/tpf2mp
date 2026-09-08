# TPF2MP prototype status

Current release: `0.44.2-alpha` (experimental testing release)

Last reviewed: 2026-09-09

Supported game: Transport Fever 2 Build 35924, Windows x64

Released protocol identity: state schema `35`, checkpoint format `5`, edge proposal
schema `6`, construction proposal schema `8` (named constructions use `9`), operation schema `4`, passenger
presentation schema `4`, cargo presentation schema `2`, freight-industry state
schema `3`, native hook `0.20.0`.

Native attached-edge-object inventory advances to schema `3`. State schema and
native hook version remain unchanged. Both players must run the same release;
old-save continuation on these latest changes is not fully live-requalified.

This release has targeted real-game evidence, not a complete UI matrix PASS.
Combined demolition/attachment/terrain cases, all construction variants and
fresh save/load/recovery remain incomplete. Intermittent native Load Game
stalls remain unresolved. Back up saves; see the
[release notes](release-notes/RELEASE_NOTES_0.44.2-alpha.md).

The 0.44.2 patch adds metadata validation, recovery-preparation fixes and
opt-in host snapshot takeover. A paired native save/reload/re-save cycle
passed in development; host takeover and moving-vehicle recovery still need
live qualification. See [recovery instructions](HOST_SNAPSHOT_RECOVERY.md).

The preceding 0.44.1 patch fixes depot attachment to an existing public road junction,
with two targeted real two-player UI passes. Broader bus/tram reruns were
blocked before gameplay by the separate native Load Game stall; they are not
current-source passes. See the
[dated incident and verification](../investigation/DEPOT_EXISTING_ROAD_JUNCTION_2026-09-06.md).

## Executive status

TPF2MP is a playable, deliberately restricted two-player alpha for trusted
peers. Two independent Transport Fever 2 processes load the same pinned save,
map local entities to canonical identities, order supported player actions,
replay them in both native worlds, settle canonical finances, and stop if
physical results or checkpoints disagree.

It is not general-purpose or hostile-peer multiplayer. The supported profile
is exactly two Windows players on Build 35924, using identical supported
content, with Player 1 as the ordering host. Secure relay and direct LAN/VPN
transport are available; host migration is not.

The separate local hot-seat mode remains available and uses two persistent
companies through a temporary native turn desk.

## Implemented authority surface

### Session and world authority

- byte-pinned starting-save transfer and independent format-2 match
  fingerprints that attest the save's ordered active mods/DLC, declared
  versions, and installed simulation-bearing content;
- canonical IDs for pre-existing and newly created entities despite divergent
  local native IDs;
- host-ordered intent sequencing, bounded FIFO deferral, reconnect backlog
  replay, acknowledgements, and all-peer checkpoints;
- separate canonical company accounts, ownership, finance reconciliation, and
  rival-edit rejection;
- shared pause/speed control with adaptive slow-peer step-down;
- fail-closed handling for unsupported, ambiguous, or divergent native work.

### Construction

- hybrid pre-mutation BuildProposal capture preferring native
  `make_cmd::BuildProposal`, falling back to synchronous decode before
  `CommandList::Add`, and correlating the exact command through the tag-15
  visitor with the bounded GUI semantic preview;
- one generated safety registry for all 37 native command tags, mechanically
  checked against installed visitors plus operation and proposal codec replay;
- named vanilla and data-only-mod roads, tracks, bridges, tunnels, signals,
  waypoints, edge upgrades, and removals;
- rail, road, tram, air, and water stations/terminals and depots, with isolated
  depot replay established and carrier-connected depot replay structurally
  generalized but still requiring live qualification for every carrier;
- modular construction edits, arbitrary portable constructions and assets,
  collateral demolition, ownership, and physical postconditions;
- public-road crossings and reconstruction, private endpoint authorization,
  issuer-only finance, and immediate cleanup/rebuild;
- explicit inventory coverage for all 52 stock non-building construction
  resources, 35 stock street resources, 2 tracks, 6 bridges, and 3 tunnels.
- unique-only topology/geometry fallback rebinding with read-only discovery and
  transactional rollback of canonical identity, ownership, and custody;
- binding-focused native drift fingerprints after ordered work and periodic
  full structural inventory probes for otherwise unbound residue.

Practical native qualification covers approximately one-kilometre straight and
curved rail, grades, a 900-metre tunnel, town-road crossings, combined building
demolition, long bridges, dense city stations, and a station placed across
116.45 metres of sampled terrain variation. Cursor-dependent extreme compound
previews and arbitrary third-party Lua callbacks remain human/content-specific
tests rather than blanket compatibility promises.

### Lines and vehicles

- line create, delete, rename, recolor, ordered stops, terminals, and bounded
  edits through ordinary stock UI capture;
- portable purchase, assignment, start/stop, reverse, maintenance, immediate
  departure, depot return, replacement, sale, and bounded multi-sale;
- stock rail, road, tram, air, and water vehicle resource families;
- canonical per-station rendezvous that bounds inter-peer route-phase drift;
- deterministic lifecycle finance, capacity, line registration, and cleanup.

Vehicle movement is not continuous coordinate lockstep. Native vehicles move
locally between synchronized station boundaries, so modest mid-leg visual
offset is expected. A different route phase or station index fails closed.

### Competitive simulation

- save-owned difficulty, starting cash, match rules, fares, score, insolvency,
  and deterministic settlement;
- generalized-cost passenger allocation with fare, time, wait, transfer,
  comfort, feeder-access, crowding, and outside-option terms;
- local bus/tram feeders, connecting passenger routes, intermediate transfers,
  exact canonical queues and vehicle loads;
- destination-gated multi-hop freight with production, source stock,
  intermediate inventory, vehicle loads, delivery, conservation, and revenue;
- model-town growth and host-authored physical town development;
- a shared settlement-driven Gregorian calendar projected back into both native
  HUDs, keeping dates and vehicle availability aligned.

Native people, cargo agents, yellow station icons, floating income text, and
native history remain cosmetic where Build 35924 exposes no safe exact-target
write path. Multiplayer panels and adapted stock views show authoritative
model values.

### Recovery, distribution, and diagnostics

- automatic paired recovery boundaries with peer receipts and signed v6 restore
  plans;
- role-specific save archives, tamper checks, fresh post-restore checkpoint,
  and clean-save continuation without resetting canonical money;
- transactional installer, verifier, updater, rollback, stable launcher, and
  complete process/session cleanup;
- outbound-only authenticated TLS relay, automatic save delivery, support IDs,
  and bounded redacted diagnostics without retained save bytes or credentials.

## Strongest current evidence

Development leading to this release passed six fixed real-UI suites: bus,
truck (empty travel only), passenger ship, small passenger aircraft, electric
tram and depot terrain deformation. Journeys observed motion and distinct
arrivals on both peers, and final audits required ownership/finance checks,
converged checkpoints, settled shutdown and exact-process cleanup. Additional
cases covered free stations/depots, train purchase and a rail/public-road
crossing. The full automated rail route is unfinished. These passes belong
to their recorded source fingerprints; final packaging/version changes do not
inherit a current-source all-matrix PASS. See the
[2026-09-06 qualification](../investigation/TRANSPORT_UI_QUALIFICATION_2026-09-06.md).

The following is historical evidence, not all repeated for `0.44.0-alpha`.

The 2026-09-01 qualification completed all fourteen repeatable local gates:

- 604.9 seconds of populated two-process play;
- 1,168 samples, ten converged checkpoints, four synchronized station releases,
  zero vehicle faults, and no pending tail;
- maximum observed world-time skew of 0.315 seconds;
- identical authored/native date progression from `1940-01-02` to
  `1940-05-31`;
- automatic paired recovery capture and successful restore;
- 153 Lua unit tests, 7 transport-network tests, 3 alpha-readiness tests,
  227 Python tests, 215 mod Lua syntax files, 10 investigation Lua syntax files,
  82 PowerShell syntax files, 109 economy vectors, 256 freight stress steps,
  and a 1,024-event replay trace.

See [the consolidated qualification](../investigation/ALPHA_QUALIFICATION_2026-09-01.md),
[construction qualification](../investigation/CONSTRUCTION_EDGE_CASE_QUALIFICATION_2026-09-01.md),
and [practical geometry qualification](../investigation/PRACTICAL_TRACK_AND_STATION_GEOMETRY_2026-09-01.md).

Earlier 2026-09-04 development evidence adds a fully connected two-process electric
tram lifecycle: two terminals, route and curb stops, connected stock depot,
line creation, Typ1 purchase, assignment, ten consensus barriers, twenty
checkpoints, and matching final core/structure digests. The construction corpus
also declares 2,848 static layout/geometry cases; this number describes codec
coverage, not 2,848 live game placements.

Disposable run `runtime/supported-api-probe/20260904-203543` additionally
proves the new earliest-capture chain with a physical stock signal-tool click:
factory decode, Add correlation, visitor suppression, and Lua consumption all
matched generation `1`, with no invalid or dropped capture. This establishes
the exact Build 35924 signal path; terrain-heavy and arbitrary third-party
builders remain separate compatibility claims.

Disposable run
`runtime/localhost-live/localhost-compound-depot-coalesce-20260905-a` proves the
compound connected-road-depot path that previously safety-faulted after leaving
a 2.58-metre residual connector. Both native worlds now demolish the collateral
house, split the public road, coalesce the depot entrance into that junction,
and converge with one complete proposal, zero rejections/faults, matching
finance/ownership, core digest `035ccd29`, and structural digest `9995a4be`.

## Not established

- production readiness or long-term save compatibility guarantees;
- hostile-peer security, anti-cheat, or authority independent of Player 1;
- host migration, spectators, or more than two active companies;
- macOS/Linux native-hook support or any game executable other than Build
  35924;
- arbitrary executable/script-heavy mod compatibility;
- independent native decoding of every construction parameter and terrain
  vector (the correlated GUI semantic capture remains authoritative for those
  fields);
- continuous vehicle-coordinate lockstep or native-agent authority;
- automatic repair after the two physical worlds have already diverged;
- multi-hour, two-physical-computer load and latency certification.

## Release position

`0.44.2-alpha` is an experimental release for external trusted-tester feedback,
not a fully qualified construction or persistence release. The previous
`0.43.5-alpha` release remains available for rollback using backed-up saves.
The next
evidence priority is a multi-hour physical two-computer relay match exercising
dense construction, several simultaneous vehicles, passenger transfers,
positive freight, reconnect, and receipt-bound restore. The machine-checkable
procedure is [the alpha release checklist](ALPHA_RELEASE_CHECKLIST.md); the
post-alpha backlog is [remaining work](REMAINING_FROM_BRIEF.md).
