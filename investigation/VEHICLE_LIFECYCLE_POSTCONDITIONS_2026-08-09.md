# Vehicle lifecycle physical postconditions - Build 35924

Date: 2026-08-09 (Europe/Amsterdam)
Prototype: `0.29.0-alpha`
Native hook: `0.14.0`
Executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

## Finding

Operation consensus already required both peers to report the same physical
result digest. Several vehicle operations nevertheless lacked a local
transaction-specific postcondition. Two peers could therefore have agreed on
the same wrong stop flag, maintenance target, replacement consist, depot-sale
flag, or line assignment.

`operation_vehicle_postcondition.lua` now projects only bounded portable native
fields and verifies them against the ordered transaction before a successful
completion can be emitted:

- Buy/Replace: exact model name, reversed bit, and per-compartment load
  selection for every part;
- Stop/Start: exact `userStopped` value;
- Maintenance: every part's target, rounded to the canonical basis points;
- Set Line: the resolved canonical line must equal the ordered line;
- Send to Depot: `sellOnArrival` must equal the ordered boolean;
- Reverse: the complete portable consist projection must be readable and is
  included in cross-peer physical consensus;
- Set Name: the native name must equal the ordered name;
- Sell: the pre-existing entity-absence check remains mandatory.

The standard runtime owns no model-specific list. Names are recovered through
the active model repository, so byte-identical mod vehicles use the same path.
Unavailable names, missing load selections, partial maintenance application,
or a callback that reports success without the requested state now fail closed.

## Exact-engine receipt

`runtime/supported-api-probe/20260809-024229` passed on the pinned executable
with all 17 native signatures and the production postcondition module loaded.
The disposable chain:

1. built a stock rail depot;
2. bought one NOHAB plus two BC4 coaches and matched all three native parts;
3. stopped and restarted the real vehicle with exact `userStopped` readback;
4. applied two reverse commands and retained a readable portable consist;
5. set maintenance to 7,500 basis points and read `0.75` on all three native
   `TransportVehiclePart` wrappers;
6. replaced the consist with one NOHAB plus one BC4 and matched both parts;
7. sold the vehicle and verified that querying its former entity raises Build
   35924's `Invalid entity` absence result;
8. issued depot cleanup and terminated the unsaved process.

An earlier run, `20260809-023242`, reached the same successful native sale but
correctly failed the first version of the probe because it assumed a deleted
component query returned `nil`. The runner was fixed to treat the pinned
engine's invalid-entity exception as absence; no game behavior was changed to
manufacture the pass.

## Automated boundary

Adversarial unit cases reject a wrong replacement model, an unchanged stop
flag, one mismatched maintenance part, a wrong line, and a wrong
sell-on-arrival flag. The full gate passes 95 Lua core tests, 75 cross-language
economy cases, runtime/game/network/hot-seat/GUI suites, 108 Python tests, and
the 1,024-event replay.

This is exact one-process command/repository/component proof. It is not yet an
ordinary-widget two-process lifecycle matrix. Reverse was exercised while the
vehicle was in its depot, so a running train still needs the human visual
round-trip. Immediate departure, manual-departure UI, return-to-depot movement,
sell-on-arrival, rival denial, and disconnect behavior retain their explicit
two-process acceptance gate.
