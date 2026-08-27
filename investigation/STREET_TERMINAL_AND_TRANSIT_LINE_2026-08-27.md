# Street-terminal placement and transit-line identity

Date: 2026-08-27  
Observed release: `0.41.3-alpha`, state schema `33`.  
Implementation state: `0.41.4-alpha`, state schema `34`.

## Live failure evidence

Relay session `mp-1e828bfc275b79a6` exposed two independent failures during
ordinary bus construction.

Large bus/tram and truck terminal clicks were repeatedly discarded with
`construction-rejected-while-busy`. The GUI invalidated its exact native
correlation whenever any proposal, operation, checkpoint, or clock rendezvous
was still settling. This avoided delayed duplicate stations, but it also lost
the legitimate current click. The failure was scheduling policy rather than a
terminal codec rejection; the live log contains no terminal-specific codec
error for those attempts.

The stock Line Manager then created a bus line successfully at native/ordered
sequence 232. Its immediate stop updates were deferred behind that create and
failed at tick 10985 with:

`origin-applied-capture-rejected:selected pre-existing object is ambiguous across peers`

The line was already event-bound. The ambiguous objects were its curbside stop
station groups.

## One vanilla resource, not separate special cases

Build 35924's `construction.zip` confirms that passenger bus stations,
passenger tram stations, and truck stations all use:

`station/street/modular_terminal.con`

The same data-driven construction selects:

- passenger templates 0-2 and cargo templates 3-5;
- 0-3 left platforms and 0-3 right platforms;
- 10 m, 20 m, and 30 m length indices for both era parameter families;
- no tram, tram without catenary, and electrified tram modes; and
- arbitrary generated platform/entrance module maps.

The existing schema-7 portable-construction format already preserves the
resource name, full transform, plain parameters, generated modules, terrain
shape, attached road topology, and up to 64 collateral construction removals.
No bus-, tram-, cargo-, era-, size-, or mod-resource allow-list was added.

Automated Lua and Python matrices now validate 216 combined vanilla parameter
variants, including an atomic seven-house demolition. This protects the
generic contract used by future data-only modded terminal resources as well.

## Latest-only construction lane

Construction input made while ordered physical work is busy now enters one
bounded latest-only lane:

- the first exact click waits behind earlier physical work;
- another construction click replaces that pending construction and moves the
  replacement to the physical FIFO tail;
- unrelated operations retain their original order;
- at most one delayed construction can exist; and
- a full 32-entry queue rejects explicitly instead of overflowing.

The native visitor still suppresses every origin mutation until its exact
canonical action is ordered. This recovers legitimate terminal placement
without reintroducing the historical ghost-station backlog from queueing every
hover/click snapshot.

## Derived station/group identity

A normal roadside bus/tram stop is encoded in a schema-5 BuildProposal as a
category-0/1 edge object. Build 35924 additionally creates native `STATION` and
`STATION_GROUP` entities that are absent from that portable topology payload.
Previously those derived entities were never captured. The first line edit
therefore discovered them lazily as non-manifest `station_group:pre:*`
identities and correctly failed closed as cross-peer ambiguous.

Schema-5 transit-stop replay now takes an expanded before/after component
attestation and binds its derived station and station-group outputs to the
same ordered proposal event. Stop removal similarly retires the derived
identities. Signals and waypoints do not pay this expanded capture cost because
their category is not a transit stop.

This fix is carrier-neutral: the operation line format contains station-group
references, not rail/bus/tram-specific line types. Once the station groups are
event-bound, ordinary bus and tram New Line / Add Station / remove-stop updates
use the same already-proven line operation path.

## Automated proof

- Source boundaries and module size budgets pass.
- The complete 142-case Lua model/codec suite passes, including 216 street
  terminal combinations and collateral demolition.
- Runtime tests cover expanded stop capture, deterministic event binding,
  stop removal, latest-only FIFO replacement, temporal ordering, and capacity.
- GUI tests prove a busy exact station click remains capturable and receives
  the latest-only queue policy.
- Python protocol tests independently admit the same 216 portable terminal
  variants.

## Next live gate

Use a fresh two-peer `0.41.4-alpha` match. Place, on both origins, a passenger
bus/tram terminal and a truck terminal connected to a road while demolishing at
least one house. Exercise asymmetric platform counts, all three lengths, and
tram/catenary choices. Then place two curbside stops and create/edit/delete a
bus line and a tram line through the stock Line Manager. Every action must
appear once on the peer and cross a checkpoint without a session fault.

The already-faulted `0.41.3-alpha` session cannot retroactively acquire the
missing station-group bindings and is not valid acceptance evidence.
