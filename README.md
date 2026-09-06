# TPF2MP competitive multiplayer prototype

TPF2MP is an executable research prototype that adds competitive multiplayer
systems to Transport Fever 2. It contains two related modes:

1. a local hot-seat game with two persistent companies, separate wallets and
   logical assets; and
2. a restricted same-area network alpha in which two independent game
   processes replay supported actions and verify their results.

Current release: `0.44.0-alpha` (experimental testing release)

Complex placement combining building demolition, road/rail attachment and
terrain changes is not fully revalidated and may fail or fault the session.
Some variants and save/load scenarios remain unverified; intermittent native
Load Game stalls are still under investigation. Back up saves and update both
players. Read the [release notes](docs/release-notes/RELEASE_NOTES_0.44.0-alpha.md)
before testing.

Supported executable: Transport Fever 2 Build 35924, Windows x64

Network profile: exactly two trusted players, Player 1 ordering host

This is not general or hostile-peer multiplayer. Read [prototype status](docs/PROTOTYPE_STATUS.md)
for the exact claim and [remaining work](docs/REMAINING_FROM_BRIEF.md) for the
post-alpha boundary.

## What works

- two native companies with canonical ownership and independently reconciled
  finances;
- byte-pinned starting-save transfer, canonical entity identities, ordered
  actions, reconnect replay, and all-peer checkpoints;
- roads, tracks, bridges, tunnels, signals, waypoints, stations, terminals,
  depots, modular edits, portable constructions, collateral demolition, and
  ownership protection;
- line creation/editing/deletion and portable rail, road, tram, air, and water
  vehicle purchase, assignment, controls, replacement, and sale;
- synchronized pause/speed and per-station vehicle rendezvous;
- contested passenger demand, fares, transfers, bus/tram feeders, queues,
  vehicle loads, revenue, upkeep, score, and difficulty;
- destination-gated multi-hop freight with production, inventories, transfer
  stock, delivery, conservation, and revenue;
- model and physical town development plus a shared settlement-driven calendar;
- clean-save continuation and paired receipt-bound recovery;
- outbound-only authenticated TLS relay, automatic save delivery, support IDs,
  and bounded redacted diagnostics;
- transactional install, verification, update, rollback, and cleanup.

All unsupported or ambiguous consequential commands remain fail-closed. Native
agents, floating income text, some stock history, and mid-leg coordinates are
cosmetic where Build 35924 exposes no safe authoritative write path.

## Install and play

For a packaged build, extract the ZIP and run:

```text
INSTALL_TPF2MP.cmd
```

Then open the installed **TPF2MP Multiplayer** launcher on both computers.
Leave **Use secure relay** enabled unless using a trusted LAN/private VPN.

1. Player 1 selects a starting save, creates a session, copies the opaque join
   code, and launches Host.
2. Player 2 pastes the code, prepares Join, and launches after Host reaches the
   title screen. The starting save is delivered and verified automatically.
3. Both players click **MULTIPLAYER** on the Transport Fever 2 title screen.
4. Begin only when both in-game Alpha Status panels report `READY`.

Both computers must run the same TPF2MP version and exact supported game build.
The launcher reads the starting save's ordered active-mod/DLC table, verifies
that every dependency exists locally, hashes its simulation-bearing files, and
refuses authority when a dependency, version, load-order position, or content
digest differs. The complete player flow, saving, recovery, and bug-report instructions are in the
[public alpha guide](docs/PUBLIC_ALPHA_GUIDE.md).

## Authority model

For supported gameplay, the issuing game captures a portable intent before
native mutation. Both peers preflight the same canonical resources, ownership,
and world boundary. Player 1 orders the action; each process reconstructs it
against its own local IDs and reports canonical outputs and physical state.
Finance commits only after agreement, followed by another all-peer checkpoint.

Construction is physically single-flight. A bounded queue retains ordinary
short topology sequences, while expensive construction previews use a
latest-only lane to prevent delayed ghost builds. Unsupported actions reject
before mutation; changed or mismatched post-commit worlds fault and require a
proven restore boundary.

Vehicles simulate locally between synchronized station releases. This bounds
route-phase drift but is not continuous coordinate lockstep.

## Current evidence

