# Automatic native restore save — 2026-08-09

> Superseded live finding: pinned Build 35924 does not publish the assumed
> `api.cmd.make.saveGame` factory and truncates normal session-based names at 50
> characters. The guarded stock-UI fallback and boundary-11 handoff evidence are
> recorded in [LIVE_RESTORE_HANDOFF_AND_SAVE_FALLBACK_2026-08-09.md](LIVE_RESTORE_HANDOFF_AND_SAVE_FALLBACK_2026-08-09.md).

Prototype `0.37.0-alpha`, state schema `29`, checkpoint format `5`, and native
hook `0.16.0` replace the last stock Save-dialog step in coordinated restore
preparation with a bounded automatic native command.

## Previous boundary

The already live-proven restore experiment ordered a shared pause, waited for
quiescence and a fresh all-peer checkpoint, then required each player to open
the stock dialog and save. The watcher hashed each stable native save, filed a
distinct ordered `recovery.save_receipt`, built a schema-2 restore plan, and the
two games later reloaded, passed `recovery.resume`, converged a mandatory fresh
checkpoint, and resumed train service.

That proved receipt-bound restore authority, but the manual click could happen
late or against the wrong preparation boundary.

## Automatic request

`recovery_native_save_runtime.lua` now observes the companion projection after
each status poll. It issues `api.cmd.make.saveGame(name)` through the normal
command helper only when all of these remain true:

- the game is in network mode;
- the companion reports an exact positive READY boundary;
- both local and companion preparation state report `ready` at that boundary;
- the companion's preparation checkpoint is that same boundary; and
- the current local core digest equals the READY checkpoint core.

The deterministic peer-local name is
`tpf2mp_<session>_<peer>_b<boundary>`. Session and peer identities are strictly
bounded and restricted to safe filename characters. A boundary is requested at
most once after success. Rejection or submission failure receives at most three
attempts with a 60-update cooldown. A missing callback is treated as failure
after a conservative 1,800 updates, and a callback from an earlier attempt
cannot overwrite the active retry. Loading a save discards the old in-process
diagnostic so a stale command state cannot suppress a future READY request.

The runtime record is intentionally machine-local and outside the authored
digest. The native command merely creates a candidate file; it never grants
restore authority.

## Stable file and receipt authority

`watch_recovery_saves.ps1` still requires a complete stable `.sav`/`.sav.lua`
pair (and archives the preview when present), rechecks that the same boundary is
READY, hashes both load-bearing files, and submits an ordered receipt. A restore point exists
only after both distinct pinned peers file receipts for the same boundary, core,
and convergence key.

The game and watcher poll the same companion status independently. A fast save
can finish just before the watcher's first READY observation. To avoid losing
that valid file, schema-6 watcher state admits only the *exact* automatic name
inside a small pre-observation grace window of `max(4, 2 * pollSeconds)`.
Arbitrary correctly prefixed manual fallback saves must still be created after
the watcher observes READY. This does not broaden restore authority: stability,
current READY state, hashing, ordered receipt validation, distinct peers, and
restore-plan verification remain mandatory.

The two peer save sets need not be identical because native saves can contain
machine-local identifiers. Their receipts bind each peer's load-bearing pair to the identical
canonical boundary and convergence proof; each peer reloads its own archive.

## Offline proof

The focused Lua runtime tests cover:

- strict automatic naming and unsafe identity rejection;
- one request at a matching READY boundary and duplicate suppression;
- receipt-filed terminal state;
- callback rejection/loss, cooldown, stale callbacks, and the exact
  three-attempt cap;
- refusal when the current core differs; and
- stale callback safety.

The functional PowerShell watcher fixture uses a live pinned process and creates
an exact automatic save immediately before its first READY poll. It proves that
the race is admitted, stabilized, submitted, and accepted while the ordinary
first-fault/retry fixtures continue to pass.

No game process was launched for this slice. `SaveGame` is known from the exact
Build 35924 command table and public/mirrored command factory, but the automatic
end-to-end path is not described as live-proven yet.

The subsequent automatic handoff slice distributes the resulting verified plan
to player2 and gives the launcher strict local discovery; see
[automatic restore-plan handoff](AUTOMATIC_RESTORE_PLAN_HANDOFF_2026-08-09.md).

## Next live gate

In a disposable two-process session with an active service and non-zero freight
or passenger state:

1. press **Prepare & Save Restore Point** once;
2. verify both worlds pause and both peer-specific saves appear;
3. verify both ordered receipts and the host restore plan name the same boundary;
4. inspect the archived hashes and peer identities;
5. close both games, reload each peer's own archive under the derived session;
6. require `recovery.resume` plus its mandatory fresh checkpoint; and
7. verify lines, vehicles, loads, stocks, balances, bindings, and train rounds
   before resuming play.

Automatic rollback/relaunch remains a later slice. Failure at any step stays
paused and requires explicit recovery; no divergent live geometry is patched.
