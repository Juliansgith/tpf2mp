# Recover from the host snapshot

This is an explicit takeover, separate from paired, receipt-bound recovery.
Both peers load the **same host `.sav` and `.sav.lua`**, discard the old
session's control state, and establish a fresh checkpoint. Player 2's old
world is not used. The host snapshot's canonical identities, companies,
account balances/loans, economy, cargo and vehicle round cursors are retained.

## Use

1. Pause the host and use the game's normal Save Game dialog to save under a
   new name. Wait for saving to finish. Keep the original faulted-session
   saves and logs; do not overwrite your last verified recovery point.
2. Close both games and their old session. Choose a **new session ID** in the
   multiplayer launcher. Select the host save, not the client's save.
3. Enable **Recover from HOST snapshot** on both launchers. Host launches
   first; Join downloads the host save using the existing save-sync flow and
   launches with the same option. Relay Join downloads it automatically.
4. Gameplay remains fenced until both independently loaded copies agree on
   their fresh checkpoint. Native company controls are rebound to each peer.

For scripted launches, `start_network_session_retry.ps1` and
`start_relay_network_session.ps1` accept `-HostSnapshotRecovery` alongside
their usual parameters. Direct Join must first sync the host's starting save.
The takeover policy is included in the match fingerprint, so an ordinary
continuation cannot silently join a takeover session.

## Scope and safeguards

- Source must be a current-state-version, initialized player1 network save
  with a running match and valid canonical account data.
- Old proposal/operation queues, fault barriers and clock generations are
  retired, not replayed. The source files remain unchanged; the adopted state
  records source identity and retired-work counts.
- Both copies use the host's physical snapshot, even if its last operation
  was only partly applied. This is choosing a new common baseline, not
  undoing that operation or replaying client-only work.
- Unowned native mutation residue is not safely adoptable yet and is refused.
  Corrupt metadata, invalid state, mismatched content or a failed fresh
  checkpoint are also refused. This is not a promise to recover every fault.
- A recurring game/mod bug may recur after recovery. Moving-vehicle behavior
  requires live qualification; cursor restoration has regression coverage.

The existing verified paired-archive mode is unchanged and remains preferable
when rolling back to a proven pre-fault boundary is desired.
