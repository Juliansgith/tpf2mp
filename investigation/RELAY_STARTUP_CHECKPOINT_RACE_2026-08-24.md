# Relay startup checkpoint race (2026-08-24)

## Live finding

Secure-relay session `mp-2eec5e643449b775` faulted before its first player
construction. The host committed `match.initialise` at sequence 2 / engine tick
240 while the player-2 companion socket was connected but the player-2 game
world had not finished loading. Player 1 exported its `match-initialised`
checkpoint immediately. The 45-second boundary expired with:

`checkpoint-consensus-timeout:player2`

Player 2 then loaded, replayed both ordered commits, and exported its sequence-2
checkpoint just after the irreversible fault outcome. All authoritative
convergence fields matched across the late pair:

| Field | Player 1 | Player 2 |
|---|---:|---:|
| core | `2cb55c0e` | `2cb55c0e` |
| model | `62ce9046` | `62ce9046` |
| structural | `8e6de95b` | `8e6de95b` |
| financial | `416d3bf5` | `416d3bf5` |
| canonical | `0b6d656f` | `0b6d656f` |
| world manifest | `9599d085` | `9599d085` |
| convergence key | `7f276773` | `7f276773` |

This was a readiness race, not simulation divergence or a failed construction.

## Root cause

The launcher marker proved that the local pinned world and native authority were
ready. The host's consensus gate separately proved that the remote companion
socket was connected. Neither fact proved that the remote game-script VM had
loaded and could answer a checkpoint. `maintainManualBootstrap` therefore
submitted initialization too early in an internet flow where Host + Launch
precedes Join + Launch.

The project already had a stronger proof: each world independently submits an
ordered `content.industry_attest` only after its game VM has loaded and read its
industry registry. Matching attestations from every required peer prove both
world liveness and identical content.

## Fix and invariant

- Automatic game-side initialization waits for digested industry content to be
  ready, which requires matching attestations from both live worlds.
- The host independently refuses production `match.initialise` intents until
  its per-peer content-attestation consensus is ready. A connected socket alone
  is deliberately insufficient.
- The main panel reports `waiting for peer world`, then `synchronising
  checkpoint`, and only reports `ready` after an agreed initial checkpoint.
  Durable session faults take precedence over every ready label.
- Restore bootstrap remains independent; it continues through its existing
  receipt-bound validation path and does not require a fresh-match attestation
  gate before submitting `recovery.resume`.

Regression coverage lives in `run_runtime_module_tests.lua` and
`IndustryContentConsensusTests`.
