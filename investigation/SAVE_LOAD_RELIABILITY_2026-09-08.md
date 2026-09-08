# Save/load reliability, 2026-09-08

## Verified defect and protections

A read-only Lua compile scan found trailing serialized fragments after the
closing `end` in the generated lab crash-save metadata
`crash_tpf2mp_lab_localhost-ui-20260905-231013-d09db9_2026-09-05_23-12-26.sav.lua`.
Line 6004 begins ` = 0,`. This is invalid Lua, independently of multiplayer
state or the native world's contents. Local disassembly of Build 35924 places
the historical save-browser dump-request stack inside Lua file loading,
before invoking the metadata's `data` function. This identifies a concrete
error trigger, not proof that this file caused every historical hang.

The new bounded, non-executing metadata validator rejects empty, truncated,
malformed, expression-bearing, or trailing-payload sidecars before launching
a selected save. Recovery archives validate their hash-checked immutable
copies before publishing a manifest; failure removes only the incomplete new
archive and preserves its sources. The accepted serializer subset includes
native infinity/NaN values and escaped literal newlines in diagnostics. A
local scan accepted 206 of 209 sidecars; the other three were the malformed
lab file and two zero-byte user-side metadata files. Those two user artifacts
were left untouched. Arbitrary Lua programs and binary world integrity are
outside this validator's scope.

Fresh localhost clients now load identical bytes under peer-specific names.
Native crash filenames contain the loaded name and a second-resolution time;
distinct names prevent the two clients targeting the same crash-save name.
Concurrent crash-writer corruption is a plausible explanation for the
duplicated tail, not a reproduced root cause. Production launcher staging
already included peer/session/nonce isolation.

An absent Steam client produced exit code 53 before either game rendered.
Direct launching now checks that Steam is running and gives an actionable
message. This check does not guarantee Steam authentication or game startup.

The first current-source capture also reproduced a separate initialization
race: launcher preparation 5 reached checkpoint 13, then the initial
`freight-industry-bootstrap` checkpoint 15 superseded it. Both watchers
correctly refused automatic UI saving at the unrelated boundary, but the
capture helper kept waiting. A restore reproduced the related content race:
fresh peer attestations arrived at commits 3 and 14, with preparation 4 in
between. Restore itself completed at commit 1 without a session fault, but
the later attestation superseded the attempted new save. The launcher pump
now waits for both fresh content agreement and freight state to be ready
before its one-shot preparation; its existing pending-work gate
still applies. The helper fails immediately if a preparation is superseded.
Regression tests cover the unready-to-ready transition, exactly one request,
and refusal of superseded capture even if watcher fixtures claim readiness.

Waiting for content agreement exposed a host/game protocol gap rather than
just another timing issue: both games exported matching `industry-content-ready`
checkpoints at commit 4, then blocked local work, but the host had never
registered that boundary. `IndustryContentConsensus.observe` now registers
the late-content boundary after a previous checkpoint has established the
match, in both live ordering and journal recovery. Pre-initialization content
still defers to the first match checkpoint. The regression establishes a
prior checkpoint, completes both attestations, restarts the host with the
new boundary pending, then verifies both reports close the barrier.

## Preserved malformed test save

Only the confirmed malformed TPF2MP lab crash pair was moved out of the native
save browser, with exact hashes verified before and after. No save was
deleted, and the binary world was not repaired or claimed recoverable.

Archive: `runtime/recovered-saves/invalid-lab-crash-20260908/`.
Its `preservation.json` records the original directory and reversal instructions.

- `.sav` SHA-256: `2a725fc52d9317dab791406b72d027c7b6fd5bf4d139c7f7755f66a47ac9ce3a`
- `.sav.lua` SHA-256: `ffd943f7f474d15cf72fc0997e4d0dccc0a21e30c87c494101e0c8435da429ef`

## Live evidence and limits