Development leading to `0.44.0-alpha` passed real stock-UI two-instance bus,
electric tram, empty-truck, passenger-aircraft and passenger-ship journeys,
plus selected construction, rail purchase, road crossing and terrain cases.
These are specific workflows, not blanket carrier or construction coverage.
The full physical UI matrix is incomplete. Historical passes are bound to
their tested source revisions, not automatically to the final release package.
See the [2026-09-06 qualification](investigation/TRANSPORT_UI_QUALIFICATION_2026-09-06.md).

Earlier `0.43.5-alpha` qualification included (not all rerun on this revision):

- a 604.9-second populated two-process run with 1,168 samples;
- ten converged checkpoints, four station releases, zero vehicle faults, and
  maximum observed world-time skew of 0.315 seconds;
- identical authored/native date progression from `1940-01-02` to
  `1940-05-31`;
- automatic paired recovery capture and successful restore;
- explicit coverage of every stock non-building construction family and
  practical long-track, bridge, tunnel, crossing, demolition, city-station,
  and slope-station geometry;
- a green Lua/Python/PowerShell/native/replay/package test gate.

See [the consolidated qualification](investigation/ALPHA_QUALIFICATION_2026-09-01.md)
and [the investigation index](investigation/README.md).

## Development

Run the complete source gate from a PowerShell prompt:

```powershell
.\tools\run_tests.ps1
```

The separate [real in-game UI regression harness](docs/LIVE_UI_TESTING.md)
drives two windowed clients through native controls and checks both worlds.
Its UI coverage gate does not count source tests or prepared-command tests as
proof of player-click behaviour; uncalibrated/unrun cases remain uncovered.

The same gate runs in GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml))
on every push and pull request. The Windows runner builds its own Lua 5.1.5
with `tools/ci/build_lua51.ps1`; `TPF2MP_LUA` and `TPF2MP_PYTHON` override the
interpreters the gate uses. The gate first checks that the interpreter formats
numbers like the game's C runtime: canonical digests hash `%.17g` text, and the
MSVCR80-linked Lua for Windows misrounds ties, so it is refused with build
instructions rather than allowed to pin wrong digests. A second job configures,
builds, and CTests the native hook with MSVC. Signature validation against the
real Build 35924 executable needs the game and remains a local step of the
release build.

Build and transactionally verify a clean release bundle:

```powershell
.\tools\package_release.ps1 -Version 0.44.0-alpha
```

Publishing requires a clean commit, matching manifest, SHA-256 sidecar, release
notes, and explicit confirmation:

```powershell
.\tools\publish_github_release.ps1 `
  -Version 0.44.0-alpha `
  -ReleaseNotesPath .\docs\release-notes\RELEASE_NOTES_0.44.0-alpha.md `
  -ConfirmPublish
```

The package process runs the full suite, rebuilds the native DLL/injector and
one-file companion executable, writes per-file hashes and schema metadata, and
performs an isolated install/verify/uninstall round trip. See
[distribution and updates](docs/DISTRIBUTION_AND_UPDATES.md).

## Repository map

- `tpf2_mp_1/` — installable game mod and authoritative Lua runtime;
- `companion/tpf2mp/` — protocol, sequencer, replay, relay, and recovery tools;
- `native/` — exact Build 35924 hook, injector, signatures, and MinHook pin;
- `tests/` — Lua, Python, replay, lifecycle, GUI, and fixture tests;
- `tools/` — launch, validation, evidence, packaging, and distribution scripts;
- `docs/` — maintained guides, architecture, status, design, and release notes;
- `investigation/` — dated evidence and reverse-engineering reports;
- `runtime/` — ignored generated sessions, binaries, saves, and live evidence;
- `.github/workflows/` — continuous integration: the automated code gate and
  the native hook build on every push and pull request;
- `LICENSE` — MIT license; third-party notices live in
  [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

Start at the [documentation index](docs/README.md). The
[architecture](docs/ARCHITECTURE.md) defines module and authority boundaries,
and the [alpha release checklist](docs/ALPHA_RELEASE_CHECKLIST.md) defines the
remaining human acceptance run.

## License

TPF2MP is released under the [MIT License](LICENSE). Vendored and build-time
third-party components, and the boundary with the game itself, are listed in
[docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md). Transport Fever 2
is not redistributed, and this project is not affiliated with or endorsed by
Urban Games.

## Explicit limits

Do not advertise this build for untrusted opponents, host migration, more than
two players, arbitrary executable mods, another Transport Fever 2 executable,
or automatic in-place repair of divergent native worlds. These are visible
post-alpha gates, not hidden promises.
