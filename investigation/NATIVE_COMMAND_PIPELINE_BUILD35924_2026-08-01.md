# Native command pipeline — Build 35924 — 2026-08-01

## 2026-08-02 hook 0.7 authority update

The observation and tag map below now support a second authority tier. Hook `0.7.0` pins and validates 23 entries in the 37-pointer table before installing their exact-ABI visitor detours. The selected tags are `0-14`, `16`, `25`, `26`, `28-30`, `33`, and `36`; tag 15 retains its separate BuildProposal gate. Each selected visitor rejects while gated unless it atomically consumes one authorization for its own tag, after which the normal `ApplyCommand` success/callback path continues.

Post-hardening run `runtime/supported-api-probe/20260802-075034` proved an unauthorized tag-0 callback returns false and a one-shot-authorized retry returns true, with 23 hooks and no pending tokens or mismatches. `runtime/live-validation/20260802-075533` passed 39/39 with the gate disabled in standalone mode and zero visitor mismatches. See [CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md](CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md) for exact RVAs, APIs, status schema, and the current boundary.

This supersedes the historical "other command gates not implemented" statements below. Payload capture, canonical replay, dependency translation, finance, and two-peer postconditions for those categories are still not implemented.

## Outcome

The exact Windows x64 Build 35924 command pipeline is now observed at both of its execution paths, and `BuildProposal` has a live-proven pre-mutation gate. This is a substantial authority primitive, but not yet network replication.

Implemented and proven:

- every queued command batch is observed at `CommandList::Swap`;
- every executed command is observed at `ApplyCommand`;
- queue entries are paired with apply results and classified by all 37 variant tags;
- engine-state commands that bypass the queue are identified as direct applies;
- command timelines retain non-script commands without being displaced by high-volume `SendScriptEvent` traffic;
- the tag-15 visitor can reject a `BuildProposal` before world mutation;
- one-shot authorization admits exactly one proposal to the original visitor;
- public `api.cmd.make.*` factories and native mirrors are callable in the same Lua state;
- an opt-in Lua callback receives the original `sendCommand` argument before the preserved game closure runs, allowing bounded same-state command projection without changing call-through semantics.

Not implemented:

- stable semantic proposal-payload serialization (the new bounded projection is evidence, not the wire format);
- host approval/rejection wired to the gate;
- remote native command construction or injection;
- callback/result capture into canonical output slots;
- canonical reference translation inside proposal payloads;
- pre-mutation gates for command categories other than `BuildProposal`;
- two-instance physical convergence.

## Exact executable pin

