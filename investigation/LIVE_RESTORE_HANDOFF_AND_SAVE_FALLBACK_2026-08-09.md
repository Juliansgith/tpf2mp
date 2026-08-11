# Live restore handoff and Build 35924 save fallback

Date: 2026-08-09 (Europe/Amsterdam)

## Result

Session `restore-handoff-live-20260809-2127` reached a shared READY checkpoint
at boundary 11. Player 1 and player 2 independently saved their native worlds,
filed ordered load-bearing receipts, and retained receipt-bound archives. The
host generated and published verified v4 restore plan checksum `0b009dd3`; the
client received, verified, and bound the same plan. This proves the two-peer
receipt, plan-delivery, and archive handoff with exact live processes.

It does not prove the newly integrated unattended UI fallback or a fresh reload
from those archives. Those are the next live actions.

## Findings exposed by the run

1. Pinned Build 35924 contains an internal `SaveGame` command/tag but publishes
   no `api.cmd.make.saveGame` factory. A game-script-only automatic save cannot
   be claimed for this build.
2. The stock filename editor accepts at most 50 characters. The former readable
   `tpf2mp_<session>_<peer>_b<boundary>` name was truncated for normal session
   identifiers.
3. The localhost harness wrote `match-content-profile.json` only into its run
   directory while the watcher implicitly looked in the durable peer root.
4. Filing the first `recovery.save_receipt` left anchor readiness true but marked
   the preparation UI state `superseded`.
5. If a save path disappeared between watcher enqueue and companion read,
   `AnchorRequestStore.pending()` let the parse failure terminate the companion.
6. Re-saving after an accepted duplicate receipt could leave the watcher holding
   newer bytes while the result still attested the original hash.

## Hardened design

- Automatic names are now
  `tpf2mp_r_<session-adler32>_<p1|p2>_b<boundary>`, generated identically in Lua
  and PowerShell and bounded below 50 characters.
- The runtime still attempts a future compatible public save command, but its
  absence is diagnostic. After an eight-second grace period, the exact-process
  watcher invokes the ordinary stock Save UI. Same-machine peers share an
  exclusive session lock, so localhost windows cannot focus-race each other.
- The UI path remains authority-free: a receipt is filed only after an exact
  name appears, both load-bearing files stabilize, the boundary remains READY,
  and their hashes are accepted by the companion.
- Launchers pass the exact match-profile path to the watcher explicitly.
- Save receipts no longer supersede their own prepared boundary.
- Malformed/missing request inputs become isolated rejected results rather than
  escaping the companion poll.
- Before any archive is made, the watcher re-finds a save pair whose SHA-256
  values equal the accepted receipt. A later overwrite can never silently take
  the place of previously attested bytes.

## Automated evidence

Focused Lua tests prove cross-language-compatible names, the maximum boundary
name length, retry behavior, and READY/core gating. Python tests prove that a
receipt preserves preparation readiness and a missing save request is rejected
idempotently. PowerShell fixtures prove the READY-poll race, duplicate-receipt
byte selection, and the complete stock-UI input sequence with an exact bounded
output pair.

## Next live gate

Start a fresh two-process session with the updated bootstrap and watchers. Make
one small synchronized change, press **Prepare & Save Restore Point** once, and
touch neither window. Both bounded save names, both ordered receipts, the v4
plan, and both receipt-bound archives must appear without manual UI work. Then
close both processes and load **LATEST RESTORE** for each role, requiring the
mandatory post-resume checkpoint before play continues.
