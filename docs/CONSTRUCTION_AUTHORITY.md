# Construction authority

This document is the maintained contract for synchronized construction in
TPF2MP. It describes the `0.44.0-alpha` construction architecture and applies
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
| Early native capture | Native hook | Pointer-free native topology captured at `make_cmd::BuildProposal`, or synchronously at `CommandList::Add` when a stock path bypasses that factory; an identity-bound decoder limitation may retain the exact GUI-semantic path |
| Command correlation | Native hook | The exact command/data identity reaches `CommandList::Add` and the suppressed tag-15 visitor |
| Canonical prepare | Engine Lua and companion | Portable IDs, access, cost, resources, and schemas validate without mutation |
| Physical replay | Both game processes | The ordered proposal produces the expected local geometry and construction outputs |
| Commit | Companion and engine Lua | Ownership, finance, native fingerprints, and canonical checkpoint agree |

Missing command identity, ambiguous correlation, FIFO loss, and contradictory
evidence fail closed. A bounded decoder that explicitly reports an unsupported
optional native sub-layout does not disable the builder family: the exact
generation-bound GUI payload remains eligible for the previously proven
canonical path.

Native evidence is monotonic across the GUI lifecycle. In particular,
Transport Fever 2 may publish the suppressed native command before its later
`builder.apply` callback, or in the opposite order. The shared exact-upgrade
transition reattaches the retained factory/Add capture in either ordering; an
exact GUI envelope may add semantic detail but may never replace an
already-native-attested topology with weaker GUI-only data. A genuine
native/exact disagreement keeps the original command suppressed and rejects
the click before canonical submission.

## Hybrid pre-mutation capture

Hook `0.20.0` detours three exact Build 35924 boundaries:

1. `make_cmd::BuildProposal` preferably decodes the proposal at factory entry,
   before the command can enter the queue or mutate the simulation.
2. `CommandList::Add` associates that decoded proposal with the concrete
   native command pointer. If a stock path constructed tag-15 command data
   without visiting the named factory, Add decodes that same layout
   synchronously before calling the original queue function.
3. `BuildProposalVisitor` promotes only the matching suppressed command-data
   pointer into the Lua-readable capture FIFO.

The native decoder independently captures node positions and flags, edge
endpoints and tangents, carrier/resource indices, ownership scalars, additions
and removals, edge-object entity lists, frozen-node indices, segment tags,
construction resource names and transforms, construction frozen nodes, thread
IDs, caller RVAs, and caller classification. Factory options are attested only
when the factory path was observed; the Add fallback labels them unavailable
and retains the correlated envelope's replay policy. No native pointer crosses
into Lua or onto the network.

The native proposal layout does not expose every semantic value through the
currently pinned scalar/vector offsets. The correlated GUI projection remains
the source for construction parameter trees, edge-object model/flag semantics,
quoted cost, and remaining terrain/alignment semantics. Native topology and
construction transforms replace their GUI counterparts; an explicit topology
envelope prevents recursive lookup from selecting a stale shallow preview.
Construction-resource disagreement and incompatible vector cardinality are
rejected, while sparse segment tags and opaque edge-object record scalars are
not mistaken for one-to-one entity arrays. This is therefore a
hybrid capture with an independently native-attested geometric core, not a
claim that every terrain or parameter byte is decoded twice.

Construction removals are also hybrid. Some builders expose collateral town
buildings only in the exact GUI callback, while others expose them only in the
pre-mutation native vector. The runtime validates existing entity identities,
deduplicates the two correlation-bound lists, and carries their union into one
atomic topology/construction transaction. Empty native collateral is therefore
not interpreted as evidence that an exact GUI removal should be erased;
malformed, temporary, or contradictory identities still reject the click.

When the decoder cannot validate one of those bounded vectors, the native
record still has to carry its Add/visitor correlation and generation. The
runtime records the decoder limitation and uses the exact correlated GUI
payload; malformed JSON, missing identity, replayed generations, queue loss,
or correlation mismatch remain fatal authority failures. This distinction is
what keeps data-driven stock/mod builders usable without weakening ordering.

Captures are bounded FIFOs. Multiple commands sharing one correlation token
remain ordered rather than overwriting one another. Retired authorized replay
captures and evicted never-added early observations are diagnostic lifecycle
events; only loss from the ready evidence queue is a sticky authority fault.
For compound construction batches, the pending transaction retains the latest
successfully attached capture rather than accidentally reverting to the first
subcommand when the exact callback arrives.

The disposable stock-GUI run
`runtime/supported-api-probe/20260904-203543` physically selected and placed a
vanilla signal. Build 35924 used the preferred factory path: the hook captured
one edge removal/re-addition plus one edge object, correlated identical native
thread/command evidence through Add and the suppressed visitor, exposed a
pointer-free generation to Lua, and drained both queues with no invalid,
missed, or dropped ready capture. The Add-only branch remains unit-tested as a
defensive path for other stock callers.

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
portable fingerprint can be captured remains deliberately non-rebindable; its
`proposalDigest:kind:slot` ordering token is never treated as a native-world
fingerprint. Stored owner context (including an intentionally public/no-owner
identity) is also pinned while matching, so a later proposal actor cannot
silently change the descriptor being searched for.

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
exercise two-world replay and the physical postconditions. The final electric
tram slice proves two terminals, an electric route with curb stops, a connected
depot, line creation, Typ1 purchase, and assignment in both native worlds.

The exact populated-world compound road-depot fixture also has a two-process
live receipt. It demolishes a house, splits a public road, constructs the depot,
coalesces the helper entrance with the nearby split junction instead of creating
an invalid 2.58-metre residue, and verifies matching ownership, finance,
physical outputs, checkpoints, core digest, and structural digest. This proof is
specific to the bounded one-entrance depot topology; it does not claim support
for arbitrary multi-entrance scripted constructions.

The GUI regression suite also exercises both real callback interleavings for
the native evidence handoff. Its public-road crossing fixture deliberately
omits the GUI default `tramTrackType` while the captured native edge supplies
zero, proving that the preview-to-exact transition cannot silently discard the
native topology. The same state-machine test is parameterized across street,
track, mixed-transport, edge-object, and construction families.

Use `tools/run_construction_corpus.ps1` for the declared corpus and
`tools/run_tests.ps1` for the complete offline gate. Native changes additionally
require `tools/build_native_hook.ps1`. New live evidence must use a disposable
save and leave no game or companion process running afterward.

## Compatibility boundary

Data-only content can participate when both peers attest the same resources
and its proposal reduces to the bounded portable schema. An unknown optional
native sub-layout may use the exact correlated semantic fallback, but arbitrary
executable callbacks, opaque userdata parameters that cannot be projected,
separately issued `ReplaceTerrain` commands, and ambiguous topology remain
unsupported.
Adding a command or construction family requires updating the safety registry,
codec, replay, ownership/finance rules, physical postconditions, corpus, and
cross-language tests together.
