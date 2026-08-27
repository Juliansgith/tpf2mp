# Atomic street-terminal collateral replay - 2026-08-27

> Superseded the same day by
> [Street-terminal typed table-converter crash](STREET_TERMINAL_TYPED_TABLE_CONVERTER_CRASH_2026-08-27.md).
> The live 0.41.6 typed path crashed before `BuildProposalVisitor`. The targeted
> collateral-only helper barrier documented here remains; single-proposal typed
> replay for collateral constructions does not.

## Live failure

In relay session `mp-748086c41a5e1f9f`, Player 1 placed a stock modular bus
terminal across two town buildings and a connected town-road edge. Both peers
accepted proposal `mp-748086c41a5e1f9f:player1:8` with transaction digest
`6b20d478`. Its portable transaction contained:

- `station/street/modular_terminal.con`;
- two explicit collateral construction removals;
- removal of canonical town-road edge `edge:pre:72fc11f4`;
- two new nodes and three replacement/access street edges.

Both native worlds removed the houses, but neither built the terminal. After
the bounded 600-tick construction window they reported `construction
collateral did not retire before the build deadline`. Because the failed replay
had already removed the houses, consensus correctly classified it as
`native-rejection-mutated-prepared-core` and faulted the session.

## Cause

Fresh constructions with collateral were routed through the staged helper
path. That path bulldozed the construction roots first and then treated every
canonical removal input as part of its pre-build barrier. The input set also
contained the town-road edge.

That edge was not collateral which the helper could clear independently. It
was replacement topology owned by the eventual station proposal, so it could
only disappear while the terminal and its access graph were being built. The
runtime therefore waited for a condition that the blocked build itself had to
create.

## Fix

Fresh non-depot construction builds now retain their explicit collateral and
replacement topology in one native GUI `BuildProposal`. This restores the
stock transaction boundary: buildings, replaced road, station, and access
edges either apply together or reject together.

The native soft-error mode is enabled only when the canonical construction
declares collateral, matching vanilla collision/demolition placement. The
existing removal verifier still checks the exact native removal vector before
the command is accepted.

Two defensive boundaries remain:

- if an atomic construction cannot be materialized, it fails before any
  helper bulldoze instead of degrading to a partial replay;
- helper-only construction classes wait only for their explicit collateral
  roots, never for road/track inputs that belong to the later build.

The routing predicates were extracted into `construction_replay_policy.lua`
and given their own source-size guard, keeping the proposal runtime within its
architecture budget.

## Verification

The regression fixture reconstructs the live proposal shape, including the
modular terminal, resource-hydrated module metadata, two houses, removed town
road, and three-edge access graph. It proves that:

- the transaction uses atomic GUI replay;
- the two houses and road edge remain in the same materialized proposal;
- helper fallback is forbidden for this shape;
- helper collateral filtering excludes the replacement road edge;
- construction-collateral soft errors retain exact removal verification.

The complete Lua, Python, PowerShell, launcher, relay, recovery, packaging,
cross-language, and integration suite passes. The main Lua model/codec suite
passes `143/143`; the companion suite passes `209/209`.

## Required live check

The already faulted session cannot safely continue because its houses were
removed without the terminal. In a fresh process containing this fix, place a
large bus/tram terminal connected to a town road while its footprint removes
one or more buildings. It must appear exactly once on both peers, remove the
same buildings and road topology on both, settle finance once, and leave the
session healthy. Repeat once with a truck terminal to exercise the same generic
street-terminal path.
