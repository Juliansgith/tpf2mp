# Vehicle purchase replication and route-phase policy — 2026-08-05

## Outcome

The stock railway purchase and line-assignment path is implemented through the
same canonical operation, physical-consensus, and checkpoint stack as line
commands. The exact NOHAB + two BC4 purchase now passes in a disposable Build
35924 process with hook 0.13.0, as well as the native, Lua, Python, and GUI-state
tests. A stock human purchase now also passes across two independent localhost
processes. SetLine and running route phase remain the next live gates.

## Exact Build 35924 purchase-shape proof

The first human network attempt exposed two native assertions on both peers:

- an empty `VehiclePart.loadConfig` failed `!loadConfig.empty()` and then the
  compartment-count invariant;
- replacing it with the API-documented `-1` automatic sentinel still failed
  Build 35924's purchase path, which requires `loadConfig[0] >= 0` and a value
  below that compartment's configuration count.

`api.res.modelRep` is therefore consulted by resource name on every machine.
The codec requires exactly one concrete zero-based selection per model
compartment, defaults each selection to `0`, validates it against the local
model metadata, and separately assigns `TransportVehiclePart.autoLoadConfig=1`
for automatic cargo choice. This is resource-driven rather than a vanilla
vehicle allow-list, so mod vehicles using the standard metadata shape can use
the same boundary.

The generated vectors have a second Build 35924 constraint: a new
`VehiclePart` must receive `loadConfig` as a complete Lua array. Indexed writes
to its initially empty generated vector produced an unusable command value at
`sendCommand`; assigning the complete array is live-proven.

Receipt `runtime/supported-api-probe/20260805-143735` built a real train depot,
granted disposable funding, issued the canonical `BuyVehicle`, and observed
vehicle entity `2782`. Its postcondition projection was exactly:

- `vehicle/train/nohab_m1_v2.mdl`, load `[0]`, auto `[1]`;
- `vehicle/waggon/bc4_v2.mdl`, load `[0]`, auto `[1]`;
- `vehicle/waggon/bc4_v2.mdl`, load `[0]`, auto `[1]`.

The callback returned `success=true`; hook command/apply conservation and all
17 executable signatures passed. The preceding negative receipts
`20260805-142622`, `20260805-143301`, and `20260805-143449` preserve the two
assertion and fresh-vector failure modes rather than hiding them.

## Two-process stock-UI receipt

Session `vehicle-buy-loadconfigfix20-20260805-1442` closed the first real
BuyVehicle network gate. A human used Player 1's stock depot manager to buy one
NOHAB plus two BC4 wagons. The ordered `vehicle.buy` transaction
`operation:dd74b213` reached both independent Build 35924 processes.

Both peers reported `exists=true`, `vehicleParts=3`, the same canonical output
`vehicle:event:vehicle-buy-loadconfigfix20-20260805-1442:player1:7:1`, and the
same physical result digest `f47da1df`. Checkpoint boundary 8 converged with
canonical `7eb48b62`, structure `402e02a8`, vehicle part `017500f9`, finance
`3b441ec9`, and convergence key `71915fbf`. Company 1 ended at `46,267,745`;
Company 2 remained `50,000,000`. P2's stock Vehicle Manager did not list the
P1-owned depot vehicle, which is the native company filter rather than missing
replication: P2's own operation completion and postcondition prove its local
vehicle exists.

The full session later included deliberately unrelated track/line work and a
successful removal of the old Bromborough South station. Repeated bulldozer
clicks on the empty location produced harmless no-change codec failures; the
session retained zero faults. The collector archived source/install equality,
a valid audit, six completed physical proposals, seven completed checkpoint
barriers, and zero failed/pending physical work at
`runtime/manual-network-evidence/vehicle-buy-loadconfigfix20-20260805-1442-20260805-150006`.

## Live evidence that fixed the consist bug

The populated operational capture in
`runtime/manual-network-evidence/operations-20260802-guided50-20260802-234533`
recorded a normal vehicle-manager accept payload containing:

- `vehicle/train/db_v100_v2.mdl`;
- six `vehicle/waggon/open_1910.mdl` entries.

