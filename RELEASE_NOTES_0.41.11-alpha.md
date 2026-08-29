# TPF2MP 0.41.11-alpha

This reliability release makes receipt-bound recovery periodic and restart-
safe, substantially reduces relay diagnostic noise, and hardens transient
launcher and relay lifetimes. Gameplay authority, state schema 34, checkpoint
format 5, construction proposal format 7, operation format 4, economy model
10, and native hook 0.19.0 are unchanged.

## Automatic recovery points

- Player 1 now orders the existing coordinated recovery workflow every 15
  minutes after the latest complete pair of signed save receipts.
- Automatic preparation waits for an idle, connected, checkpoint-converged
  session and never promotes an incidental checkpoint.
- A host-only journal marker lets companion restart adopt an interrupted
  preparation or finish receipts written immediately before restart.
- A three-minute bound orders `recovery.cancel`, releases its preparation
  fence, and restores the prior speed only while the session is healthy.
- If a peer disconnects after saving but before speed restoration, the restore
  point remains valid and the host remains alive with both games safely paused.
- The Multiplayer panel displays current automatic-recovery state, latest
  boundary, age, next due time, and any bounded error.

## Relay and launcher reliability

- Unchanged status is sampled every 20 seconds; critical connection, fault,
  receipt, recovery, and relay-channel transitions remain immediate.
- Identical log text is limited to once per minute, and routine game stdout is
  omitted unless it contains a failure marker.
- Relay metadata now records the nested ordered action type without retaining
  command payloads. Repeated raw clock-health and anchor-state frames are not
  stored a second time in the support timeline.
- The save tunnel exits after one verified and acknowledged bundle instead of
  reconnecting indefinitely.
- A failed Host launch closes only its exact credential-bound relay room. Join
  cannot destroy the room.
- Same-session retry now covers a strict allowlist of native-menu, companion-
  readiness, hook-startup, and paused-menu-wake failures before authority is
  ready. Identity, fingerprint, content, credential, and stale-traffic errors
  remain hard failures.

## Deterministic failures and verification

- Lua failure handling selects stable bounded `error`, `errorCode`, `detail`,
  `message`, or `reason` fields and never leaks allocator-dependent
  `table: 0x...` text into cross-peer consensus.
- Automatic recovery success, timeout, fault, restart, receipt-finalization,
  disconnect, cancellation, and strict-wire cases have adversarial coverage.
- Diagnostic sampling, action metadata, one-shot save transfer, launch retry,
  and exact-room cleanup have dedicated Python and PowerShell regressions.
- The complete Lua, Python, cross-language parity, launcher/updater, relay,
  recovery, packaging, syntax, and architecture suite passes. The separate
  relay service suite passes 27/27 tests.

Both players must install `0.41.11-alpha`. Mixed versions remain unsupported.
The remaining live gate is one physical two-computer match left running beyond
one automatic-recovery interval.