- Runtime: `Build 35924 Windows 64-bit`
- SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`
- File size: `72,843,280` bytes
- PE timestamp: `0x675ABCC6`
- PE image size: `0x46CE000`
- Architecture: AMD64
- Current hook version: `0.6.0` (`0.5.0` produced the earlier queue/gate evidence)
- Exactly-once signatures: 17

The DLL fails closed unless the complete file/PE profile and every signature match. RVAs below are review metadata for this exact executable; hook targets are still found and validated by signatures.

## Recovered anchors and layout

| Item | Build 35924 fact |
|---|---|
| `CommandList::Swap` | RVA `0x009D2CF0` |
| `ApplyCommand` | RVA `0x009DA290` |
| Command visitor pointer table | RVA `0x030B10C0`, 37 pointers |
| `BuildProposal` table entry/thunk | tag 15, RVA `0x009D6440` |
| `BuildProposal` real visitor | RVA `0x009D6E20` |
| `sizeof(Command)` | `0x38` bytes |
| Command data pointer | `Command + 0x00` |
| Variant discriminator | signed byte at `CommandData + 0xB18` |
| Command success state | byte at `Command + 0x30` |
| Visitor ABI | `bool visitor(void* context, void* buildProposal)`; payload is the second argument in RDX |

`ApplyCommand` dispatches through the 37-entry visitor table. The observer reads only the pinned layout fields needed to classify and correlate commands. It records invalid layouts or out-of-range tags and refuses to reinterpret them as valid traffic.

## Complete command tag map

| Tag | Name | Tag | Name |
|---:|---|---:|---|
| 0 | `SetGameSpeed` | 19 | `DevelopTown` |
| 1 | `SetCalendarSpeed` | 20 | `SetTownInfo` |
| 2 | `UpdateLogo` | 21 | `InstantlyUpdateTownCargoNeeds` |
| 3 | `CreateLine` | 22 | `ConnectTownsAndIndustries` |
| 4 | `DeleteLine` | 23 | `SetSimBuildingManualDevelopment` |
| 5 | `UpdateLine` | 24 | `SetSimBuildingClosureTimeStamp` |
| 6 | `SetLine` | 25 | `ReplaceTerrain` |
| 7 | `Reverse` | 26 | `SetDate` |
| 8 | `SetUserStopped` | 27 | `SaveGame` |
| 9 | `SetVehicleTargetMaintenanceState` | 28 | `SetColor` |
| 10 | `SetVehicleShouldDepart` | 29 | `SetName` |
| 11 | `SendToDepot` | 30 | `SetVehicleManualDeparture` |
| 12 | `SellVehicle` | 31 | `Book` |
| 13 | `BuyVehicle` | 32 | `SendScriptEvent` |
| 14 | `ReplaceVehicle` | 33 | `SetNoCosts` |
| 15 | `BuildProposal` | 34 | `SetAnimalState` |
| 16 | `RemoveField` | 35 | `SpawnAnimal` |
| 17 | `CreateTowns` | 36 | `Debug_SetSimPersonState` |
| 18 | `RemoveTown` |  |  |

This map is exact-build reverse-engineering evidence, not a compatibility promise for another Transport Fever 2 version.

## Queue path and direct path

Commands do not all travel through the same queue:

1. `CommandList::Swap` exposes batches produced by the normal queued path.
2. `ApplyCommand` is the common execution boundary and supplies the final success state.
3. Some engine-state commands call `ApplyCommand` directly and therefore have no queue record.

The correct conservation invariant is:

```text
apply.calls + commandList.pendingCommands
  == commandList.commands + apply.direct
