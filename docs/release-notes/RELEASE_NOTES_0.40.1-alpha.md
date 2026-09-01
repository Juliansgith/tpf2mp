# TPF2MP 0.40.1-alpha

This hotfix reduces the longest avoidable construction-consensus delay and
makes secure Relay Join robust when another local TPF2MP role already owns the
default loopback ports. It remains compatible with state schema 31 and does not
change any network, checkpoint, proposal, operation, passenger, cargo, or
freight schema.

## Faster construction completion

- Network construction replay now observes the delayed native wallet journal
  for a conservative 90-GUI-frame grace period instead of waiting for the
  historical 360-frame hard deadline whenever the native wallet remains
  neutral.
- A real native debit observed during the grace period still wins. When no
  debit appears and both wallet samples are stable, the already signed
  canonical construction cost completes settlement; periodic account
  reconciliation repairs any genuinely later native cache entry.
- Standalone behavior and the 360-frame emergency deadline are unchanged.
  Result diagnostics now report observed wallet mutation, canonical fallback,
  hard-deadline use, and total settlement frames.
- On the measured slow peer, this removes roughly 270 render frames from the
  critical path: approximately 24-29 seconds becomes about 6-8 seconds before
  ordinary relay and checkpoint completion.

## Same-PC relay reliability

- Relay Join probes the requested gameplay/save loopback port pair before
  startup. If another local host, joiner, or process owns it, Join selects the
  next free adjacent pair automatically.
- The selected local port is used consistently for starting-save reception,
  companion startup, and session diagnostics. Relay identity and remote
  transport are unchanged; players no longer need matching machine-local
  ports.
- A real two-listener socket regression test covers detection, remapping, and
  reuse of the preferred pair after it is released.

## Verification

- The complete source suite passes: 137 Lua tests, 7 transport-network tests,
  197 Python companion/relay/recovery tests, cross-language economy and freight
  parity, and the deterministic 1,024-event replay.
- All 167 Lua files and 71 PowerShell tool files pass syntax validation.
- Source-size boundaries, launcher/update behavior, release manifests,
  transactional installation, and rollback checks pass.

Both players must install 0.40.1-alpha before creating or resuming a match.
