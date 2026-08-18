# TPF2MP 0.38.2-alpha

This corrective prerelease fixes the automatic installer handoff discovered while updating a real `0.38.0-alpha` installation.

## Fixed

- The updater now invokes the downloaded release installer with a named-parameter hashtable instead of array-splatting parameter tokens under Windows PowerShell 5.1.
- The installer accepts the one exact malformed handoff emitted by the `0.38.0-alpha` and `0.38.1-alpha` updaters, allowing those versions to bootstrap directly into the corrected updater without a manual reinstall.
- Unexpected, duplicated, or incomplete legacy arguments still fail closed.
- The updater test now completes a real local ZIP extraction and installer invocation, verifies paths containing spaces, and checks the resulting handoff receipt.
- The transactional installer test now exercises the bounded legacy-updater compatibility path.

## Updating

Existing `0.38.0-alpha` and `0.38.1-alpha` installations can run `UPDATE_TPF2MP.cmd` again or use **CHECK / INSTALL UPDATE** in the launcher. The old updater performs the download; the `0.38.2-alpha` installer recognizes and repairs its historical handoff shape.

The supported game/runtime profile and gameplay functionality are otherwise unchanged from `0.38.1-alpha`.
