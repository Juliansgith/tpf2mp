# Save-browser preflight follow-up — 2026-09-12

User constraint: do not launch or drive the game until explicit green light.
No game launch, UI input, save relocation, overlay setting change or native
hook patch was performed in this follow-up.

## Current evidence, not the older release summary

The repository already includes the September 8 selected-save metadata
validator and successful empty-world paired capture/reload evidence. See
[save/load reliability](SAVE_LOAD_RELIABILITY_2026-09-08.md). The native
dump/overlay loader wait remains unattributed; those successes do not certify
moving-vehicle persistence or fix every Load Game hang.

The remaining diagnostic gap was that the native browser inspects other
sidecars while the launcher validates only its selected pinned save. A valid
selected save therefore does not rule out a malformed unrelated sidecar.

## Change

`inspect-save-directory` performs a read-only, nonrecursive scan of native
`.sav.lua` sidecars using the existing non-executing serializer parser. It
reports suspect filenames and reasons, unreadable/changed files, and whether
file/byte/time budgets prevented a complete scan. It does not execute Lua,
move, delete, repair or rewrite any save. Limits: 2,048 matching entries,
64 MiB total reads, existing 32 MiB per-file limit, and an eight-second budget
checked between directory entries (not an interrupt of an individual parse).

Normal network launch writes `save-browser-preflight.json` in the local session
directory and warns before installing the runtime overlay or starting a game
if the scan finds suspect files or is incomplete. `NoLaunchGame` skips it.
Diagnostic failure also warns; selected-save validation remains enforced.
Reports remain local and are not newly uploaded to the relay.

This is deliberately advisory. Valid mod-authored Lua outside our serializer
subset is unsupported, not necessarily corrupt. Automatically hiding saves,
or preventing every launch because of such a file, would be unsafe. This
change improves diagnosis; it is **not** a proven fix for the native hang.

## Offline verification

Regression cases cover a valid selected save plus damaged unselected metadata,
preservation of every original byte, non-execution, nonrecursive inspection,
file/byte/time limits, oversized/non-UTF8 files and CLI reporting.
The launch script was syntax-checked without invoking it.

A read-only scan of this PC's detected Steam save directory completed:
11 sidecars, 15,497 bytes, zero suspect entries. No current local malformed
sidecar was found to explain a new hang.

The initial broad Python test attempt used a runtime missing the repository's
declared websockets/zstandard dependencies and failed imports. A dedicated
ignored `runtime/save-browser-venv` was created with those dependencies; this
does not change the system Python or deployed mod. Final results are retained
in `runtime/save-browser-offline-20260912-final.log`. Python unit tests mock
game-driving behavior; they are not real UI or full release-gate evidence.
The final Python run passed all 393 tests in 8.409 seconds; PowerShell syntax
and `git diff --check` passed as well. No commit, install or release was made.

## Waiting for green light

1. Repeat the pinned two-instance load with the new preflight report and
   existing timeout evidence, recording current source/content identity.
2. If it hangs with clean metadata, correlate the original native error and
   loader wait before proposing any native/overlay change. Do not suppress
   assertions or alter the user's global Steam settings to obtain a pass.
3. Run complete bus/tram workflows at both existing junctions and road splits,
   then compound demolition/terrain cases, moving-vehicle save/rehost and soak.
   The older reports are not new passes for this source revision.
