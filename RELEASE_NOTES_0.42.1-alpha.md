# TPF2MP 0.42.1-alpha

This construction-replay release replaces the road-depot-specific correction
with one graph-derived rule for portable buildings that connect to streets.
Gameplay authority remains state schema 34, checkpoint format 5, construction
proposal format 7, operation format 4, economy model 10, and native hook
0.19.0.

## Universal connected-street replay

- A construction with a captured existing street endpoint now uses the typed
  exact-graph path regardless of its stock or mod resource filename.
- The rule covers road depots, electrified and unelectrified tram depots,
  passenger bus/tram terminals, cargo/truck terminals, arbitrary compatible
  data-only constructions, construction-owned edge objects, road splits,
  retained topology, and collateral demolition.
- Build 35924's disposable generated snap node is replaced only when exactly
  one bounded node is surplus, at least one generated edge endpoint is safely
  rebound, no edge still references the discarded node, and vector trimming
  round-trips. Ambiguous shapes fail closed.
- Curbside bus, tram, and truck stops retain their dedicated edge-object
  protocol. Connected rail depots remain deliberately blocked: their typed
  replay output crashes the stock context helper, so players should place an
  isolated rail depot and connect track as a separate synchronized action.

## Validation

- The Lua suite covers road and tram depots, catenary parameters, generic
  mod-style constructions, construction-owned edge objects, all 216 modular
  street-terminal variants, all 60 airport variants, and all 12 harbor layouts.
- Exact Build 35924 disposable runs pass for a connected road depot followed
  by a stock bus purchase, an electrified connected tram depot, and a connected
  modular passenger terminal with road splitting and two collateral houses.
- Each native run converged core state, structural state, checkpoints, and
  company finances with zero rejects, faults, or pending work.
- The complete Lua, Python, cross-language parity, launcher/updater, relay,
  recovery, syntax, architecture, and packaging gates pass.

Both players must install `0.42.1-alpha`. Mixed versions remain unsupported.
