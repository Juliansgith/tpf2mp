# Playable-alpha code closure

Date: 2026-08-18 (Europe/Amsterdam)

Target: the restricted two-player trusted-LAN alpha, prototype
`0.38.0-alpha`, state schema `31`, checkpoint format `5`, exact Transport
Fever 2 Build 35924.

## Closed in this pass

The network companion now treats a socket and a synchronized peer as different
states. On disconnect the host immediately orders an authoritative pause,
invalidates old clock health, protects existing physical/checkpoint deadlines
for one bounded 120-second grace interval, and removes the peer from the ready
roster. A reconnecting client cannot submit intents. Under the host's ordering
lock it receives every missing commit and any published restore plan; only a
signed `sync_ready` after that catch-up makes the peer ready again. Successful
catch-up resets pending deadlines. Expiry faults the session closed with a
visible `peer-reconnect-timeout` rather than allowing solo continuation.

The in-game **Alpha Status** projection now states `READY`, `WAITING`, or
`FAULTED`, lists every concrete blocker, and displays the supported profile and
its explicit limits. It checks network mode, initialization, synchronized
companion state, native authority, durable audit health, session faults,
pending proposals/operations/checkpoints, deferred ordered work, reconnect
state, and the existence of an agreed checkpoint.

One strict `alpha-live-report` now replaces subjective log inspection. It
revalidates the shared audit and checkpoint payloads, then has three profiles:

- `core`: fault-free, quiescent all-peer checkpoint convergence;
- `playable`: core plus connected/synchronized peers, successful construction
  and operation replay, a settled economy, and synchronized vehicles;
- `alpha`: playable plus multiple vehicles, ordered town development,
  multi-line passenger routing, a complete conserved cargo transfer with
  onward boarding, recovered reconnect, and a matching current receipt-bound
  restore plan.

The launcher button now runs the playable report after collecting both local
bridges. Separate host/client evidence directories support the real
two-computer gate. The release package includes the analyzer, one-command local
runner, alpha quick start, and exact release checklist. Companion and product
versions are aligned at `0.38.0-alpha`.

## Automated evidence

- client/host refactors compile and remain below their architecture budgets;
- a real TCP test disconnects Player 2, emits a commit while offline, reconnects,
  proves that commit exists locally before `connected`, and reports recovery;
- immediate pause/deadline reset and fail-closed reconnect timeout tests pass;
- full alpha-report fixtures pass every strong gate and reject missing
  acknowledgements, absent synchronization, and incomplete evidence;
- Lua Alpha Status fixtures prove ready, pending, and faulted projections;
- launcher construction and PowerShell syntax checks pass.

The complete repository suite passed after this note: 132 core Lua tests, 7
transport scenarios, 3 readiness scenarios, 108 economy parity cases, 3
freight parity steps, 256 freight stress steps, 179 Python tests, 141 mod Lua
syntax checks, 9 tool/investigation Lua checks, 54 PowerShell syntax checks,
release-manifest/install transactions, recovery tools, launcher smoke, and all
architecture boundaries.

## Honest remaining boundary

No local test can honestly manufacture the first physical two-computer receipt.
The code-side alpha profile is closed; release still requires the exact run in
`ALPHA_RELEASE_CHECKLIST.md`: passenger and cargo transfers, town development,
multiple vehicles, disconnect/reconnect, paired restore, and a passing
`-Profile alpha` report assembled from both machines. Clean-machine install and
performance/usability observation also remain human gates. Public Internet,
untrusted peers, arbitrary executable callbacks, host migration, more than two
players, and general divergent-world repair are explicitly post-alpha work.