```

The earlier full run `runtime/live-validation/20260801-164040` recorded:

- 204 swaps and 204 non-empty batches;
- 11,293 queued commands;
- 11,312 applied commands, all successful;
- 19 direct applies;
- zero invalid layouts, unknown tags, pending overwrites, pending commands, or tag mismatches.

The 19 direct applies exactly match the mod's 19 `sendCommand` calls:

- 2 × `SetGameSpeed`;
- 5 × `SetSimBuildingManualDevelopment`;
- 12 × `Book`.

Queued traffic was 11,292 × `SendScriptEvent` plus one `SetNoCosts`. This proves that relying only on the queue would miss legitimate command execution; `ApplyCommand` is the universal observation point on the tested run.

Each observed command receives a local sequence plus batch/index, tag/name, queue/apply thread, and success state. `commandEvents` retains up to 256 non-`SendScriptEvent` records; `recentCommandEvents` retains the latest 64 records of any tag. This prevents script-event volume from erasing construction/finance evidence.

Hook-0.6.0 integration run `runtime/live-validation/20260801-183544` separately passed 30/30 with one registered pre-issue observer state, 21 transparent wrapped calls, 10,721 queued commands, 10,695 completed applies, 47 pending queue entries at evidence capture, and 21 direct applies. The conservation equation closed exactly; invalid layouts, unknown tags/applies, pending overwrites, and tag mismatches were all zero.

## Callable-table correction

The initial capability probes used `type(factory) == "function"`. That predicate is wrong for this build: `api.cmd.make.buildProposal`, `sendScriptEvent`, and the other tested factories are callable Lua tables.

Corrected evidence:

- `runtime/supported-api-probe/20260801-161030`: public and native-mirrored `buildProposal`/`sendScriptEvent` exist as tables and are callable; the public source is preferred.
- `runtime/supported-api-probe/20260801-162057`: a documented public `BuildProposal` road command succeeded.
- the hook mirrors command bindings only after `SetupCommandInterface` returns, avoiding sol2 re-entrancy; mirrors are same-state fallbacks, not a cross-state bridge.

The earlier negative markers are retained as investigation history, but their “factory absent” interpretation is invalid.

## Pre-commit Lua proposal projection

Shipped `guidesystem.lua` proves `builder.proposalCreate` exposes a traversable `param.proposal`: the base game reads `toAdd` and nested `proposal.edgeObjectsToAdd` from it. A manual Build 35924 GUI sample on 2026-08-01 then established the runtime detail the static inspection could not: both `param.data` and `param.proposal` arrive as userdata with field-access metamethods, not as ordinary Lua tables. Prototype 0.6 captures proposals through a separate bounded projection:

- maximum depth 8, 2,048 visited values, and 128 entries per table;
- deterministic key ordering;
- strings bounded to 240 characters;
- ordinary tables retain deterministic traversal, while proposal userdata is read only through protected sequence indexing and an explicit allowlist of known shipped-script/proposal fields;
- opaque userdata, functions, and threads remain type markers such as `<userdata>`, never pointer-bearing `tostring` output;
- the latest projection remains under `capture.lastProposalSnapshot`, while an eight-record ring preserves preview/apply samples so an empty cursor preview cannot erase the useful proposal;
- the action field is cleared inside the engine handler before event/audit recording, so this larger RE payload does not inflate or destabilize the checksummed history.

Manual export `9cb25ad2` live-proves that the userdata-aware GUI projection reaches the outer `proposal`, `toAdd`, and `toRemove` fields and the nested `addedSegments`, `removedSegments`, `new2oldSegments`, `addedNodes`, `removedNodes`, and edge-object containers without addresses. The latest sample itself was an empty post-build preview, so its sequence containers had length zero and remained `<userdata>` markers. Prototype 0.7 also captures `builder.apply` and retains eight samples to preserve the next non-empty instance.

Hook 0.6.0 adds `tpf2mp_native_set_command_observer(callback)`. The callback is rooted in the registry of the exact Lua state which registers it. The transparent `sendCommand` wrapper invokes it with argument 1 before moving/calling the original closure. The mod callback wraps all work in `pcall`, never calls `sendCommand` recursively, filters for command objects with a `proposal` field, and projects the full command envelope with protected userdata reads, depth/entry/string budgets, and the proposal-field allowlist. The larger projection is removed before immutable event/audit recording and kept only in the eight-record research ring. Capability run `runtime/supported-api-probe/20260801-183428` proved the API callable; full run `20260801-183544` proved one GUI state registered it without changing the validator result.

This is deliberately not called serialization: element fields still need live confirmation, semantic normalization, local-ID classification, and round-trip construction tests.

Static visitor analysis also shows why a raw native memory dump was not promoted as a protocol. The tag-15 object spans roughly `0xB18` bytes and contains mutable flags, inline state, dynamic C++ containers, and process-local pointers (notably regions around `+0x2F8`, `+0x370`, `+0xAD0`, and `+0xB00`). Copying those bytes would be machine-specific and unsafe to replay. The binding string has only one executable xref, inside `SetupCommandInterface`; no independent named serializer anchor was found in the string-xref scan.

## Edge ownership finding

The manual two-road run's native timeline contains three successful tag-15 applies: the two builds and the later native player-ownership tool. Disposable run `runtime/supported-api-probe/20260801-181750` then proved that `game.interface.setPlayer` is not an alternate edge path: passing a live `BASE_EDGE` enters the game's internal assertion at `legacy/interface.cpp:2340`, even when the requested owner already matches. Prototype 0.7 therefore pins road/track edges to the shared turn desk and retains only logical per-company custody by default.

Disposable run `20260801-190732` subsequently proved a supported exact-build replacement path. A `SimpleProposal` removed a public edge and added an otherwise-identical `SegmentAndEntity` with `playerOwned.player` set to an arbitrary new player, then a second proposal restored desk ownership. Native IDs changed `1444 -> 9479 -> 8145`, and callback result-ID vectors were empty. Proposal construction, guarded owner/delta-based replacement discovery, `canonical.rebindLocal`, and logical-custody migration are now implemented and tested. Capturing the built-in third proposal remains useful to compare its `new2oldSegments` mapping and generalize the serializer; it is no longer required to prove arbitrary-player reassignment is possible. Local turn integration still needs asynchronous multi-edge completion, rollback replacements, persistence, reference migration, and finance-after-custody ordering.

## BuildProposal visitor gate

The gate is disabled by default. Its diagnostic Lua API is:

- `tpf2mp_native_enable_build_gate()` — enable rejection and clear old authorizations;
- `tpf2mp_native_authorize_build()` — add one bounded authorization token;
- `tpf2mp_native_disable_build_gate()` — disable rejection and clear tokens.

When enabled, the detour either consumes one authorization and calls the original visitor, or returns `false` without calling it. Because this boundary is inside `ApplyCommand`'s variant visitor, the original command completion/callback machinery still reports the rejection normally.

Live gate evidence is `runtime/supported-api-probe/20260801-163359`:

| Attempt | Gate action | Visitor result / callback |
|---|---|---|
| 1 | no authorization | suppressed, `success=false` |
| 2 | one authorization | original visitor ran and naturally failed, `success=false` |
| 3 | one authorization | original visitor ran and succeeded, `success=true` |

Final gate counters were `enabled=false`, `authorizations=0`, `allowed=2`, and `suppressed=1`. The native tag-15 timeline is exactly `false, false, true`; there were no unknown tags, pending overwrites, or tag mismatches.

The mod UI exposes **Toggle Build Gate (Test)** and **Authorize Next Build** for disposable local diagnosis. These controls are deliberately not represented as multiplayer authority.

## ABI failure and fix

The first transparent visitor experiment, `runtime/supported-api-probe/20260801-162841`, crashed because the detour was initially declared with one argument and forwarded only RCX. Per-function disassembly showed that the thunk/real visitor consumes a second argument in RDX. The detour was corrected to `bool(void*, void*)` and forwards both values.

`runtime/supported-api-probe/20260801-163114` then proved transparent pass-through without a crash, and `20260801-163359` proved suppression/authorization. This failed experiment matters: the exact visitor ABI is now an explicit pinned invariant rather than an inferred generic callback shape.

## Reproduce safely

Close Transport Fever 2 and use only the disposable runners:

```powershell
.\tools\build_native_hook.ps1
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -BuildGateTest
.\tools\run_unattended_live_validation.ps1 -NativeHook -SkipNativeBuild
```

The runners launch a fresh unsaved world, preserve/restore settings, capture PID-specific status, stop the exact process, and remove verified temporary resources. They must never be pointed at a valued save.

For static pointer-table inspection, the analyzer supports:

```powershell
python .\tools\analyse_tpf2_binary.py `
  'F:\SteamLibrary\steamapps\common\Transport Fever 2\TransportFever2.exe' `
  --pointer-table-rva 0x30B10C0 --pointer-count 37
