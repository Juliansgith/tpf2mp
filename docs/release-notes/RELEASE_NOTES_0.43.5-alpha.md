# TPF2MP 0.43.5-alpha

This patch release adds a fail-closed compatibility gate for the exact mods and
DLC active in the synchronized starting save. Gameplay and protocol schema
versions are unchanged from `0.43.4-alpha`; the match-manifest format advances
to version 2 so active content becomes part of session identity.

## Active-content compatibility

- The companion reads Transport Fever 2's ordered active-mod table directly
  from the native `.sav` header, including Workshop items, local/game mods,
  TPF2MP itself, and automatically activated Urban Games DLC.
- Preflight resolves every entry on the local machine and records its declared
  major/minor version, load-order position, source kind, and a SHA-256 digest of
  simulation-bearing files. Missing dependencies and unsafe mod identifiers are
  rejected before a game can cross the authority boundary.
- Host and client compare the complete ordered inventory even if an aggregate
  fingerprint were ever equal. Rejections name the first missing, extra,
  reordered, wrong-version, or content-different dependency.
- ZIP mods are hashed by logical file content rather than archive metadata, so
  harmless repacking does not create a false mismatch. Presentation-only media
  is excluded, while scripts, models, construction data, configuration, and
  other gameplay-bearing resources remain bound.

## Launcher and diagnostics

- Fresh launches and recovery launches always derive compatibility from the
  exact pinned starting save; users do not need to enter a separate mod list.
- A persistent hash cache keeps repeat launches fast without trusting stale
  files: cache keys include the relevant path metadata and content inputs.
- Companion status and logs expose a compact active-content count and digest,
  while credentials and full local installation paths remain outside the wire
  inventory.
- A rejected handshake now closes its client socket cleanly and reports the
  actionable content mismatch instead of degrading into a generic timeout.

## Regression evidence

- Automated coverage parses synthetic native save headers and exercises
  Workshop, DLC, regular, missing, and unsafe dependencies; version, order, and
  digest mismatches; logical ZIP repacks; restore-manifest binding; and rejected
  network handshakes.
- The packaged one-file companion was smoke-tested with the new Zstandard save
  parser. A real 106-entry modded save resolved 102 Workshop mods, two official
  DLC entries, and two regular mods, with the cached repeat scan completing in
  about four seconds on the qualification machine.
- A disposable two-process live run with Urban Games' Legacy Vehicle Pack and
  TPF2MP passed 21 ordered commits, 13 controls, eight checkpoint barriers, and
  all expected proposal outcomes without a fault or pending action.
- The complete automated gate passes Lua/Python parity, GUI/native replay,
  network ordering, recovery, packaging prerequisites, architecture budgets,
  documentation checks, and deterministic replay.

## Supported boundary

This remains a trusted two-player Windows x64 alpha for exact Transport Fever 2
Build 35924. Both players must install `0.43.5-alpha`; mixed versions are
unsupported. Identical active content is now enforced, but that does not imply
that every script or executable mod is behaviorally compatible. Start a fresh
multiplayer session after updating.
