# TPF2MP 0.43.0-alpha

This feature release promotes the fully qualified candidate following
`0.42.5-alpha`. Gameplay authority is now state schema `35`, checkpoint format
`5`, edge proposal format `5`, construction proposal format `7`, operation
format `4`, and native hook `0.19.0`.

## Shared authored calendar

- Network bootstrap freezes autonomous native date progression before the
  peers begin authoritative play.
- Save-owned match rules carry the shared start date and integer
  milliseconds-per-day rate.
- Existing ordered economy settlements advance a leap-safe canonical date, so
  calendar synchronization does not add another network round.
- Both peers project the authored date back into Transport Fever 2, keeping the
  HUD date and vehicle availability aligned with the checkpointed model.
- Lua and Python implementations use the same validation and date arithmetic.

## Construction breadth and geometry

- The release inventories all 52 stock non-building construction resources,
  plus every stock street, track, bridge, and tunnel resource in Build 35924.
- Headquarters identity is retained by the portable construction codec.
- Field-decoration and ground-texture constructions now materialize with their
  actual persistent native root shape.
- Exact second-station transactions from support session
  `mp-2b831d5eac67c488` are pinned and replayed sequentially, including their
  collateral building removals.
- Native qualification covers kilometre-scale straight and curved rail,
  grades, tunnels, road crossings, combined collateral demolition, steep-site
  stations, bridges, dense city stations, cleanup, and immediate rebuilding.
- Construction limits now fail closed for excessive graphs, modules,
  collateral removals, cyclic parameters, and excessive parameter depth.

## Qualification and regression coverage

- A populated two-process run completed 604.9 seconds with a real routed
  vehicle, automatic settlements and recovery, ten converged checkpoints, four
  synchronized station releases, zero vehicle faults, and no pending tail.
- Across 1,168 samples, maximum observed world-time skew was 0.315 seconds.
- The authored date advanced identically from `1940-01-02` to `1940-05-31`.
- New audits pin stock construction/resource coverage, practical GUI geometry,
  live second-station bytes, runtime performance, and source-tree cleanup.
- Vehicle lifecycle, passenger transfer/feeders, multi-hop freight,
  save/rehost, automatic recovery, relay, launcher, updater, and installer
  regression suites remain green.
- The packaged localhost harness now retires the PyInstaller companion child
  processes by exact executable, session, and peer identity, preventing a
  completed local test from leaving a stale session that blocks an update.

## Repository and documentation hygiene

- Maintained documentation now lives under `docs/`, with immutable historical
  notes under `docs/release-notes/`; `README.md` is the only Markdown file at
  repository root.
- Local Codex/Claude state and root handoff scratchpads are ignored instead of
  becoming product documentation.
- Packaging copies the canonical documentation tree rather than maintaining a
  second hand-written file list.
- The test gate now rejects version drift, mismatched release-note headings,
  broken maintained-document links, stale root-relative evidence paths, and
  new root Markdown clutter.

## Supported boundary

This remains a trusted two-player Windows x64 alpha for exact Transport Fever 2
Build 35924. It does not claim hostile-peer security, host migration, more than
two players, arbitrary script-heavy mod compatibility, or continuous vehicle
lockstep. Physical two-computer construction and long-session testing remain
the final human-facing gates.

Both players must install `0.43.0-alpha`; mixed versions are unsupported. Start
a fresh multiplayer session after updating.
