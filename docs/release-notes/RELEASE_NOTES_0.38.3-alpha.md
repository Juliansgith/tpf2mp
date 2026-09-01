# TPF2MP 0.38.3-alpha

This prerelease packages the gameplay-neutral performance work, launcher
hardening, connected-station correction, and exact typed construction replay
developed and live-tested after `0.38.2-alpha`.

## Faster construction and runtime

- Fresh schema-7 constructions now use Build 35924's typed native
  `BuildProposal` path when their shape is safely representable. A stock
  modular passenger station completed its native operation in 436 ms in the
  supported-API probe, instead of the 6.6–7.1 second helper calls observed in
  the earlier localhost session.
- Exact construction results use a strict GUI delta attestation and canonical
  proposal-derived identity, avoiding unsafe engine-thread reads of freshly
  generated construction userdata.
- Construction upgrades and removals retain an optimized, scheduled helper
  fallback until their replacement semantics have separate native proof.
- Idle engine, GUI, native bridge, checkpoint, telemetry, and companion paths
  now sleep or use bounded indexes instead of repeating unchanged work every
  update. Authored simulation, ordering, economy, ownership, and vehicle
  synchronization rules are unchanged.
- Localhost peers receive balanced CPU affinity and background-throttling
  protection, reducing the previous host/client performance imbalance.

## Building and station fixes

- Passenger stations snapped to an existing canonical track endpoint now pass
  the station-graph validator without leaking a local entity ID.
- Exact station replay binds the complete generated construction, station,
  station group, node, and edge graph and preserves the correct company debit.
- The two-process validator now exercises a typed station build, post-build
  checkpoint, and structural soak; the accepted run completed with matching
  core and structural digests and no proposal or checkpoint faults.

## Launcher and update robustness

- Host and Join use a bounded retry for the narrow native Load Game manager
  hang while keeping fingerprint, authority, and convergence failures
  fail-closed.
- Identical pinned starting saves are safely reusable on retry; partial or
  mismatched residue is still refused.
- Stale localhost companions and occupied ports are identified and cleaned up
  without terminating an unverified process.
- Session-state publication is atomic and reader-safe.
- The development-tree Update button correctly delegates to the installed
  versioned release instead of expecting a source-tree release manifest.

## Verification

- Two exact Build 35924 processes converged through typed station replay,
  finance, checkpoint boundary 18, and a 60-tick structural soak.
- Lua core: 137/137; transport-network: 7/7; alpha-readiness: 3/3.
- Cross-language economy, freight, transport parity, and 256-step freight
  stress passed.
- Lua, GUI, game-script, ownership, launcher, updater, transactional install,
  recovery, native-build, and package checks passed.
- Python: 181/181.

## Updating

Close every Transport Fever 2 instance, then use **CHECK / INSTALL UPDATE** in
the multiplayer launcher or run `%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd`.
The updater downloads the versioned ZIP and checksum from GitHub Releases,
verifies the clean source-bound manifest, and installs transactionally.
