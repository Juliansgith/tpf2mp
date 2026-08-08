# Automatic first-fault evidence and randomized replay stress

Date: 2026-08-08 (Europe/Amsterdam)  
Prototype: `0.29.0-alpha`  
State schema: `26`

## Result

Every launcher-managed peer now preserves one local evidence bundle when its
companion first publishes a non-empty `sessionFault`. This is part of the
existing recovery watcher, so it creates no additional resident process and
does not alter authority, recovery, or game state.

The fault check runs before the watcher tests game-process liveness. A fault
that is immediately followed by a game crash therefore still captures the
bridge, companion state, native-hook status, and logs that remain on disk. The
watcher records the original fault, observation time, attempted flag, evidence
directory, `evidence.json` path, and any collector error in its atomic schema-3
status. It attempts the first fault exactly once; later errors cannot overwrite
the earliest cause.

## Bundle contents

`tools/collect_live_evidence.ps1` now captures:

- the selected peer bridge tree and companion status;
- the copied host audit, replayed from the immutable copy rather than the live
  append target;
- the launcher session state and recovery-watcher status;
- bounded tails (8 MiB per file) of the exact companion, game, menu
  coordinator, and recovery-watcher stdout/stderr paths named by that session;
- the ordinary game log and recent structured/error lines;
- any matching native-hook status files;
- source-versus-installed mod fingerprints; and
- a schema-3 summary with source path, copied path, original/captured byte
  counts, truncation flag, and SHA-256 for each session artifact.

The bundle stays under the peer's local `%LOCALAPPDATA%\TPF2MP\sessions` tree.
Nothing is uploaded. Logs can contain local paths and gameplay details, so a
player should inspect the directory before sharing it.

This is diagnosis, not recovery. The session remains faulted and paused; a
verified restore point or a fresh match is still required.

## Automated evidence

The PowerShell integration fixture publishes a fault for a deliberately absent
game PID. It proves the watcher captures first-fault evidence before reporting
`stopped-game-exited`, passes the exact session/peer/bridge identity, and keeps
the original fault. A second fixture runs the real collector against an
isolated installed-mod tree and verifies exact session-log bytes, game-log
capture, and matching source/install fingerprints.

The independent replay stress was expanded from 104 to 1,024 post-checkpoint
events. Seed `20260808` deterministically interleaves settlements, demo-market
re-registration, and autonomy freeze/unfreeze actions. More than 850 settlement
boundaries must survive exact residual accounting, the bounded in-save event
tail, bridge persistence, and independent Python replay. The focused run
verified all 1,024 events and finished at model digest `1ef1e452`.

## Remaining proof

A human fault should still be induced once in a disposable two-process session
to confirm that both peers expose their local summary paths in the launcher and
that the bundles contain the expected live native statuses. Automatic
rotation/retention and one-click coordinated rollback remain separate work.
