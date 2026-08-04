# Checkpoint barriers and coordinated recovery

Date: 2026-08-02  
Prototype: `0.16`  
State/checkpoint/proposal formats: `13` / `2` / `3`

## Decision

A successful native proposal is not the end of an authoritative transaction. After the two pinned peers agree on canonical outputs and core state, the host applies the quoted cost to canonical accounts, reconciles native wallet caches, and opens a second barrier. Each game exports a checksummed checkpoint and no later intent may commit until both checkpoints have the same convergence key.

Checkpoint format 2 covers:

- replayable authored model state;
- the local-ID-free canonical registry;
- the structural world digest when available;
- canonical balances and loans keyed by canonical company ID, with native-wallet observations retained only as local diagnostics;
- the exact global boundary sequence and retained event cursor.

The peer ID, tick, local event numbering, native player numbers, and local entity bindings may differ. They are excluded from the convergence key. A peer cannot submit a legacy format-1 checkpoint to a live consensus barrier, although the offline verifier still reads format 1 so older evidence remains usable.

## Ordered flow

1. A host `match.initialise` commit or successful `network.proposal_outcome` establishes a checkpoint boundary.
2. Both game scripts persist a local pending barrier and export `reason`, `boundarySeq`, model/canonical/core/structural/financial digests, and the full checksummed checkpoint.
3. The companion validates internal hashes, session/peer identity, format, reason, and roster membership.
4. The host blocks every later intent while the barrier is pending.
5. Matching convergence keys produce an ordered `network.checkpoint_outcome` success consumed by both games.
6. A mismatch, malformed record, missing peer, or 45-second timeout produces an ordered fault and permanently closes that session.

The host reconstructs pending/completed barriers from its append-only audit after restart. Ordered outcome controls are retained in reconnect replay just like commits and physical proposal outcomes.

## Recovery plan

`tpf2mp recovery-plan` and packaged `tools/new_recovery_plan.ps1` verify the audit and select the newest successful all-peer checkpoint outcome. The generated checksummed JSON includes:

- audit SHA-256;
- source and derived restart session IDs;
- boundary/outcome sequences and reason;
- core, model, canonical, structural, and financial digests;
- each required peer's checkpoint digest;
- the first later authoritative fault, when present;
- explicit coordinated-reload requirements.

The plan does not import Lua state into a divergent live world. Native geometry may already differ after a failed proposal, and the checkpoint intentionally contains no machine-local binding IDs. Safe recovery therefore requires both players to stop, load an identical native save captured at the agreed boundary, regenerate matching save/content manifests, and start the derived session. Automatic native-save capture and binding reconstruction remain future work.

The protocol checksum detects accidental record corruption and the plan carries the authority audit's SHA-256. Neither is an authenticated digital signature. The current transport has no peer identity authentication or encryption, so it is suitable only for localhost or a trusted LAN/VPN until that layer is added.

## Automated evidence

The suite exercises:

- match/proposal dependency blocking until checkpoint agreement;
- two matching format-2 peer records over two real file bridges and localhost TCP;
- ordered checkpoint success delivery to both inboxes;
- financial-only divergence faulting the session;
- missing-peer timeout and permanent fail-closed continuation;
- audit replay validation;
- checksummed recovery-plan generation and verification;
- backward-compatible reading of historical format-1 checkpoints;
- player-2 Lua engine simulation across match, two physical proposals, three checkpoint barriers, and split issuer/native-owner mapping.

`runtime/live-validation/20260802-075533` additionally passed 39/39 in exact Transport Fever 2 Build 35924 with state schema 11 and checkpoint format 2. Its independent report verified 14 post-anchor events, model digest `95dd1197`, core digest `f859604c`, and financial digest `fde11e45`.

Superseding two-peer proof: `runtime/localhost-live/localhost-20260802-175636` passed the initial barrier and one post-physical barrier for each peer-origin track in two real game processes under state schema 13. The latter barriers covered matching physical results and canonical accounts after each schema-3 25,000 charge. It finished with three completed barriers, zero barrier faults, core `fdaceb08`, and structure `33cdc17a`, then held structure and canonical finance for 600 ticks. Automatic native-save capture/reload remains open; the barrier itself is bidirectionally live-proven.
