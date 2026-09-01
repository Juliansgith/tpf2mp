# TPF2MP 0.39.2-alpha

This relay-startup hotfix keeps the `0.39` network protocol and state schema 31
unchanged.

## Reliable internet-session startup

- Automatic match initialization now waits for matching industry-content
  attestations from both live Transport Fever worlds. A connected companion
  socket no longer falsely implies that the remote game has finished loading
  and can answer the initial deterministic checkpoint.
- The authoritative host independently enforces the same invariant, so a stale
  or older game-side startup attempt cannot open a doomed checkpoint boundary.
- Restore sessions retain their separate receipt-bound bootstrap path and are
  unaffected by the fresh-match gate.

## Clearer readiness reporting

- The main panel reports `waiting for peer world` while the second game loads,
  `synchronising checkpoint` while the first boundary converges, and `ready`
  only after that convergence is proven.
- A durable session fault now overrides every optimistic ready label.

The fix was reproduced from secure-relay session evidence in which player 2's
late checkpoint matched every authoritative player-1 digest but arrived just
after the old 45-second timeout.
