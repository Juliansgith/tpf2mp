# Network station proposal schema 4 - Build 35924

Date: 2026-08-03

## Outcome

Schema 4 now implements the stock modular rail-station placement family rather
than one hard-coded station. It covers:

- passenger and cargo;
- through and terminus;
- 80 m, 120 m, 160 m, 240 m, and 320 m;
- 1 through 8 tracks;
- standard and high-speed track;
- catenary off and on.

The 80 m/one-track passenger terminus has completed live two-process physical
and checkpoint consensus. The broader family is derived from the stock resource
and passes Lua/Python protocol tests, but still needs a focused live matrix.
Station module editing, station removal, depots, signals, and non-stock
constructions remain fail-closed.

## Why only the smallest station originally worked

The first codec deliberately admitted one measured proposal: eight passenger
modules and a 13-node/12-edge graph. A follow-up added the second main-building
slot seen in another sample, initially mistaken for a rotation effect.

Live session `lan-station-rotated-live-20260803-1905` resolved the ambiguity:
the slot difference represents through versus terminus layout. Its immediate
codec-failure telemetry also captured these stock variants before mutation:

| Variant observed | Params | Modules | Nodes/edges | Distinguishing facts |
|---|---:|---:|---:|---|
| Cargo through, 80 m, 1 track | `length=0 tracks=0` | 5 | 13/12 | main slot `3400020`, cargo platform slots `6400000/10`, track row `8402000/10` |
| Cargo through, 120 m, 1 track | `length=1 tracks=0` | 7 | 19/18 | main slot `3400000`, three cargo and three track modules |
| Passenger through, 120 m, 1 track | `length=1 tracks=0` | 11 | 19/18 | main slot `3400000`, three platform/track/roof modules plus one access module |
| Passenger terminus, 120 m, 1 track | `length=1 tracks=0` | 11 | 19/18 | main slot `3699980`, terminus-specific roof/access slots |

The same run successfully replayed two 80 m/one-track passenger terminus clicks
and closed their physical/checkpoint barriers. The apparent placement no-op for all
other selections was therefore the intentional old allow-list rejecting valid
stock shapes, not an engine placement or finance failure.

## Authoritative template source

The base resource is readable at:

`res/construction/construction.zip/station/rail/modular_station/modular_station.con`

Its `createTemplateFn` deterministically constructs the module map from the
menu parameters and template kind. Both the Lua codec and Python companion now
port that function's slot/resource rules. They independently regenerate four
candidate maps (passenger/cargo crossed with through/terminus) and accept only
an exact match. This is stricter than accepting a union of known module names:
an omitted, duplicated, moved, wrong-era, wrong-track-type, or wrong-catenary
module fails validation.

Important stock rules reproduced by the codec include:

- UI length indices map to 1, 2, 3, 5, or 7 forty-metre module intervals;
- track-count indices 0-7 map to 1-8 physical track rows;
- building level changes at four and seven tracks;
- passenger and cargo layouts use different platform/track row slot bases;
- terminus and through layouts use different main-building slot formulae;
- long/wide through stations add deterministic side buildings;
- passenger roof/access placement depends on length, terminus state, era, and
  building level;
- standard/high-speed and catenary state select one of four exact track modules.

## Wire and graph rules

A schema-4 transaction is accepted only when it contains:

1. one stock `modular_station.con` addition and no topology/construction
   removal;
2. a bounded finite planar rigid transform;
3. year/seed plus stock menu ranges for length, tracks, track type, and
   catenary;
4. 1-256 sorted unique modules exactly equal to one regenerated stock map;
5. a bounded graph of private track edges using the template's catenary state;
6. exactly one simple open graph path per selected physical track, with no
   external node references;
7. no process-local entity/player IDs, a canonical digest, and the existing
   512 KiB message bound.

Construction proposals may contain up to 1024 nodes and 1024 edges; ordinary
schema-3 proposals retain their 256/256 limits. This covers the largest stock
station while preserving the narrower road/track transaction boundary.

## Replay and physical postcondition

The native player click remains suppressed by the BuildProposal gate. After
host ordering, each peer reconstructs plain metadata for every allow-listed
stock module and calls `game.interface.buildConstruction` on the engine thread.
The GUI path does not issue a second BuildProposal.

Before replay, each peer snapshots construction, station, station-group, depot,
node, and edge component sets. Completion now expects:

- one construction;
- one station;
- one station group;
- zero depots;
- exactly the transaction's variable node and edge counts.

Every node/edge is geometrically matched to its canonical transaction slot.
Private track ownership is verified, all compound outputs are bound to
event-derived canonical IDs, the effective wallet debit is normalized to the
quoted cost, and both peers must agree on physical and checkpoint results before
another intent can commit.

## Automated proof

The post-change suite passes the existing 25 Lua test groups and 31 Python test
groups plus all game-script, network-company, ownership, GUI, hot-seat, replay,
syntax, launcher, native, and recovery integrations. New station vectors cover:

- the original 80 m passenger terminus;
- the 80 m passenger through form in offline protocol/materialization tests;
- live-captured 80 m cargo through placement;
- live-captured 120 m passenger through placement with 19/18 graph;
- a two-track high-speed electrified passenger terminus with two disjoint path
  components;
- wrong module, wrong slot, catenary, digest, and graph tampering rejection.

## Focused live matrix

The next session should vary one dimension at a time instead of trying every
cross-product:

1. passenger through: 80 m/1 track;
2. passenger through: 120 m/1 track;
3. passenger terminus: 160 m/1 track;
4. passenger through: 80 m/2 tracks;
5. passenger terminus: 320 m/8 tracks;
6. cargo through: 80 m/1 track;
7. cargo terminus: 120 m/2 tracks;
8. passenger through: 80 m/1 high-speed track, catenary on.

For each, wait for proposal and checkpoint completion and compare station
appearance plus both balances. Export research/snapshot/checkpoint only after
the matrix or immediately after the first fault; immediate codec telemetry
already preserves rejected proposal diagnostics.
