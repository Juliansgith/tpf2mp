# TPF2MP 0.44.2-alpha

Save/load reliability and opt-in host snapshot recovery. This remains an
experimental testing release, not a guarantee that every fault is recoverable.

## Changes

- Validate selected save metadata without executing Lua; reject malformed,
  truncated or trailing-payload sidecars before launch. Recovery archives
  validate their immutable copies before publishing a restore manifest.
- Wait for content agreement and freight initialization before preparing a
  recovery point. Track late-content checkpoints on the host, including after
  companion journal recovery; report superseded preparations promptly.
- Check that Steam is running before direct launch. Local two-instance tests
  use distinct save names to avoid colliding crash-save filenames.
- Add **Recover from HOST snapshot** to the launcher. Both peers load the
  same host save in a new session, retain its durable multiplayer state,
  retire old faults and pending commands, and must agree on a fresh checkpoint
  before gameplay resumes. Both launchers must enable the option. It does not
  undo partial host changes or replay client-only work; unowned native mutation
  residue is refused. Preserve backups and prefer a verified pre-fault restore
  point when available.
- Restore vehicle authorization round cursors from the agreed shared-save
  continuation checkpoint.
- Include the intervening transport fixes for bounded frame reads and stalled
  gameplay socket writes.

## Verification and limits

- A real two-instance paired save, reload and subsequent save passed during
  development. Both peers retained matching core, finance, structure, model,
  canonical identity and vehicle-sync digests. The fixture had no tracked
  moving vehicles; this is not moving-train recovery qualification.
- Automated coverage includes malformed save metadata, preparation ordering,
  checkpoint journal recovery, host takeover on both peer identities, retained
  finances, retired work, source preservation and unsupported-source refusal.
- The native host-takeover attempt was blocked at the main menu by Windows
  foreground/UI automation failure. No world loaded: **in-game host takeover
  and its subsequent save/reload remain unverified**. The earlier paired-mode
  pass does not qualify takeover or the final versioned package.
- Binary save corruption, arbitrary Lua metadata programs, every native Load
  Game stall, moving-vehicle recovery and the broader construction/transport
  matrix are not certified. A recurring game/mod defect may recur after reload.

See the [save/load evidence](https://github.com/Juliansgith/tpf2mp/blob/v0.44.2-alpha/investigation/SAVE_LOAD_RELIABILITY_2026-09-08.md),
[takeover evidence](https://github.com/Juliansgith/tpf2mp/blob/v0.44.2-alpha/investigation/HOST_SNAPSHOT_RECOVERY_2026-09-08.md)
and [takeover instructions](https://github.com/Juliansgith/tpf2mp/blob/v0.44.2-alpha/docs/HOST_SNAPSHOT_RECOVERY.md).

## Update

Back up saves, close the old session, update **both players to 0.44.2-alpha**,
and create a new session. Windows x64 / Transport Fever 2 Build 35924 and
exactly two trusted players remain required. Native hook and protocol schema
versions are unchanged. Host migration and automatic repair of arbitrary
faulted worlds remain unsupported.