All runs use native Transport Fever 2 Windows x64 Build 35924 and retain their
own `runtime/localhost-live/<session>/run-status.json` evidence.

- `save-load-20260908-baseline`: failed before rendering with Steam absent;
  retained as a failed run, not classified as save corruption.
- `save-load-20260908-steam`: both worlds loaded and produced a receipt-bound
  paired recovery archive at boundary 12. Diagnostic baseline only: companion
  changes were still in progress during this run.
- `save-load-20260908-train`: the old railway fixture loaded on both peers but
  never supplied industry-content inventory, leaving bootstrap blocked before
  commit 1. Stopped the exact disposable game PIDs deliberately after observing
  the persistent prerequisite failure. This is not a passing train restore.
- `save-load-20260908-final`: reproduced the initialization race above; stopped
  both disposable clients after recording the superseded preparation. Despite
  its name, this is a failed diagnostic run, not acceptance evidence.
- `save-load-20260908-fenced`: passed with metadata and freight guards installed. Freight
  checkpoint 5 preceded preparation 7; both native saves and ordered receipts
  produced verified archives at boundary 12, plan `3b4ed13a`. Audit: 11
  converged commits, two completed checkpoint barriers, no pending work or
  synchronization fault. Both disposable games and companions were closed.
- `save-load-20260908-fenced-r12--verified-reload`: the exact archived pair
  loaded, accepted `recovery.resume` at commit 1, and converged its fresh
  checkpoint without a session fault. The requested subsequent capture failed
  promptly on the content race above. Not counted as a passing full cycle.
- `save-load-20260908-fenced-r12--content-fenced-reload`: restored correctly,
  then exposed the missing host checkpoint tracking. Both peer content
  checkpoints had core `2697d530`, financial `416d3bf5`, and structural
  `dc3ae927`, but no host outcome. Stopped the disposable clients and retained
  `host-audit.ndjson` in this run directory before repeating the session.
- `save-load-20260908-fenced-r12--checkpoint-tracked-reload`: **passed** with
  the final code, reusing the exact boundary-12 archived bytes (no binary save
  edits). Restore completed at commit 1; the late-content checkpoint completed
  before preparation 6. Both peers then saved and published a new paired
  archive at boundary 11 in the new session, plan `802dd713`. Audit: 10
  converged commits, no pending physical work or session fault. All six
  settings/temporary-file cleanup flags are true and no test games remain.

The passing capture and final reload each retain `host-audit.ndjson` in their
run directory. Explicit comparison of both peers' capture and re-save
checkpoints passed for all six digests:

| State | Before save and after reload/re-save |
| --- | --- |
| Authoritative core | `2697d530` |
| Finances | `416d3bf5` |
| World structure | `dc3ae927` |
| Model | `9665165f` |
| Canonical identity | `be735887` |
| Vehicle synchronization | `5e3b581e` |

The initial restore checkpoint intentionally precedes fresh content
attestation and has a different core digest; after attestation the original
core matches exactly. This world has no tracked vehicles, so this successful
cycle does **not** qualify moving-train continuation. The older train-fixture
failure remains recorded above.

No native assertion, error reporting, or Steam-overlay hook was disabled.
The separate historical native dump/loader-lock interaction remains unproven
and is not claimed fixed. Successful save-browser traversal is empirical
coverage, not a guarantee for every existing save.

## Automated verification

The final full `tools/run_tests.ps1` gate passed: 162 main Lua tests, 386 Python
tests, 109 cross-language economy scenarios, freight parity/stress, launcher
and recovery PowerShell checks, syntax/source boundaries, release checks,
and the 1,024-event replay. The faithful Lua 5.1 interpreter was explicitly
selected through `TPF2MP_LUA`. Both native CTest tests also passed; no native
hook code changed. An earlier gate correctly refused overlay cleanup while
live games were open; subsequent gates ran with the games closed. Legacy
synthetic archive fixtures were updated to the real `function data()` format,
not exempted from metadata validation.
