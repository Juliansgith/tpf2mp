# Recovery and freight audit review

Date: 2026-08-10 (Europe/Amsterdam)

Scope: adversarial review of the four recovery/freight findings reported after
prototype `0.37.0-alpha`. This review distinguishes a user-facing CLI gate from
the lower-level Python API, follows ordered line deletion into every canonical
ledger, and adds malformed-input tests at the signed-plan/session boundary.

## Verdict

| Finding | Verdict | Result |
| --- | --- | --- |
| `--allow-legacy-unbound` is never enforced | Partly correct | The CLI already enforced an explicit choice through a required mutually-exclusive argument group. The lower-level `build_restore_plan()` API did silently emit a policy-unbound v2 plan when no profile was supplied. The API now requires an explicit `allow_legacy_unbound=True`, and the CLI passes its flag through. Supplying both a profile and the legacy opt-in is rejected. |
| Freight transport cursors survive line deletion | Confirmed | A deleted cargo line left its cumulative contract cursor in canonical, digested, saved state forever. Ordered `line.delete` consensus now retires that one cursor alongside passenger/cargo presentation retirement. Historical aggregate transported/delivered totals are deliberately retained. |
| `all([])` could promote an empty point | Latent, currently unreachable | Normal restore analysis cannot mark an empty receipt roster ready: the required roster is non-empty and every missing receipt contributes a reason. The plan builder nevertheless now independently requires an exact, non-empty receipt roster and uses an explicitly non-empty metadata predicate. A future change cannot turn the vacuous truth into a v4 plan. |
| malformed integer fields escape as `ValueError`/`TypeError` | Confirmed | Restore-plan protocol and restore-session checkpoint-boundary fields used coercive `int()` reads. They now require exact non-boolean integers and raise `ProtocolError`. The adjacent signed-envelope protocol check was hardened to the same rule. |

The first report therefore identified a real defense-in-depth gap, but its
statement that the command-line flag was decorative was too broad. Omitting
both `--match-profile` and `--allow-legacy-unbound` already failed in argparse;
only callers of the Python API could bypass that explicit choice.

## Recovery changes

`restore.build_restore_plan` now treats policy binding as an explicit sum type:

- a supplied match-content profile produces a profile-bound plan;
- `allow_legacy_unbound=True` permits the intentionally weaker v2 plan;
- neither choice, both choices, or a non-boolean opt-in fail closed.

Before version selection, the builder also rechecks that the ready point has
exactly the required non-empty peer receipt set. This is intentionally
redundant with `analyse_restore_points`: plan construction is the authority
boundary and does not trust a future analyzer or a mocked caller to preserve
that invariant.

No restore-handshake semantics were loosened. Host-only resume admission,
exact action/plan equality, gameplay fencing until the fresh checkpoint, and
the faulted-resume fence are unchanged. Mixed legacy/current receipt metadata
continues to reject rather than downgrade.

## Freight lifecycle change

The cursor is not presentation state. It binds a line to its source, sink,
cargo type, destination stock index, and cumulative boarded/delivered amounts;
it is therefore correct for an extant line and stale once that canonical line
is deleted.

`freight_transport_settlement.retireLine` removes only
`transportCursors[lineCid]`. `vehicle_sync_passengers.applyOperation` stages
the freight ledger together with the existing passenger and cargo presentation
copies for `line.delete`, adopting them only after all three domain operations
succeed. This preserves the existing fail-atomic operation seam. Global
`totalTransported` and `totalDelivered` remain lifetime statistics and are not
reduced when a player scraps a route.

The fix does not weaken the conservation properties already present in freight
settlement: cumulative delivery still cannot exceed boarding, cursors remain
monotonic while a line exists, contracts remain pinned after movement, and
parallel withdrawals are still checked in aggregate.

## Proof added

The Lua regression test creates a moved freight contract, deletes its line
through the real post-consensus operation integration, and proves:

- the per-line authoritative cursor is gone;
- cargo presentation is retired at the same boundary;
- lifetime transported and delivered totals remain unchanged.

The Python regressions prove:

- the core API refuses an implicit policy-unbound plan;
- the explicit CLI legacy flag still creates a valid v2 plan;
- profile plus legacy opt-in is rejected;
- an impossible empty ready receipt set is rejected independently of analyzer
  readiness;
- malformed plan, envelope, and restore checkpoint protocol fields produce a
  clean `ProtocolError` rather than a built-in conversion exception.

## Verification

`tools/run_tests.ps1` passed after the changes. Its relevant coverage included:

- Lua unit suite: `125/125`;
- Python discovery suite: `146/146`;
- 256-step deterministic multi-cargo freight stress replay;
- Lua/Python freight and economy parity;
- 1,024-event deterministic replay;
- restore-plan publication/discovery/handoff and recovery archive tests;
- architecture/source budgets, Lua/PowerShell syntax, native boundaries,
  release manifest, transactional installer, and package checks.

No game processes were started for this static audit.
