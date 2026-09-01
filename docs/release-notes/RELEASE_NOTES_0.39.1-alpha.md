# TPF2MP 0.39.1-alpha

This launcher-quality release keeps the `0.39` relay/network protocol and game
schemas unchanged.

## Launcher quality of life

- A first normal per-user install now asks before adding the stable
  `TPF2MP Multiplayer` desktop shortcut. Scripted installs retain explicit
  create/skip switches and updates never interrupt with this prompt.
- Opening the launcher starts a non-blocking release check. Private-repository
  checks may reuse an existing GitHub CLI or non-interactive Git Credential
  Manager login without opening an authentication dialog.
- A launcher-driven update independently verifies the installed manifest and
  stable version pointer, closes the old launcher, and starts the newly
  installed launcher automatically. Merely being up to date never triggers a
  restart loop.

## Relay launcher reliability

- Relay create/join wrappers now publish one validated protected receipt
  instead of duplicating the companion's machine-readable output.
- A valid durable relay receipt is authoritative when Windows reports a blank
  fast-worker exit code, fixing the observed `Failed relay-session-create with
  exit .` result after the room had actually been created.
