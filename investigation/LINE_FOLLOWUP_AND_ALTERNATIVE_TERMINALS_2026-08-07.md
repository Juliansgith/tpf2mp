# Line follow-up deletion and alternative terminals — 2026-08-07

## Live queue finding

Session `line-followup-fix-live-20260807-1241` reproduced a normal user flow:
create an accidental line, delete it, then remove and restore a stop on the
surviving `Mainline`. The accidental lines were user-created; they were not
temporary lines invented by the vanilla editor.

Before this slice, a `line.delete` removed the native/canonical line and any
registered economic service, but did not cancel a still-deferred
`line.register`. A deleted line could therefore remain at the head of the
authored follow-up FIFO and retry normalization forever, starving valid work.

The operation-outcome handler now cancels an un-emitted registration for the
deleted canonical line. Live evidence includes:

- `network-followup-cancelled` for
  `line:event:line-followup-fix-live-20260807-1241:player1:12:1`;
- queue depth falling from two to one;
- two updates for `line:pre:2820313f` coalescing into one registration;
- the surviving registration emitting with `queueRemaining:0`;
- commit 25 applying `line.register` successfully on both peers;
- both peers subsequently reporting `localWorkPending:false`, commit 25, and
  no session fault.

The companion replay audit was valid with 10 authored commits, 15 controls,
zero missing peer digests, and no pending physical/checkpoint work.

## Hidden alternate-platform divergence

The same run exposed that the line used Transport Fever 2's alternative
terminal/platform feature. The old capture serialized only
`stationGroup/station/terminal`, while replay constructed every
`Line.Stop.alternativeTerminals` as empty. The origin retained its optimistic
native setting and the remote peer silently lost it.

Build 35924's pinned `Line::Stop` copy helper at RVA `0x001D8140` proves the
missing field layout. After copying the three 32-bit identity fields at
`+0x00/+0x04/+0x08`, it invokes the typed vector-copy helper with source and
destination `+0x10`. This matches the documented Lua
`Line.Stop.alternativeTerminals` vector. The official API identifies its
element as `api.type.StationTerminal`, an eight-byte pair of 32-bit `station`
and `terminal` indices. The decoder reads that vector only after validating its
begin/end/capacity pointers, readable range, eight-byte element alignment,
per-stop count, total count, and both indices in every pair.

The first live acceptance session,
`line-alt-platform-live-20260807-130412`, caught the initial decoder treating
those eight-byte pairs as independent 32-bit terminal IDs. P1 captured and
completed schema 2 with flattened values `[0,0,0,1]` and `[0,1]`; P2 received
the ordered action but never issued `UpdateLine`, so physical consensus stayed
pending. This was a failed acceptance, not a successful synchronization claim.
It also exposed a generic liveness defect: a generated-userdata exception was
caught by the outer GUI update loop after `operationIssued` had latched, leaving
no failed completion to close the barrier.

The next typed-replay attempts also failed closed and exposed an undocumented
sol2 binding distinction. In session
`line-alt-constructor-live-20260807-135231`, the public
`api.type.StationTerminal.new()` constructor returned owning userdata with
metatable name `sol.transport::StationTerminal`, while entries read from a
real line component had metatable name `sol.transport::StationTerminal*`.
Bulk assignment of a populated Lua table to
`Line.Stop.alternativeTerminals` therefore failed with `expected userdata,
received sol.transport::StationTerminal`. A read-only console probe showed
that the field itself is a native
`std::vector<transport::StationTerminal,...>*` proxy. Clearing that proxy and
assigning each owning userdata by numeric index performs the native value copy
and reads back the required pointer userdata. Replay now uses that measured
path; a regression fixture rejects any future return to bulk assignment.

## Portable contract

- Native envelope `L3` appends colon-separated `station.terminal` pairs to each
  stop. The Lua decoder remains able to read historical `L1`, and interprets
  historical flattened `L2` values pairwise only when their count is even.
- Canonical operation schema 3 requires `alternativeTerminals` as an array of
  exact `{station, terminal}` records on every stop. Lua-created routes default
  it to an empty array.
- Python and Lua continue to validate schema 1 and flattened schema 2 for
  historical audit/recovery records; all new operations emit schema 3.
- Replay creates typed `api.type.StationTerminal` values, clears the native
  alternative-terminal vector proxy, and appends the values through that
  proxy. The remote postcondition reads back and compares every pair. Economic
  corridor endpoints remain station-group based, so allowing several physical
  platforms does not multiply or change modeled demand.
- GUI operation materialisation is locally protected. A generated-userdata
  exception now emits an explicit failed `operation.result`; it cannot leave an
  ordered operation permanently pending.

Waypoints and richer load/wait settings remain deliberately outside this
claim; they are not copied as opaque native bytes.

## Verification

- Native typed `StationTerminal` vector decode/L3 encode unit test: PASS.
- Build 35924 executable hash, PE profile, all 17 signatures: PASS.
- Native CTest and DLL load rejection test: PASS.
- Full Lua, cross-language parity, Python, GUI/native integration,
  deterministic replay, and source-boundary suite after schema 3: PASS.
- Fresh live session `line-alt-vector-live-20260807-143109`: PASS. P1's
  vanilla alternative-platform edit produced schema-3 commit 3; P1 and P2 both
  completed it successfully with identical physical result digest `dacfb53d`.
  P2 issued one authorized native `UpdateLine`, and checkpoint boundary 4
  converged at core digest `6ef70769` with no session fault.

The P1-origin acceptance is live-proven. A later two-origin coverage pass may
repeat the same edit from a P2-owned line; the codec, materializer, and native
authority path are symmetric, so this is additional coverage rather than a
remaining blocker for the populated demo.
