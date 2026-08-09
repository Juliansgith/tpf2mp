# Release source provenance

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

The format-1 release manifest authenticated every packaged byte, but it did not
identify the source revision that produced those bytes. Two archives carrying
the same prototype version could therefore have different hashes without a
machine-readable way to relate either archive to Git. This weakened audit and
support work even though it did not permit unnoticed file tampering.

## Resolution

New packages write release-manifest format 2. Its `source` object contains the
exact lowercase 40-character Git commit and a real boolean `dirty` flag. The
packager resolves both directly from the repository and refuses a dirty tree by
default. `-AllowDirtySource` is an explicit development-only override; such an
archive remains verifiable but the installer verifier prints a warning.

The shared verifier accepts format 1 for existing archives and format 2 for new
ones. Format 2 fails closed when the source object, full commit, or boolean flag
is absent or malformed. New format-2 packages also record the operation schema;
that later-added field is optional for compatibility with earlier format-2
archives and strictly positive whenever present. Install verification exposes
`manifestFormat`, `sourceCommit`, `sourceDirty`, and the recorded or explicitly
unrecorded operation schema in JSON as well as human-readable output.

## Evidence contract

`tests/run_release_manifest_tests.ps1` now proves:

- valid format-2 provenance round-trips;
- an earlier format-2 manifest without operation-schema metadata remains valid;
- malformed or missing provenance is rejected;
- the dirty flag cannot be a truthy string masquerading as a boolean; and
- a valid historical format-1 manifest still verifies.

The final release gate remains `tools/package_release.ps1`, including its
temporary install/verify/uninstall round trip. A clean package run additionally
proves that the recorded commit is the committed tree used for the archive.
