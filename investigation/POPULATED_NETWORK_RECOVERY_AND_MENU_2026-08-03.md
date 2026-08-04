# Populated network, recovery, and title-menu proof — 2026-08-03

Prototype: `0.17.0-alpha`  
Game: Transport Fever 2 Build 35924 (Windows x64)  
Executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`  
Mod state/checkpoint/proposal formats: `16 / 2 / 3`

## Outcome

The strongest automated network run now starts two real game processes from
the same populated native save, gives the pre-existing world the same canonical
ownership on both peers, applies one host-origin and one client-origin private
track transaction, reaches physical and checkpoint consensus after both, and
finishes with identical core, model, structure, finance, and mobility domains.

This closes the earlier populated-world identity divergence. It does not prove
that arbitrary vanilla gameplay, live autonomous simulation, or every command
category is synchronized.

## Populated two-process run

Evidence directory:

`runtime/localhost-live/populated-network-ownershipfix-20260803`

Source save:

`autosave_New Game_1992-08-03.sav`

Session:

`populated-network-ownershipfix-20260803`

Observed source-world inventory included:

- 2 towns;
- 5 industries;
- 363 constructions;
- 1 rail depot;
- 1 passenger line with 2 station groups;
- 1 train;
- 413 simulated people.

Final results:

| Domain | Player 1 | Player 2 |
|---|---:|---:|
| Core digest | `7a1b9f9d` | `7a1b9f9d` |
| Model digest | `5b59ecf2` | `5b59ecf2` |
| Structural digest | `07db112f` | `07db112f` |
| Mobility digest | `a7ae06ac` | `a7ae06ac` |
| Status | passed | passed |

The independent host audit reported:

- 5 ordered commits;
- 5 ordered controls;
- 68 telemetry records;
- 5 mobility convergences;
- 2 complete, 0 faulted, 0 pending physical proposals;
- 3 complete, 0 faulted, 0 pending checkpoint barriers;
- 6 peer checkpoint records;
- 34 event records, of which 26 were in the digest chain;
- both pinned peers present.

## What the soak did and did not prove

The final soak was 300 game-script ticks. The native calendar was deliberately
paused at speed 0, and town/industry autonomous development was frozen. The
pre-existing train and passengers were present, but the train was not advancing
during this validator soak. Intermediate finance reconciliation and mobility
samples were taken; this was not merely a start/end file comparison.

The comparison covered core, authored model, canonical structure, canonical
finance, and native mobility aggregates. The structural digest stayed
`07db112f`; both canonical accounts stayed at `4,975,000`; the mobility digest
stayed `a7ae06ac`.

Therefore this is a populated static-authority/convergence proof. It is not a
running-simulation drift proof. A later human test must unpause both peers with
moving services and compare time-series samples while no unsynchronized player
actions occur.

## Pre-existing-world identity fix

The first populated attempt found a real design bug. Each peer treated its own
original native player as the owner of the pre-existing network. The objects and
geometry matched, but the same train network became canonical Company 1 on one
peer and Company 2 on the other.

State schema 16 now seeds shared-save ownership before peer-local company
mapping:

1. the selected source owner becomes canonical `company:1` on every peer;
2. other source owners receive deterministic canonical positions afterward;
3. canonical logical ownership is authoritative;
4. the peer-local native player remains only a realization/binding detail;
5. rival proposal and entity vetoes consult that logical owner in both
   standalone and network mode.

`tests/run_network_company_mapping_tests.lua` now starts player 2 on a native
world locally owned by player 2 and still requires the shared pre-existing track
to resolve to canonical Company 1. The populated two-process run is the live
proof of the same invariant.

## Passenger and cargo observability

The earlier documented convenience readers remained unavailable, but the
populated run invalidated the broader conclusion that passenger state could not
be read. Direct ECS component traversal worked on both peers.

Final read-only aggregate:

- 413 person entities;
- 10 passenger uses of the canonical line;
- 8 passengers aboard its train;
- 2 passengers waiting at its stops;
- 1 vehicle on the line;
- direct cargo entity, terminal, and vehicle component paths available;
- 0 cargo entities in this passenger-only source save.

The mobility payload contains canonical line identities and aggregate counts,
not machine-local entity IDs. Both peers produced the same digest. A
cargo-positive source save is still required to validate non-zero cargo
classification and to test whether host-authored allocation can be reflected in
native queues and loads.

The 37 native command tags were cross-checked during the earlier command-table
work. `Debug_SetSimPersonState` is observable/gated research surface, not proof
of a safe production passenger steering protocol. Town/industry command tags
likewise do not by themselves solve deterministic physical realization. Those
paths remain fail-closed until they have bounded payloads, host authorization,
replay, and peer postconditions.

## Direct apply path

The native hook continues to observe both `CommandList::Swap` and direct
`ApplyCommand`. Across the populated operational capture and this network run,
ordinary player actions appeared in the queued command stream. No human action
has yet been observed using the direct path. The direct observer remains active
because absence in current traces is not proof that no action can bypass the
queue.

## Automatic recovery-save watcher

Host sessions now start `tools/watch_recovery_saves.ps1` after the pinned world
is loaded. The watcher:

1. verifies the exact recorded game PID, executable path, start time, session,
   and host peer;
2. follows the host audit's latest all-peer agreed checkpoint;
3. waits for a later stable native save triplet candidate;
4. generates and verifies a checksummed recovery plan for that boundary;
5. archives and hashes the `.sav`, `.sav.lua`, and optional screenshot;
6. writes `latest-recovery-archive.json` and exposes its status in the launcher;
7. stops safely if the game exits or the PID is reused.

End-to-end watcher evidence used the completed populated audit at boundary 8
and a disposable save fixture under `runtime/watcher-e2e`. It produced a linked
plan and tamper-evident archive under:

`%LOCALAPPDATA%/TPF2MP/sessions/populated-network-ownershipfix-20260803/player1/recovery`

The important limitation is explicit: Build 35924 exposes no supported
game-script command that creates an exact-tick native save. The watcher links
the first later stable native save candidate to the last agreed boundary; it
does not claim that the save is a byte-exact snapshot of that tick. Full
coordinated rollback still needs a safe save trigger or a stronger temporal
association, two-peer archive agreement, and automatic relaunch/rebinding.

## Real title-screen entry

Production Host/Join sessions no longer load the world before the user enters
multiplayer. The launcher starts the exact game and installs a real
`MULTIPLAYER` entry on the Transport Fever 2 title screen. Until it is selected,
the session remains `awaiting-multiplayer-selection` and no pinned save load is
requested. Selecting it writes a session receipt; only then does the native
menu coordinator load the byte-pinned starting save and attach the session
authority flow.

Disposable live session `menu-production3-20260803` proved:

- the entry was installed with a valid native GUI rectangle;
- the game remained idle before selection;
- a physical click produced the selection receipt;
- the pinned save progressed to `hosting-world-ready`;
- the native save-load receipt existed;
- the recovery watcher started;
- session stop terminated the watcher, companion, and exact game process.

The localhost validator intentionally bypasses this one human click because it
is an automated harness; normal Host/Join does not.

## Durability and packaging

The hook profile remains pinned by the executable SHA-256, PE timestamp, image
size, 17 unique signature/RVA checks, and 23 selected command-visitor entries.
The research trail for the strings, xrefs, layouts, and visitor table is kept in
the Build 35924 investigation documents; a new game build must be re-pinned and
live-tested rather than accepted from signatures alone.

Prototype `0.17.0-alpha` packages the title-menu bootstrap, main-menu
coordinator, session launcher, status/stop tools, recovery plan/archive tools,
and automatic watcher. The full post-change suite passes 24 Lua units, all Lua
integration suites, 14 mod Lua syntax checks, 4 bootstrap syntax checks, 39
PowerShell syntax checks, the launcher smoke test, 30 Python tests, and a
104-event cross-language replay.

## Manual handoff, bidirectional construction, and endpoint isolation

Disposable session `lan-preflight-handoff-20260803-1316` continued in the same
two exact game processes after automated validation. A per-peer handoff receipt
removed validator-only GUI behavior while retaining the network native gates,
frozen autonomy, canonical accounts, and paused calendar policy.

The human then built one ordinary private track from each peer. Each proposal
was captured once, ordered, reconstructed on both worlds, charged only to its
canonical company, physically agreed by both peers, and followed by an all-peer
checkpoint. Final audit before shutdown reported 7 commits, 9 controls, 158
telemetry records, 4 complete and 0 faulted physical proposals, 5 complete and
0 faulted checkpoint barriers, 10 checkpoint records, and no pending peer
digests. Company 1 remained at `4,925,598`; Company 2 remained at `4,952,012`.

The same run exposed a narrower ownership defect before any unauthorized
mutation committed: player 2 could not expand player 1's private track, but
player 1's builder could snap to player 2's endpoint. The audit stayed at 7
commits and contained only `builder.proposalCreate` observations, proving this
was a preview/authorization asymmetry rather than hidden world mutation.

Root cause: the pre-commit access policy inspected removed/replaced entities,
but a linear expansion can contain no removal and name the old network only by
a positive `node0` or `node1` reference. Created BASE_NODE outputs also lacked
logical company custody. The corrected policy now:

1. treats positive endpoints in added edges as ownership sources;
2. assigns canonical/logical ownership to nodes created for private edges;
3. seeds endpoints of private edges in the starting save;
4. validates rival canonical node references again in the ordered replay
   queue, independently of the GUI;
5. leaves genuinely public/untracked nodes usable;
6. restores node/edge ownership atomically if output binding fails.

Regression coverage proves own, rival, and public endpoint behavior in both
directions, local and remote node output custody, starting-save node seeding,
and rejection of a forged rival attachment that bypasses GUI capture. Session
`lan-endpointfix-20260803-1350` then live-proved the complete symmetric matrix:
each player could extend its own private track and the result synchronized to
the other process, while each player's attempt to extend the rival's private
endpoint was rejected before mutation. The endpoint fix is therefore
live-proven on localhost in both directions.

The fresh retest session `lan-endpointfix-20260803-1350` then exposed a separate
sequencing/UX issue. A Player-2 click was natively suppressed at tick 3365,
while Player 1's proposal received at tick 3345 was still awaiting physical
consensus and its checkpoint did not close until tick 3555. The engine correctly
refused a concurrent intent, but the already-suppressed click was discarded and
looked like one-way replication failure. It never entered the host audit. Once
the barrier cleared, the same Player-2 build synchronized normally, confirming
that reverse replication remained healthy.

The source now retains up to eight machine-local deferred build captures while
a physical/operation/checkpoint barrier or a just-emitted local intent is
pending. The overlay exposes queue depth and the outbound intent awaiting host
order. Captures remain FIFO, cannot overwrite one another, are canonicalized
only when they reach the head, and never enter portable state or a core digest.
Integration coverage orders the first of two independent queued builds, holds
the follower through physical consensus and checkpoint consensus, then emits
the untouched second geometry. Fresh-process live proof remains pending.

The endpoint session was stopped cleanly and archived at
`runtime/manual-network-evidence/lan-endpointfix-20260803-1350-20260803-142755`.
Its independent audit verified 9 commits, 13 controls, 444 telemetry records,
9 converged samples, 6/0/0 complete/faulted/pending physical proposals,
7/0/0 checkpoint barriers, 14 checkpoint records, 226 events, no pending
authority work, and no session fault.

The same session measured the next proposal boundary. Signal placement did not
produce an ordered mutation. Track-type and catenary upgrades were captured as
complete topology-preserving edge replacements, but the companion rejected
them with `proposal transaction has an invalid node list`. The proposal itself
was not deficient: a pure edge replacement creates no BASE_NODE outputs, and
Lua's deterministic JSON encoder spells that empty table as `{}` rather than
`[]`. No upgrade entered the ordered log, no money moved, and neither world was
partially modified.

The protocol now accepts only that empty-object spelling for a zero-node
proposal while retaining it byte-for-byte in the digest view; a non-empty
object remains invalid. Automated coverage now takes a remote private
track-type/catenary replacement through canonical endpoint resolution, local
materialisation, removal of the old edge, geometric binding of the replacement,
retirement/rebinding of canonical identity, preservation of company custody,
owner-only finance, two-peer physical consensus, and an all-peer checkpoint.
Signals remain deliberately fail-closed because their `edgeObjectsToAdd`
payload still has no canonical codec. The full suite passes 24 Lua units, all
Lua integrations, 14 mod and 4 bootstrap Lua syntax checks, 39 PowerShell
syntax checks, 30 Python tests, and the 104-event replay. Track-type/catenary
upgrades now require fresh-process live proof.

Fresh session `lan-upgradefix-20260803-143752` supplied that next measurement
but did not yet close the gate. Ordinary Company-1 and Company-2 track builds
both synchronized and checkpointed. The first high-speed replacement was then
ordered as commit 17 and the native command physically changed the track on
both worlds. Build 35924 reused an old numeric BASE_EDGE identity for part of
the successful replacement; canonical finalization attempted to bind the new
event identity before retiring the removed identity and failed identically on
both peers with `local identity already bound to edge:...:11:3`. The failure
completion's empty output table was encoded as `{}`, rejected by the companion,
and consequently became a completion timeout instead of an immediate ordered
fault. Evidence is archived under
`runtime/manual-network-evidence/lan-upgradefix-20260803-143752-idreuse-fault`;
the final independent audit remained valid and fail-closed.

The corrected finalizer now snapshots registry/custody state, retires every
canonical removal before binding replacement outputs, and restores the exact
pre-finalize bookkeeping if any later binding fails. The companion accepts
only an actually empty Lua completion-output object, so a native failure faults
immediately rather than stalling until timeout. The same live ID-reuse shape
now passes end-to-end integration. Timing evidence also showed each healthy
human build spending about 39 seconds in a redundant second 180-engine-update
finance wait after the GUI had already stabilized its native journal sample.
That second wait is removed; the signed quoted cost remains authoritative and
periodic native-wallet reconciliation remains the safety net. These changes
need one more fresh-process live upgrade and latency proof.

## Next human gate

The shortest useful next test is one fresh localhost two-process session:

1. Upgrade one Company-1-owned track segment to a different track type and
   require the change, owner-only cost, physical consensus, and checkpoint on
   both peers.
2. Toggle catenary on one Company-2-owned segment and require the same results.
3. Attempt each upgrade on the rival's private segment and require pre-mutation
   rejection with no money change.
4. Attempt one signal and require an explicit fail-closed result with no
   topology or finance change.
5. During a pending build/checkpoint barrier, make exactly one build on the
   other peer and verify the overlay reports it deferred and releases it once.

After that localhost vocabulary check, run the two-computer trusted-LAN session
using byte-identical copies of the populated save: enter through Host/Join and
the title-screen `MULTIPLAYER` button, compare the initial checkpoint, unpause
both peers at the same speed for several real train cycles with intermediate
samples, pause, submit one supported private track transaction from each peer,
save on the host, verify the recovery archive, and collect both evidence
bundles.

That is a real human game slice, but its build vocabulary remains deliberately
narrow. Lines, stations, depots, and train lifecycle operations have canonical
codecs and offline consensus tests in the current source; they still require
live two-process vanilla-UI proof before being described as playable network
features.
