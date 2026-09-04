# Construction authority

This document is the maintained contract for synchronized construction in
TPF2MP. It describes unreleased development after `0.43.5-alpha` and applies
only to the pinned Windows x64 Transport Fever 2 Build 35924 profile.

The core rule is simple: a local builder preview is never authority. A build
becomes authoritative only after its native command has been captured before
mutation, converted to a portable transaction, ordered by the host, replayed
on both peers, checked against physical postconditions, and included in an
all-peer checkpoint.

## Authority flow

| Stage | Owner | Required result |
|---|---|---|
| Preview | GUI Lua | Bounded semantic projection and correlation token |
| Factory capture | Native hook | Pointer-free native topology captured at `make_cmd::BuildProposal` entry |
| Command correlation | Native hook | The same command reaches `CommandList::Add` and the suppressed tag-15 visitor |
| Canonical prepare | Engine Lua and companion | Portable IDs, access, cost, resources, and schemas validate without mutation |
| Physical replay | Both game processes | The ordered proposal produces the expected local geometry and construction outputs |
| Commit | Companion and engine Lua | Ownership, finance, native fingerprints, and canonical checkpoint agree |

Any missing, ambiguous, overflowing, or contradictory stage fails closed.

## Hybrid pre-mutation capture

Hook `0.20.0` detours three exact Build 35924 boundaries:

1. `make_cmd::BuildProposal` decodes the proposal at factory entry, before the
   command can enter the queue or mutate the simulation.
2. `CommandList::Add` associates that decoded proposal with the concrete
   native command pointer.
3. `BuildProposalVisitor` promotes only the matching suppressed command-data
   pointer into the Lua-readable capture FIFO.

The native decoder independently captures node positions and flags, edge
endpoints and tangents, carrier/resource indices, ownership scalars, additions
and removals, edge-object entity lists, frozen-node indices, segment tags,
construction resource names and transforms, construction frozen nodes,
factory options, thread IDs, caller RVAs, and caller classification. No native
pointer crosses into Lua or onto the network.

The native proposal layout does not expose every semantic value through the
currently pinned scalar/vector offsets. The correlated GUI projection remains
the source for construction parameter trees, edge-object model/flag semantics,
quoted cost, and remaining terrain/alignment semantics. Native topology and
construction transforms replace their GUI counterparts; the merge rejects
resource, entity-order, or vector-count disagreement. This is therefore a
hybrid capture with an independently native-attested geometric core, not a
claim that every terrain or parameter byte is decoded twice.

Captures are bounded FIFOs. Multiple commands sharing one correlation token
remain ordered rather than overwriting one another. Retired authorized replay
captures and evicted never-added factory observations are diagnostic lifecycle
events; only loss from the ready evidence queue is a sticky authority fault.

## One command-safety registry

[`content/native-command-safety-v1.json`](../content/native-command-safety-v1.json)
describes all 37 Build 35924 command tags. Each row records the capture point,
visitor coverage, safe suppression/pass-through behavior, UI result contract,
replay owner, ownership rule, finance rule, and required postconditions.

The generator emits the C++ and Lua views. Native detours use generated policy
constants at compile time, native tests prove visitor/registry coverage in both
directions, Lua tests bind every operation codec and the BuildProposal codec to
their declared replay policy, and the offline gate rejects stale generated
files. The textual ownership, cost, and postcondition names also document the
review contract; not every string is executable dispatch metadata, so runtime
postcondition implementations still require explicit tests.

## Canonical identity and fallback rebinding

Machine-local entity IDs are never sent as durable identities. Canonical IDs
remain primary. When a saved or reconstructed world no longer has the expected
local binding, eligible objects may be recovered using a unique portable
fingerprint assembled from resource identity, transform or endpoint geometry,
tangents, carrier type, logical ownership, and neighbouring topology.

Fallback discovery obeys four rules:

- proposal inspection is read-only;
- zero matches fail closed;
- multiple matches fail closed unless the stored neighbour fingerprint makes
  exactly one candidate unique;
- the actual bind/rebind occurs only inside the accepted proposal transaction,
  with canonical reverse maps, logical ownership, and pinned custody restored
  atomically if finalisation fails.

For exact compound construction results, the GUI callback records portable
ordinary/topology identity for newly created construction, station, group,
depot, and asset outputs while their exact local output delta is known. Some
fresh Build 35924 child components are unsafe to dereference from the engine
Lua state immediately after creation; those children retain their attested
identity and are not probed again merely to recreate it. A child for which no
portable fingerprint can be captured remains deliberately non-rebindable.

## Physical postconditions and drift detection

Construction success requires both peers to report compatible output sets,
portable geometry/construction fingerprints, logical ownership, and finance
deltas before the canonical checkpoint can close.

Drift detection has two levels:

- the frequent cheap fingerprint checks every canonical binding plus logical
  and native ownership, vehicle-line association, and town/industry summaries;
- every tenth scheduled sample escalates to the full structural probe, which
  enumerates whole native inventories and therefore detects extra unbound
  topology that the binding-focused tier cannot see.

Old full-inventory evidence is never carried forward and labelled as a fresh
cheap sample. Category-specific digests distinguish edge, construction,
vehicle, autonomous-world, and other divergence in diagnostics.

## Construction corpus

[`content/construction-corpus-v1.json`](../content/construction-corpus-v1.json)
is the machine-readable compatibility contract. Its static matrices currently
declare 2,848 stock layout combinations, including 2,560 rail-station variants,
and cover long/curved/graded network geometry, bridges, tunnels, crossings,
demolition, station families, depots, signals, waypoints, and extension rules.

Static coverage proves codec normalization, resource inventory, generated
layout consistency, and rejection behavior; it is not a claim that every case
was physically clicked in a live game. Declared localhost slices separately
exercise two-world replay and the physical postconditions. The connected tram
lifecycle is live-proven through two terminals, an electric route connected to
a stock tram depot, two stops, line creation, a Typ1 purchase, assignment,
barrier consensus, and matching final core/structure digests.

Use `tools/run_construction_corpus.ps1` for the declared corpus and
`tools/run_tests.ps1` for the complete offline gate. Native changes additionally
require `tools/build_native_hook.ps1`. New live evidence must use a disposable
save and leave no game or companion process running afterward.

## Compatibility boundary

Data-only content can participate when both peers attest the same resources
and its proposal reduces to the bounded portable schema. Arbitrary executable
callbacks, opaque userdata parameters, unknown native layouts, separately
issued `ReplaceTerrain` commands, and ambiguous topology remain unsupported.
Adding a command or construction family requires updating the safety registry,
codec, replay, ownership/finance rules, physical postconditions, corpus, and
cross-language tests together.