The canonical validators previously admitted only `vehicle/train/`. Tests also
incorrectly represented the wagon as `vehicle/train/open_1910.mdl`, so a normal
loco+wagon purchase could lose every wagon or be rejected. Lua capture,
canonical Lua validation, Python wire validation, materialisation tests, and GUI
tests now admit exactly the railway namespaces `vehicle/train/` and
`vehicle/waggon/`; road vehicles, trams, ships, and aircraft remain rejected.

## Exact Build 35924 capture boundary

The pinned tag-13 BuyVehicle visitor at RVA `0x009D6280` proves this command-data
layout:

| Offset | Field |
|---:|---|
| `+0x00` | native player entity |
| `+0x04` | railway depot entity |
| `+0x08` | `TransportVehicleConfig` begins |
| `+0x38` | result vehicle entity |

The tag-6 SetLine visitor is at RVA `0x009D5610`; the implementation it reaches
at `0x009D9B10` reads vehicle, line, and stop index at `+0x00`, `+0x04`, and
`+0x08`.

Hook 0.13 serializes only these bounded integers as pointer-free `V1` envelopes.
It deliberately does not walk the undocumented native consist graph. The stock
GUI event supplies the ordered model-name list; the native BuyVehicle envelope
confirms that a command was really attempted and supplies the authoritative
player/depot. Neither half can mutate the world alone. After correlation, the
normal canonical operation is host-ordered and one-shot-authorized on both
peers. Output binding assigns the independently created local trains one
canonical vehicle identity, and physical consensus plus the financial
checkpoint close the operation.

SetLine needs no GUI half: the native scalar envelope already contains its full
canonicalizable payload. Rival vehicle/line ownership is still checked in the
engine state before an ordered operation is emitted.

## Why a train at a different station matters

Exact metre-by-metre position is not required: each game renders and simulates
its own native train. A persistent route-phase difference is not cosmetic,
however. It changes which station loads, when revenue posts, platform/segment
occupation, and what commands appear sensible to each player.

Mobility schema 3 therefore publishes two local-ID-free digests:

1. **Vehicle lifecycle:** canonical vehicle and line, canonical owner metadata,
   ordered consist resource names, part count, stopped state, and sell-on-arrival
   state. This should agree after canonical operations.
2. **Vehicle route phase:** canonical vehicle, canonical line, and native
   `stopIndex`. This can differ briefly because ordered replays arrive a few
   frames apart.

The host reports each domain separately. One or two phase mismatches are
`observing`; three consecutive ordered samples become `warning`. A later
converged sample resets the streak. The code intentionally does not teleport a
moving train: no safe exact-position command has been established. If a train
is genuinely one station away, the recovery design is to pause both games,
return the canonical train to its depot on both peers, wait for a verified safe
boundary, and relaunch it on the line under the shared clock. That coordinated
recovery remains to be implemented and live-proven.

## Focused localhost acceptance test

1. Start a fresh two-process network lab and leave both games paused.
2. On Player 1, open an owned rail depot and buy one locomotive plus at least
   two wagons through the ordinary vehicle manager.
3. Verify exactly one train appears in both games, with the same ordered
   consist, and only Company 1 receives the canonical debit.
4. Create or use a synchronized two-stop line and assign the train with the
   stock Set Line control while still paused.
5. Verify both stock vehicle panels show the train on that line, then unpause at
   the shared speed and let it complete two circuits.
6. Pause and submit `Sample Pax / Cargo` three times. Lifecycle must converge.
   Route phase should converge when sampled paused at the same stop; if it does
   not, retain the evidence rather than manually editing either train.
7. Export research, snapshot, and checkpoint from both peers.

## Explicit remaining boundary

- BuyVehicle has real one-process and ordinary-UI two-process receipts. SetLine
  still needs its two-process receipt.
- Replace remains GUI-captured rather than native-confirmed.
- Start/stop, reverse, maintenance, send-to-depot, sell, replacement, and
  unassignment still need complete typed vanilla adapters and live proof.
- SellVehicle's native command contains a vector rather than the scalar assumed
  by the early operation prototype; it must be reverse-engineered before stock
  sale capture is enabled.
- Route-phase comparison detects divergence; it does not yet repair it.
