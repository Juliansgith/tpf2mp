# TPF2MP 0.39.0-alpha

This is the first alpha with an integrated outbound-only Internet transport,
automatic starting-save delivery, and centralized privacy-bounded support
diagnostics. Direct LAN/private-VPN mode remains available.

## Secure relay

- The launcher enables **Use secure relay** by default. Host creates a
  short-lived room and shares one opaque `TPF2MP1...` join code; Join validates
  that code locally before launch. No game or save-transfer port is exposed on
  either player's network.
- Gameplay and save streams use independent authenticated WSS channels. Host
  remains the commit-ordering authority; the relay never simulates the game,
  edits commands, or becomes an alternative authority.
- Each room has independent 256-bit Host and Join credentials. Tokens travel
  only in authorization headers, are held in current-user-only local files,
  and are stored server-side only as keyed SHA-256 digests. Roles, rooms, and
  channels cannot be exchanged; duplicate roles and mismatched match-content
  fingerprints fail closed.
- Lost tunnels trigger the existing pause/reconnect/backlog fence. There is no
  silent direct-network fallback.
- Both clients upload only named, bounded text/status sources. The client and
  server redact credential-like fields, bearer values, invite codes, local user
  paths, and IP addresses. Raw save files, command payloads, memory dumps, and
  arbitrary files are never uploaded.
- The relay retains bounded protocol metadata and redacted diagnostics under a
  non-secret `mp-...` support ID. Operators can inspect one ID through a
  protected admin API or local server command.
- The relay is a separate repository and deployment unit. Its supplied
  container runs as an unprivileged UID with a read-only root filesystem,
  dropped capabilities, resource limits, a dedicated data volume, loopback
  binding, and TLS reverse-proxy isolation.

## Automatic starting-save sync

- Host pins `.sav`, `.sav.lua`, and optional `.jpg`; Join receives the complete
  immutable set automatically over the relay before the ordinary content
  fingerprint is created.
- Every file and whole bundle are SHA-256 verified. Metadata/preview install
  first and `.sav` is renamed last, so interruption cannot expose a loadable
  partial save. Existing different saves are never overwritten.
- Receipt-bound restore remains peer-specific and is deliberately not replaced
  by copying Host's restore save to Join.

## Optimistic line-manager recovery

- A new vanilla line can be adopted after a temporary discovery binding, and a
  genuinely retired empty optimistic line can be recreated once through the
  authorized path. Manifest-bound or referenced lines still fail closed.
- Failed operation receipts carry bounded peer-local error detail without
  adding that diagnostic text to the consensus digest.

## Validation

- The existing complete project suite passes: 137 Lua tests, 196 Python tests,
  cross-language economy/freight/transport parity, PowerShell/CMD parsing, and
  installer/updater safety.
- Twenty-five relay-specific service tests cover authentication, cross-session rejection,
  duplicate roles, fingerprint mismatch, redaction, storage quotas, retention,
  tunnel teardown, audit-writer failure, and bounded rate-limiter state.
- A local full-stack run transferred a 54,455,136-byte native save triplet and
  gameplay traffic through the relay, synchronized both companions, delivered
  diagnostics for both roles under one support ID, then survived relay loss and
  reconnect without a match fault.
- A repeatable cross-repository test also round-trips both byte streams through
  the real packaged client and proves secrets, invite codes, local user paths,
  and IPv4/IPv6 addresses are redacted before transmission.

The remaining acceptance gate is deployment behind a real HTTPS endpoint and
one fresh two-computer match through that endpoint.
