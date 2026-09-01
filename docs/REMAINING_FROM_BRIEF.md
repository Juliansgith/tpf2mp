# What remains from the TPF2MP brief

Current release: `0.43.1-alpha`

Last reviewed: 2026-09-01

## Bottom line

The restricted trusted-peer two-player alpha is implemented. The remaining
alpha work is primarily physical-PC endurance, compatibility evidence, balance,
and UX—not discovery of a synchronization architecture.

The broader original ambition, “general Transport Fever 2 multiplayer,” still
requires substantial product work. The distinction matters: a missing
two-computer receipt does not mean the implemented command is absent, while an
unsupported engine command or script-heavy mod is a genuine authority gap.

## Before calling the alpha mature

1. **Physical two-computer endurance.** Run several multi-hour relay matches on
   different machines, GPUs, save sizes, and network qualities. Exercise both
   peers as builders and require final evidence reports, checkpoints, recovery
   receipts, and clean teardown.
2. **Dense gameplay matrix.** Combine long terrain-heavy rail, public-road
   crossings, bridges/tunnels, dense modular stations, deletion queues, several
   lines, signals, and multiple simultaneous vehicles in one continued save.
3. **Economy and network play.** Complete passenger transfer/feeder and positive
   multi-hop freight scenarios with ordinary player-built networks, then tune
   demand, fares, upkeep, growth, and difficulty over long 1850–2030 play.
4. **Disconnect and restore UX.** Repeat reconnect within the grace period,
   companion/game crashes, automatic paired saves, clean rehost, and
   receipt-bound restore with non-trivial freight, growth, and several active
   vehicles.
5. **Clean-machine distribution.** Keep testing install, first-launch,
   update/restart, private/public repository authentication, support-bundle
   collection, and uninstall on machines without the development repository.

The exact acceptance procedure is [the alpha release checklist](ALPHA_RELEASE_CHECKLIST.md).

## Post-alpha engineering backlog

### Broader command authority

Every consequential player action needs a portable payload, ownership and
finance authorization, deterministic replay, physical postconditions, result
consensus, and a checkpoint. Unadapted commands must remain rejected. Priority
families are advanced schedule/terminal settings, less common construction
editors, additional management widgets, and commands introduced by supported
mods.

### Mod compatibility

Named data-only resources already use the generic codec. Script-heavy mods can
run arbitrary local Lua callbacks and therefore need one of:

- a deterministic canonical adapter;
- an attested, constrained callback environment; or
- an explicit incompatibility declaration.

Accepting a `.con` or `.mdl` filename is not proof that arbitrary callback side
effects agree on both peers.

### Vehicle synchronization depth

Station rendezvous bounds service-phase drift without continuously correcting
native coordinates. Future work may add cheaper multi-vehicle batching,
schedule-aware release slots, better signal interaction, and optional visual
phase correction that cannot alter authoritative service or finances.

### Recovery and migration

Current recovery restarts both roles from a proven paired boundary. It does not
repair already-divergent geometry in place. General recovery would need a
portable authoritative world snapshot or audited reconstruction system. Host
migration additionally requires ordering authority, credentials, relay room,
and recovery ownership to move safely.

### Security and trust

The relay protects transport credentials and limits diagnostics, but players
are trusted. Hostile-peer play requires authenticated identities, replay and
rate defenses, payload/resource abuse controls, stronger server-side policy,
anti-cheat assumptions, moderation, and a formal security review.

### Scale and platforms

More than two players changes quorum, company mapping, pacing, recovery, and
station-barrier throughput. macOS and Linux require separate executable
profiles, native-hook engineering, packaging, and complete live qualification;
they are not enabled by the portable Lua/Python layers alone.

### Product UX and operations

- clearer readiness, rejection, reconnect, and restore explanations;
- server-side support tooling keyed by non-secret support ID;
- opt-in telemetry and privacy controls;
- compatibility discovery before launch;
- accessible onboarding and less developer-oriented in-game panels;
- stable save/version migration policy and deprecation windows.

## Completed core from the brief

| Capability | Current position |
|---|---|
| Separate companies and finances | Canonical accounts, native wallet projection, ownership, rival veto, purchase/upkeep/revenue, and scoring implemented. |
| Shared construction | Portable preflight/replay and physical consensus cover the supported stock/data-only matrix, including collateral and topology. |
| Lines and vehicles | Ordinary line lifecycle and portable stock vehicle lifecycle implemented for all carrier families. |
| Passenger competition | Fares, generalized cost, capacity, transfers, feeders, queues, loads, revenue, and model growth implemented. |
| Freight | Destination-gated production, inventories, multi-hop transfers, loads, deliveries, conservation, and revenue implemented. |
| Shared time | Pause/speed rendezvous and settlement-driven authored calendar implemented. |
| Saving and recovery | Clean continuation plus receipt-bound paired restore implemented. |
| Internet transport | Outbound TLS relay, save transfer, credentials, and redacted diagnostics implemented for trusted peers. |
| Distribution | Transactional installer, launcher, updater, verification, rollback, and cleanup implemented. |

## Work that can continue without another tester

- fuzz and property testing for codecs, schemas, finance, and recovery;
- stock-resource inventory audits after game updates;
- performance profiling and batching that preserve authority semantics;
- documentation/version/link checks and clean-package verification;
- deterministic model balance simulations;
- new adapters whose exact native payloads are already captured;
- support-log analysis and reduced reproductions from reported session IDs.

Physical human evidence is still required before upgrading claims about WAN
latency, visual feel, complex mouse previews, or long-session stability.
