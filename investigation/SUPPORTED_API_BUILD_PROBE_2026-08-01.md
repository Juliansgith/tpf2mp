# Supported construction-API probe — 2026-08-01

## 2026-08-02 consequential-command follow-up

The probe runner now accepts `-CommandGateTest`. Post-hardening exact-build evidence `runtime/supported-api-probe/20260802-075034` validated hook `0.7.0` and all 23 selected visitor hooks, then issued tag-0 `SetGameSpeed` twice. The unauthorized command completed through the ordinary callback with `success=false`; one per-tag authorization admitted the retry with `success=true`. The gate ended disabled with `suppressed=1`, `allowed=1`, `pending=0`, and `mismatches=0`. This proves a reusable pre-mutation authority ABI for the selected commands, not their payload serialization or multiplayer replay.

## Question

Can a pinned Transport Fever 2 Build 35924 Lua console issue a documented `BuildProposal`, giving a pure-Lua mod-owned builder an exact construction/result-ID path without native hooks?

## Why this needed a runtime test

The official [`api.cmd`](https://wiki.transportfever2.com/api/modules/api.cmd.html) documentation describes command construction/sending and the official [street-building example](https://wiki.transportfever2.com/api/examples/build_street.lua.html) uses `SimpleProposal`, terrain heights, and `buildProposal`. Module documentation is not proof that every member is exposed in every Lua state on the pinned executable.

The early multiplayer research export reported `buildProposal=no` in its engine game-script state, but it used the same function-only predicate later shown to be invalid for callable command tables. The runtime test was still necessary to prove actual construction and callback behavior.

## Method

The isolated runner `tools/run_supported_api_build_probe.ps1`:

1. refuses to run if Transport Fever 2 is already open;
2. injects only `investigation/live_probe_bootstrap.lua`, the JSON helper, and `investigation/live_console_probe.lua` into explicit temporary base-resource paths;
3. starts a new unsaved default world through `app.startGame()`;
4. waits for a minimal engine `world-ready` marker without loading the multiplayer runtime;
5. executes the console probe after explicitly closing/reopening the console to restore keyboard focus;
6. records capabilities and attempts one 80-metre country-road proposal only if every required callable exists;
7. stops the exact game process and removes the temporary files in cleanup.

No valued save was opened or modified.

## Corrected result

Yes. Build 35924 can construct and send a documented `BuildProposal` from the tested disposable-world state.

The original run `runtime/supported-api-probe/20260801-032701` and wrapper run `20260801-150839` did execute their probes, but the capability predicate accepted only values whose Lua type was `function`. Build 35924 exposes `api.cmd.make.*` command factories as callable tables. Their negative factory markers therefore do **not** prove absence.

The corrected capability run `runtime/supported-api-probe/20260801-161030` established:

```text
buildProposal=true
buildProposalCallable=true
buildProposalType=table
buildProposalSource=public
sendScriptEvent=true
sendScriptEventCallable=true
sendScriptEventSource=public
nativeMirroredBuildProposal=true
nativeMirroredBuildProposalType=table
sendCommand=true
```

The public factory is preferred. The native hook's same-state binding mirror is only a fallback and was not needed to construct the command.

`runtime/supported-api-probe/20260801-162057` then attempted candidate locations using legacy `game.interface.getHeight` with protocol-shaped `{x=..., y=...}` vectors. A documented public road `BuildProposal` succeeded. The native command timeline retained tag 15 and its callback result, proving command construction, sending, native dispatch, and completion were all real rather than a capability-only claim.

## Native gate result

Evidence: `runtime/supported-api-probe/20260801-163359`.

The exact-build hook gates the tag-15 visitor before world mutation. The automated test enabled the gate, sent one proposal without authorization, then admitted proposals with one-shot tokens:

- blocked attempt: visitor suppressed, Lua callback `success=false`;
- authorized attempt 1: original visitor ran and naturally failed;
- authorized attempt 2: original visitor ran and succeeded;
- native counters: `suppressed=1`, `allowed=2`, `authorizations=0`, gate disabled after completion;
- tag-15 apply timeline: `false, false, true`;
- zero invalid layouts, unknown tags, pending overwrites, or tag mismatches.

The first visitor experiment at `20260801-162841` crashed because its detour forwarded only RCX. Static per-function disassembly showed the BuildProposal payload is the second argument in RDX. The corrected `bool(void*, void*)` detour passed transparently in `20260801-163114` before the gated run was attempted.

## Edge ownership and pre-issue observer results

Evidence: `runtime/supported-api-probe/20260801-181750` and `20260801-183428`.

The ownership mode builds a fresh road, obtains its new edge ID, and exercises the generic legacy ownership function under protected Lua calls. On edge `9480`, same-owner assignment, assignment to an added company, and restoration each entered Transport Fever 2's internal assertion at `legacy/interface.cpp:2340`. This proves `game.interface.setPlayer` is not a supported Build-35924 mutation path for `BASE_EDGE`, even though the component is `PLAYER_OWNED` and the generic legacy documentation describes the setter. Native status from the earlier manual session separately shows its UI ownership tool was a successful third tag-15 command, so proposal-based reassignment—not retry ordering—is the implementation target.

Hook 0.6.0 adds `tpf2mp_native_set_command_observer`. The corrected capability-only run reported `nativeCommandObserverApi=true`, kept the transparent wrapper call-through proof (`sendCommandNilRejected=true`), and passed all native layout/tag checks. The full-mod run documents actual callback registration; this isolated probe establishes that the API exists in a live disposable-world Lua state.

Evidence `runtime/supported-api-probe/20260801-190732` proves the supported replacement route. The exact binary's Lua binding exposes `SegmentAndEntity.playerOwned` even though that field is absent from the generated public type table. The probe selected public road edge `1444`, added player `9478`, and issued a `SimpleProposal` that removed the edge and added an otherwise-identical segment with `PlayerOwned.player=9478`. It became edge `9479`. A second proposal restored desk player `5743` and produced edge `8145`. Both callbacks succeeded, both local IDs changed, and both `resultEntities` lists were empty. Hook 0.6.0 retained zero invalid layouts, unknown tags, pending commands, or mismatches. See [PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md](PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md).

## Consequence

Two earlier conclusions are superseded:

1. A mod-owned Build 35924 builder is possible for documented commands exposed as callable tables.
2. BuildProposal now has a proven native pre-mutation suppression point.
3. Arbitrary-player native edge ownership can round-trip through supported proposal replacement, but it necessarily needs canonical rebinding and asynchronous transaction recovery.

Neither result completes simultaneous construction multiplayer. A mod-owned UI does not intercept the vanilla builder, and the native gate is still local-only. Proposal payload serialization, host ordering, remote injection/reconstruction, result capture, canonical output binding, physical postcondition comparison, and other command-category gates remain separate requirements. See [NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md](NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md).

## Reproduce

```powershell
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -BuildGateTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -CommandGateTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -ProposalOwnershipTest
```

`-OwnershipTransferTest` intentionally reproduces an internal assertion on a disposable road edge. It is retained as exact evidence but should not be run routinely and must never be pointed at a valued save.

## Related startup hardening

An integrated probe attempt at `runtime/live-validation/20260801-031844` never reached construction: Build 35924 entered its generic Internal-error/hang path around the unguarded validator's initial tick-15 mirror stage. The mod now waits 180 engine updates before any test-only native player/journal mutation. Consecutive guarded runs `20260801-033437` and `20260801-033644` both completed 30/30 at tick 270 with identical core/model/structural digests.