```

## Remaining network-authority slice

The shortest honest path from this gate to a two-machine construction pilot is:

1. decode every relevant field of the tag-15 payload and normalize references/geometry/resources;
2. suppress the originating action and send that normalized intent to the host;
3. have the host validate/order it and broadcast a committed payload;
4. construct or inject the accepted command on host and client;
5. capture ordered result slots and bind each local entity to the host's canonical identity;
6. compare canonical topology, ownership, cost, and result postconditions;
7. stop on the first ambiguity or asymmetric result;
8. repeat the pattern for the remaining MVP command visitors.

Until that completes, the gate is a local authority primitive, not network multiplayer.

## Prototype 0.8 builder-lifecycle follow-up

The manual run documented in [CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md](CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md) retained a non-empty final GUI preview and apply pair for a two-edge rival track electrification. Preview sources `27017/27018` mapped by carrier and unchanged unordered endpoints to apply targets `27020/15370`. This was enough to implement local atomic canonical/logical/pinned rebinding without relying on empty callback result vectors. It is not yet a portable command payload: geometry, local IDs, costs, resource indexes, split/join topology, host approval, and remote reconstruction still need normalization and postcondition binding.

The focused 0.8 retest matched `25863/25864 -> 25866/9803` exactly, but also proved the GUI commit can expose new target ownership one script-event boundary before `api.engine.getComponent(..., PLAYER_OWNED)` can read those new IDs. Prototype 0.9 carries `builder.apply.playerOwned` through the local observation for that absent-component case, rejects any actual engine contradiction, and verifies the pinned owner again at financial reconciliation. This timing bridge is local evidence handling, not network authority.

## Primary references

- [Transport Fever 2 command API](https://wiki.transportfever2.com/api/modules/api.cmd.html)
- [Official street-building example](https://wiki.transportfever2.com/api/examples/build_street.lua.html)
- [Transport Fever 2 API types](https://wiki.transportfever2.com/api/modules/api.type.html)
- [Legacy `game.interface` reference](https://wiki.transportfever2.com/script-doc/modules/game.interface.html)
- [MinHook upstream](https://github.com/TsudaKageyu/minhook)
