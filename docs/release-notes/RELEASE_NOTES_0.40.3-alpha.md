# TPF2MP 0.40.3-alpha

This hotfix prevents a native game-thread failure while creating or editing a
line through the vanilla Line Manager. It remains compatible with state schema
31 and does not change the network, checkpoint, proposal, operation, passenger,
cargo, or freight schemas.

## Line-manager crash correction

- Ordinary `mainView.hover` events no longer invoke native line-entity lookups.
- Line selection now reads only explicitly named line/entity carrier fields
  instead of recursively treating coordinates, dimensions, colours and other
  numeric GUI values as possible entity IDs.
- Actual line selection, stop editing, renaming, deletion and other line
  mutations continue to retain their target for ownership and registration.
- The focused line-carrier parser lives in its own module so the GUI replay
  runtime remains within its enforced 650-line architecture boundary.

The defect was captured live under relay support ID
`mp-8c18530e0ea933fd`. Both peers completed the preceding physical operations,
then Player 1's crash handler identified
`guiHandleEvent(id="mainView", name="hover")`; the host subsequently emitted
60 consecutive game-thread watchdog failures while Player 2 remained connected.

## Regression coverage

- A coordinate-heavy regression sends 240 main-view hover events containing
  values that are also valid test line IDs and proves that no native entity or
  line-component lookup occurs.
- Line stop edits and existing line selection/ownership tests prove the fix does
  not disable legitimate Line Manager behavior.
- The complete deterministic Lua/model suite, 1,024-event replay, transport and
  cross-language parity checks pass.
- All 168 packaged Lua files and 72 PowerShell files pass syntax validation.
- All 197 Python tests pass.
- Updater integrity, transactional installation, rollback, launcher, relay,
  save-sync, recovery and restore tests pass.

Both players must install 0.40.3-alpha before creating or resuming a match.
