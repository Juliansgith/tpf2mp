# TPF2MP 0.43.3-alpha

This patch release hardens construction replay and its exact two-process
validation after `0.43.2-alpha`. Gameplay and protocol schema versions are
unchanged.

## Construction replay hardening

- Connected road-depot repair now revalidates persisted source transactions
  and strictly checks the helper node, helper edge, endpoint orientation,
  finite positions, unique retained slots, and either internal-node ordinal
  before native materialisation.
- Native construction output deltas must be dense numeric arrays. Sparse,
  keyed, duplicate, invalid, and over-limit entity lists fail before canonical
  output binding.
- Derived station and station-group replacements are preflighted against a
  copied canonical registry and committed together, removing their dependency
  on caller-level rollback for atomicity.

## Recoverable build rejection

- Exact network validation now correlates physical proposal outcomes by
  canonical transaction digest instead of aggregate completion counts.
- A symmetric native terrain rejection is retained as evidence, checkpointed,
  and followed by the next deterministic candidate rather than leaving the
  validator waiting indefinitely.
- The localhost harness now rejects missing populated fixtures or missing
  independently captured industry registries before launching an impossible
  test, and verifies cleanup even when a managed overlay came from an
  interrupted earlier run.

## Regression evidence

- A fresh exact two-process populated run completed 21 converged commits, four
  accepted physical proposals, one safely checkpointed rejection, eight clean
  checkpoint barriers, and zero faults or pending work.
- Current-build native probes passed kilometre-scale track, curves, grades,
  tunnels, road crossings, collateral demolition, a sloped station, rail
  facilities, road assets and junctions, airports with aircraft movement, and
  harbors with ship movement.
- The complete automated gate passes 154 Lua tests, 227 Python tests,
  cross-language parity, integration, packaging, installer, updater, relay,
  recovery, lifecycle, documentation, and architecture-boundary checks.

## Supported boundary

This remains a trusted two-player Windows x64 alpha for exact Transport Fever 2
Build 35924. Both players must install `0.43.3-alpha`; mixed versions are
unsupported. Start a fresh multiplayer session after updating. Mouse-preview
edge cases and arbitrary third-party scripted constructions remain explicit
human compatibility tests rather than claimed universal support.
