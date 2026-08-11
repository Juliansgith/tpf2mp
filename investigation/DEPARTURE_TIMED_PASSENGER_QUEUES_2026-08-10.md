# Departure-timed passenger queues

Date: 2026-08-10 (Europe/Amsterdam)

Implementation target: prototype `0.37.0-alpha`, state schema `30`, economy
model `9`, checkpoint format `5`, passenger-presentation schema `4`

## Problem

The first live corridor had two 20-seat trains and roughly 30 route seat-slots
per five-minute accounting interval. Passenger schema 2 displayed that
interval throughput as 15 riders in each direction and smoothed it over planned
departures. The arithmetic was internally consistent, but the physical story
was confusing: a player could see “30 capacity” beside a 20-seat train, trains
were unlikely to fill, and excess demand never became a convincing station
queue.

## Implemented authority

Economy model 9 separates three mutually exclusive outcomes for every market:
natural outside choice, admitted service throughput, and capacity-constrained
waiting demand. A service result carries `requested`, `allocated`, and
`capacityOverflow`; their exact conservation is checked in Lua and Python.
Requested load also becomes the next epoch's lagged crowding input. Historical
economy versions retain their prior immediate-reallocation behavior for replay.

Passenger schema 3 stores an exact millisecond demand cursor and directional
fixed-point residuals. Every already-ordered station release advances both
terminal queues to the shared release timestamp. Arriving riders split
directionally with alternating odd-rider ownership, then a vehicle boards only
`min(waiting, physical free seats)`. Completed synchronized alighting remains
the sole passenger-revenue source.

Queue storage is bounded to one maximum-wait demand window. Existing backlog is
never deleted merely because demand falls; only new arrivals beyond the bound
are counted as abandoned. Route edits retain the existing explicit
discard/backlog accounting.

Passenger schema 4 subsequently adds line-level discard accounting and strict
vehicle/line/arrival conservation. See
[LIVE_SOAK_FAILURE_HARDENING_2026-08-10.md](LIVE_SOAK_FAILURE_HARDENING_2026-08-10.md).

## Player-facing interpretation

The authoritative line view now labels both quantities explicitly:

- `seats/train` is the capacity of one physical consist;
- `route seat-slots/5m` is the whole service's bidirectional interval capacity;
- `requested` is demand that chose the service;
- `throughput` is demand admitted by route capacity;
- `waiting` and `abandoned` describe the departure-timed presentation ledger.

The former “carried” label for projected allocation has been removed. Transport
and revenue counters continue to mean actual synchronized boarding/completion.

## Verification boundary

Automated coverage includes the exact motivating shape: 45 requested riders,
30 interval seat-slots, 20 physical seats per train, a roughly 6.5-minute
release, a full 20-seat departure, and a remaining station queue. Checkpoint
tests bind the new demand fields, time cursor, residual bounds, and latest
economy result; cross-language model-v2-through-v9 parity remains exact.

The remaining proof is a fresh two-process visual run. It should confirm that
both peers show the same 20-seat full train and queue after the first ordered
release, the queue changes only at deterministic release times, crowding affects
the following settlement, and old schema-2 saves migrate without a fault.
