# TPF2MP 0.43.2-alpha

This patch release fixes two authority-boundary faults found in external relay
sessions. Gameplay and protocol schema versions are unchanged from
`0.43.1-alpha`.

## Rejected native operation isolation

- Native operation targets are now identified read-only before any canonical
  binding is created.
- An ambiguous pre-existing object or rival-owned target is rejected without
  changing the canonical registry, revision counter, or checkpoint digest.
- Standalone and hot-seat duplicate-decoration behavior remains compatible
  with the earlier local-only path.

## Connected-depot repair safety

- The derived helper-to-road repair graph now renumbers retained node slots
  after removing the construction-internal helper node.
- Every edge reference is remapped to the derived slot plan, and physical
  output identities are translated back to their original canonical slots.
- The complete derived graph is validated before native execution, preventing
  a late codec rejection after the depot shell has already changed the world.
- Proposal node, edge, and edge-object arrays must now be dense contiguous
  lists, closing the related sparse-table validation gap.

## Regression coverage

- A network integration test proves rejected ambiguous operation capture is
  digest-neutral and emits no bridge traffic.
- A connected-depot regression reproduces the one-node `node:2` repair graph
  from live evidence and proves it becomes a valid `node:1` physical graph.
- The complete automated gate passes: 154 Lua tests, 7 transport-network tests,
  3 alpha-readiness tests, 227 Python tests, cross-language parity, integration,
  packaging, installer, updater, and lifecycle checks.

## Supported boundary

This remains a trusted two-player Windows x64 alpha for exact Transport Fever 2
Build 35924. Both players must install `0.43.2-alpha`; mixed versions are
unsupported. Start a fresh multiplayer session after updating; an already
faulted save remains fenced and should be restored from a healthy boundary.
