# TPF2MP 0.42.2-alpha

This depot-safety release replaces typed fresh-depot roots with the engine's
stock-selectable helper construction while retaining deterministic canonical
street connection and ownership. Gameplay authority remains state schema 34,
checkpoint format 5, construction proposal format 7, operation format 4,
economy model 10, and native hook 0.19.0.

## Selectable connected depots

- Fresh connected road and tram depots are created through the stock
  `buildConstruction` helper, so opening the ordinary depot context window no
  longer feeds a typed `ConstructionEntity` root into Build 35924's unsafe
  selection path.
- After the helper graph stabilizes, a topology-only proposal appends the
  captured road connector. The construction-owned entrance remains intact.
- The root, depot, connector, and helper entrance are assigned to the intended
  company on both peers. A remote peer's local native player can no longer
  silently become the depot owner.
- The retained helper entrance is bound as an explicit private derived output,
  preventing a later structural scan from inventing an unjournaled canonical
  edge and invalidating recovery evidence.
- The rule is graph-derived and applies to compatible stock or data-only mod
  road/tram depots without a resource-name allowlist. Ambiguous helper graphs
  and connected rail depots still reject before unsafe mutation.

## Validation

- A two-process Transport Fever 2 Build 35924 run created and connected a road
  depot, corrected connector ownership on both worlds, bought a stock bus, and
  completed physical consensus and checkpoint convergence.
- Final core digest `8d0812ef` and structural digest `6cef503c` matched across
  both peers with no native build drops.
- The complete repository gate passes: 147 Lua model/codec tests, 7 transport
  network tests, 3 alpha-readiness tests, 225 Python companion/relay/recovery
  tests, cross-language parity and stress replay, native-hook verification,
  syntax and architecture budgets, and transactional package installation.

Both players must install `0.42.2-alpha`. Mixed versions remain unsupported.
