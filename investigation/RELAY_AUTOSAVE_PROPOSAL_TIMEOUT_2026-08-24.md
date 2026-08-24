# Relay autosave/proposal timeout — 2026-08-24

## Outcome

Secure-relay session `mp-82a4b6ad61de51f8` isolated a second cause of the
earlier player-2 save symptom. The relay did not stall and the companion did
not disconnect. Transport Fever 2 began an ordinary per-client autosave on
player 2 in the same second that player 2 received a physical station proposal.
The native save occupied the game for 256,781 ms, long enough for the host's
45-second physical-completion deadline to expire.

The session correctly faulted closed, but a stock autosave must not be allowed
to interrupt the ordered physical lane. Network launches now lease the native
autosave setting for the exact game process: ordinary per-client autosaves are
suspended for the match, while the existing coordinated READY-boundary save
flow remains available.

## Exact timeline

All times are Europe/Amsterdam on 2026-08-24. The centralized relay retained
both clients' redacted log/status stream under the non-secret support ID.

- `23:11:32`: host proposal `...:player1:64` finalized successfully on player 1.
- `23:11:32`: player 2 logged `Saving to file ...autosave_...player2...sav`.
  The native complexity line reported 674 population, 58,659 asset groups,
  984,803 assets, 1,115,953 models, and an estimated 5,816 MiB working shape.
- `23:12:10`: the host ordered sequence 65 with
  `proposal-completion-timeout:player2`; the session fault latched.
- `23:15:50`: player 2 finally logged a 53,532,582-byte native save and
  `Saving...: 256781 ms`. Only then could its game script consume the already
  ordered fault outcome.
- `23:17:19`: player 2 emitted a crash marker and shut down at `23:17:27`.

The host remained TCP-connected throughout the original deadline. Player-2
companion and launcher statuses continued updating, but no game-side physical
completion or fresh clock health could be produced while native serialization
owned the game. This distinguishes the failure from relay latency, packet loss,
or a companion deadlock.

The host's recovery panel then reported `waiting-for-ready-boundary`. That was
correct: the shared clock was not unanimously paused, player-2 readiness was
stale, the session was already faulted, and ordered work existed after the last
converged checkpoint. The recovery watcher did not start this stock autosave.

## Correction

`network_autosave_guard.ps1` now owns a current-user lease around
`settings.lua` for launcher-managed network games.

1. Before the exact game process starts, it records the player's prior
   `autosaveIntervalMinutes` and raises the in-match interval to at least 10,080
   minutes (one week).
2. The lease is bound to the exact executable, PID, and process start time.
3. A small hidden watcher restores only the autosave field after that exact
   process exits, retaining every other setting the game wrote.
4. A stale/crashed launcher lease is repaired on the next launch. An active
   lease refuses a second network game under the same Windows profile.
5. If another program or the user changed the field externally, cleanup does
   not overwrite that newer value.

The launcher exposes the guard receipt and explicitly distinguishes suspended
stock autosaves from coordinated recovery saves. The coordinated flow still
orders `recovery.prepare`, reaches an all-peer quiescent checkpoint, and only
then drives each peer's stock Save UI with a 20-minute completion allowance.

## Automated verification

- PowerShell parsing passes for the launcher, guard, watcher, and test files.
- The guard test proves `10 -> 10080 -> 10` across an exact child-process
  lifetime.
- The same test proves stale-process repair and preservation of an explicit
  external settings change.
- Source boundaries and release-manifest/transitive-tool validation pass.
- The broader suite reached the release-update tests while the live game was
  intentionally still open; that expected install-safety gate refused to run.
  A clean full run remains required after both live games close.

## Next live gate

Install the guarded release on both computers and start a fresh relay room.
Both launcher panels must report that native autosaves are suspended. Leave the
match open beyond player 2's former ten-minute autosave point while performing
one isolated construction at that boundary. No `autosave_...` line may appear,
and physical consensus must complete normally. Then use the coordinated
recovery control once at READY; a slow native save is acceptable there because
the ordered gameplay lane is already fenced.

