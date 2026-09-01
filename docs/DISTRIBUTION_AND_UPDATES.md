# TPF2MP installation and updates

## Install and launch

Extract the release ZIP and double-click `INSTALL_TPF2MP.cmd`. The installer:

- verifies every packaged file against `release-manifest.json`;
- finds the active Transport Fever 2 Steam userdata profile;
- stages and verifies the mod before replacing an older install;
- preserves recoverable backups if anything is replaced;
- installs versioned support files under `%LOCALAPPDATA%\TPF2MP`;
- creates stable Launch, Update, Verify, and Uninstall commands there; and
- on the first normal per-user install, asks whether to add
  `TPF2MP Multiplayer.lnk` to the desktop.

The stable commands do not change when a new version is installed:

```text
%LOCALAPPDATA%\TPF2MP\LAUNCH_TPF2MP.cmd
%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd
%LOCALAPPDATA%\TPF2MP\VERIFY_TPF2MP.cmd
%LOCALAPPDATA%\TPF2MP\UNINSTALL_TPF2MP.cmd
```

The extracted release also remains directly usable through its own
`LAUNCH_TPF2MP.cmd` and `UPDATE_TPF2MP.cmd`.

## Safe updates

The multiplayer launcher checks for an update in the background whenever it
opens. Use its update button, or double-click the stable
`UPDATE_TPF2MP.cmd`, to install one. After a launcher-driven update verifies
the new signed install, the old launcher closes and the new version opens
automatically. Updating is refused while Transport Fever 2 or a multiplayer
companion is running. The updater:

1. reads versioned releases from `Juliansgith/tpf2mp`;
2. selects only a newer semantic version on the configured alpha channel;
3. downloads `TPF2MP-<version>.zip` and its SHA-256 sidecar (or GitHub asset
   digest);
4. rejects path traversal, duplicate paths, links, oversized archives,
   downgrades, dirty builds, checksum failures, and manifest failures; and
5. invokes the rollback-safe installer.

An update is deliberately not taken straight from the `main` branch. The game
needs a compiled companion EXE and exact-build native hook, so a tested GitHub
Release is the deployable unit.

## Private GitHub authentication

While the repository is private, each authorized tester must authenticate with
their own read access. The updater tries, in order:

1. `TPF2MP_GITHUB_TOKEN` or `GITHUB_TOKEN` from the current environment;
2. an existing `gh auth login` session; and
3. Git Credential Manager through the installed `git` command.

No token or private SSH/deploy key is stored in the package, logs, manifest, or
repository. Embedding a deploy private key would let anyone who receives the
ZIP clone the private repository; even a read-only key would destroy its
confidentiality. Once the repository or release feed is public, anonymous
updates work without authentication.

## Publishing an update

Publication intentionally requires a clean worktree and a package whose
manifest names the exact current commit. After tests, commit, and push:

```powershell
.\tools\package_release.ps1 -Version 0.43.2-alpha
.\tools\publish_github_release.ps1 `
  -Version 0.43.2-alpha `
  -ConfirmPublish
```

The publisher obtains the developer's own GitHub credential, creates a draft
release at the manifest's exact commit, uploads the ZIP and checksum, and only
then publishes it. A failed upload remains a visible draft for repair rather
than exposing a partial update.

Every published update needs a new semantic version. Reusing the same version
for different bytes is intentionally not an automatic-update path.
