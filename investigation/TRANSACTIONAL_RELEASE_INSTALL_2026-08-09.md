# Transactional release installation

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

The installer checksum-verified and staged both copies, but it committed the
versioned support bundle, active game mod, and `current.json` pointer in separate
steps. A failure while copying the mod or running post-install verification
could leave those three surfaces on different builds. The existing backup made
manual recovery possible but did not perform it automatically.

## Resolution

Installation is now one rollback-capable transaction:

1. validate a private support staging tree;
2. archive and replace the same-version support bundle;
3. stage, archive, and replace the active game mod;
4. verify the installed bundle and installed mod; and
5. atomically replace `current.json` only after verification succeeds.

Any failure restores the prior mod and support bundle, preserves the previous
current pointer byte-for-byte, and removes generated staging trees. Backup names
carry millisecond time plus a random suffix so repeated same-version installs do
not collide. Successful schema-2 `current.json` files also record manifest
format, source commit, and source dirty state.

Rollback deletes only the newly generated copies at the two exact validated
install targets; the source archive remains intact and every pre-existing copy
is restored from its recoverable backup.

## Adversarial proof

`tests/run_release_install_transaction_tests.ps1` constructs a manifest-valid,
checksum-valid bundle whose companion is deliberately not a Windows executable.
That reaches post-copy verification only after both swaps, then fails. The test
requires the old support tree, old mod tree, and old `current.json` bytes to be
restored exactly, with no staging or detached-backup residue.

The same fixture then takes the explicit no-run verification path and proves a
successful transaction writes schema-2 provenance, installs byte-identical mod
copies, and preserves both old trees as recoverable backups. The distributable
package self-test no longer skips integrated installer verification, and still
runs its separate exact-native verifier afterward.
