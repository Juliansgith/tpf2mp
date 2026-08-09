# Atomic multi-vehicle sale

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.37.0-alpha`  
State schema: `29`  
Operation schema: `4`  
Native hook: `0.15.0`  
Exact game build: Windows x64 Build 35924

## Result

The stock SellVehicle multi-selection no longer has to be rejected merely
because tag 12 contains a native vector. The complete selection is retained at
the native boundary and represented above it as one canonical operation.

Hook 0.15 emits `V3|12|count|id,id,...` for a sale. The decoder accepts 1-256
non-negative, unique native entity IDs and rejects malformed, duplicate,
truncated, or count-mismatched payloads before mutation. Other vehicle command
tags keep their compact `V2` representation, and historical `V1` compatibility
remains limited to the two already documented legacy tags.

Lua maps a one-target vector to `vehicle.sell` for compatibility. A larger
selection becomes `vehicle.sell_batch` under operation schema 4. Canonical
vehicle IDs are sorted, unique, bounded to 2-256, and contain no peer-local
native IDs. Python applies the same field, ordering, cardinality, and schema
checks, so the companion cannot admit a payload that the game rejects or vice
versa. Operation schemas 1-3 remain readable for existing evidence.

## Transaction boundary

Before any replay, every target is resolved, checked against the issuing
company, and checked for operation access. Materialization produces a
deterministic list of scalar local IDs because Build 35924 exposes only the
public scalar `sellVehicle` command factory. Replay then issues those scalar
commands serially, with one native tag-12 authorization per item, while keeping
one aggregate pending operation.

If the Lua submission itself throws after authorization but before the native
visitor consumes its token, hook 0.15 exposes a bounded tag-specific revoke.
Both scalar and batch replay withdraw that unused token before reporting the
failure, so a later vanilla click cannot inherit stale mutation authority.

Success requires all selected native vehicles to be absent. Only after that
postcondition passes does the runtime unbind every canonical vehicle, retire
their logical ownership, remove their authored upkeep and passenger/cargo/
vehicle-sync presentation state, refresh every affected line, report aggregate
finance, enter physical consensus, and open the normal checkpoint boundary.
The canonical model therefore never observes a partially successful sale.

## Honest failure boundary

The public game API supplies no transactional multi-sale command and no safe
way to reconstruct a deleted native vehicle exactly. If a later scalar replay
fails after an earlier vehicle was deleted, the canonical operation does not
commit, but physical residue may exist. That condition faults and pauses the
session; it is not described as rollback or recovery. Preflight removes the
ordinary authorization/not-found failures before mutation, but it cannot make
an engine failure physically reversible.

## Automated evidence

- Native codec tests prove complete V3 output and duplicate rejection.
- GUI tests prove malformed envelopes fail closed and a two-target stock sale
  produces exactly one canonical capture.
- Lua codec tests prove canonical sorting, materialization, cardinality,
  duplicate, and old-schema rejection.
- Runtime tests prove two ordered scalar native calls, two gate
  authorizations, one aggregate result/finance report, and removal of upkeep
  for every target.
- Python protocol tests prove strict schema-4 parity.
- New release-manifest format-2 packages record the operation schema alongside
  the exact source commit and native hook version. Pre-field format-2 archives
  remain readable; verification labels their operation schema unrecorded. The
  transactional install pointer carries the field when the package has it.

The remaining evidence gate is an ordinary-widget two-process sale of at least
two selected vehicles, with both peers proving entity absence, affected-line
refresh, isolated finance, physical consensus, and the following checkpoint.
