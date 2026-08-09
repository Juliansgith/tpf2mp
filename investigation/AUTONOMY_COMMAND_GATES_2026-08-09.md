# Autonomy command gates

Date: 2026-08-09  
Prototype: `0.37.0-alpha`  
State schema: `29`  
Native hook: `0.16.0`  
Pinned executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

## Result

The exact Build 35924 native command authority surface now contains 31 visitor
gates. The previous 23 consequential visitors remain unchanged. Eight
contiguous town/industry autonomy visitors were recovered from the pinned
37-entry dispatch table and added before hook activation:

| Tag | Command | RVA |
| ---: | --- | ---: |
| 17 | `CreateTowns` | `0x009D5850` |
| 18 | `RemoveTown` | `0x009D5860` |
| 19 | `DevelopTown` | `0x009D5920` |
| 20 | `SetTownInfo` | `0x009D5930` |
| 21 | `InstantlyUpdateTownCargoNeeds` | `0x009D5A30` |
| 22 | `ConnectTownsAndIndustries` | `0x009D5BA0` |
| 23 | `SetSimBuildingManualDevelopment` | `0x009D5BB0` |
| 24 | `SetSimBuildingClosureTimeStamp` | `0x009D5CC0` |

The DLL validates the exact table entry and expected command tag before any
detour is installed. Network readiness now requires all 31 visitors to be
hooked, both authority gates enabled, and no visitor/tag mismatch.

## Authorization policy

The command gate rejects all eight new tags unless the same tag has a pending
one-shot token. Production code has only three token consumers:

- canonical physical town development authorizes tag 19;
- authored town information/population projection authorizes tag 20;
- native industry-autonomy freezing authorizes tag 23.

Tags 17, 18, 21, 22, and 24 have no gameplay authorization path. A centralized
`native_command_authority.send` helper grants a token immediately before the
command and withdraws it if Lua submission throws before the visitor consumes
it. This closes the known stale-token window in which a later unrelated native
command might otherwise inherit an authorization.

Each native tag counter is finite at 8,192 pending tokens. That bound covers the
protocol maximum of 512 towns times eight `DevelopTown` calls (4,096 tag-19
visits) in one authored growth burst while still failing closed under runaway
submission.

## Verification

The native build against the pinned executable validates all 17 unique code
signatures, all 31 selected visitor-table entries, and passes both CTest cases.
The full offline repository gate passes 124 Lua tests, 136 Python tests,
cross-language economy/freight replay parity, GUI/game/network/hot-seat tests,
release/install tests, and the deterministic 1,024-event audit replay.

Focused Lua coverage proves exact-tag authorization, withdrawal after a
pre-visitor submission exception, and standalone fallback when the native hook
is deliberately absent. Native tests assert that every tag 17-24 is present in
the pinned authority table.

## Honest boundary and next live proof

This is a native command-visitor authority boundary, not hostile-code security.
A script that directly invokes a game interface outside the command visitor
table, including direct `setTownDevelopmentActive` use, is not automatically
intercepted. Peer authentication and arbitrary script-mod mutation are also
separate work. Structural checkpoints still detect resulting physical
divergence and fault the session rather than accepting it silently.

No new game process was launched for this slice. The next live proof is a fresh
two-process town-growth/settlement run with `hooked=31`: authored tags 19, 20,
and 23 must pass without unexplained suppression, an unauthorized autonomy
visitor must fail before mutation, and both peers must finish on the same
physical and canonical checkpoint.
