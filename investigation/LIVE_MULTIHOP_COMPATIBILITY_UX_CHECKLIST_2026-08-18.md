# Live multi-hop, compatibility, and UX checklist

Date: 2026-08-18 (Europe/Amsterdam)

Target: prototype `0.38.0-alpha`, state schema `31`, fresh disposable
two-process localhost match, exact Build 35924. Do not continue after a session
fault, unresolved proposal/checkpoint, or physical mismatch. Export Research
at each marked boundary.

## 1. Clean baseline

1. Start a fresh two-process match with only TPF2MP and any explicitly chosen
   data-only content mod enabled identically on both peers.
2. Wait for both Multiplayer panels to report running/ready and a completed
   initial checkpoint.
3. Set speed 3, pause and resume once from Player 2, and confirm both games
   recover to the same effective speed.

Pass: no fault, no pending construction, and both peers show the same match
epoch, service count, and route counts.

## 2. Passenger connection

1. Build and operate passenger line `A <-> B` on Player 1. Record its direct
   demand in Overview.
2. Build and operate `B <-> C`. Reuse the exact station group at B; a nearby
   separate station is intentionally not a transfer.
3. Open **Routes / Transfers**. Find an `A -> B -> C` passenger route and note
   its transfer count and demand.
4. Wait for one automatic five-minute settlement. Confirm A-B's total demand
   is above its recorded direct demand, both lines continue moving, and the
   checkpoint completes on both peers.
5. Export Research.

Optional multimodal pass: replace B-C with a bus or tram line using the same
station group. The route should remain carrier-neutral.

## 3. Cargo must have a destination

1. Place a cargo station in catchment of a producing industry and a transfer
   station away from a compatible consumer.
2. Create `Source -> Hub`, assign a cargo-capable vehicle, and let it reach its
   source stop.
3. In **Routes / Transfers**, require the line to say `WAITING` / no compatible
   path. Authored capacity and demand should be zero; it must not acquire model
   cargo merely because the producer exists.
4. Export Research before adding a destination.

Pass: zero authoritative transfer stock and no final-delivery revenue.

## 4. Real two-leg cargo transfer

1. Add a second cargo line from the exact same Hub station group to a station
   in catchment of an industry that consumes the same cargo type.
2. Assign a compatible vehicle to the second line. Wait for automatic line
   registration.
3. **Routes / Transfers** should now show one cargo path, two legs, Source ->
   Hub -> Destination, positive demand/capacity, and no unresolved source leg.
4. Run both vehicles. Observe, in order:
   - upstream vehicle boards at Source;
   - Hub transfer stock becomes positive after its unload;
   - downstream vehicle boards no more than Hub actually holds;
   - Hub stock falls by exactly that amount;
   - final delivery appears at the consuming industry after settlement.
5. Confirm only final delivered units enter `totalDelivered`; physical movement
   on both legs contributes to `totalTransported`.
6. Export Research and a checkpoint.

Intermediate-stop variant: make Hub the middle stop of a three-stop first
line. The manager's first segment should end at that middle stop, not at the
line's terminal.

## 5. Operational path pin

1. Before either cargo vehicle runs, add a faster alternative Hub ->
   Destination line. The unused path may replan to the cheaper compatible
   alternative.
2. Let a vehicle reach an ordered stop on the selected path. That pins every
   leg of the complete route.
3. Add another shortcut. The operated route must not silently change its path
   digest, stock identity, or payment cursor.

Pass: no duplicated cargo and no contract-change fault. If an operated leg is
deleted, the remaining leg should become `pinned-path-unavailable`; for this
prototype, delete/recreate all operated legs to abandon that path.

## 6. Generic infrastructure and mod resources

One category at a time, build and then inspect **Compatibility**:

- road, including a town-road junction;
- normal/electrified/high-speed track, bridge, tunnel, and crossing;
- signal and waypoint;
- passenger and cargo station, depot, and one modular station edit;
- bench/lamp/fence or another graphless asset;
- one data-only mod road, track, vehicle-supporting station, or construction if
  available on both peers.

For every item require:

- it appears on both peers in the intended position;
- only the issuing company's competitive wallet changes;
- rival private edits are denied while public-road connection policy remains;
- the Compatibility view lists the exact named resource and increments its use
  count;
- no proposal or checkpoint remains pending.

An executable scripted construction whose result depends on an opaque callback
is not expected to work generically. It should fail visibly and leave both
world and wallet unchanged.

## 7. UX, save, and reload

1. Switch among Overview, Routes / Transfers, and Compatibility while both
   games run. Confirm the panel remains responsive and route/stock counts
   update without manual Refresh.
2. Use the one-button restore-point preparation only after every prior action
   has checkpointed.
3. Save both peers at the READY boundary, then reload through the normal paired
   restore flow.
4. Confirm passenger routes, cargo path digest, transfer stock, active vehicle
   loads, retired freight totals, compatibility inventory, finances, and
   station-release rounds survive.
5. Let both cargo vehicles complete another cycle and one settlement.
6. Export final Research, Snapshot, and Checkpoint.

Final pass requires identical core/model/structure/convergence digests, no
session fault, no negative transfer stock, no line whose delivery exceeds its
boarding, and no unexplained native-only competitive income.
