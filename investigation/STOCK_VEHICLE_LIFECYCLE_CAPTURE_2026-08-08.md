# Stock vehicle lifecycle capture - Build 35924

Date: 2026-08-08 (Europe/Amsterdam)  
Prototype: `0.29.0-alpha`  
Native hook: `0.14.0`  
Executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

## Result

The normal vehicle controls no longer have to be recreated as multiplayer-only
buttons. The exact native visitors can now suppress and serialize the scalar
half of these stock actions before mutation:

- Set Line;
- reverse;
- start/stop;
- target maintenance state;
- immediate departure;
- send to depot, including sell-on-arrival;
- direct sale of one selected vehicle;
- Buy Vehicle;
- Replace Vehicle;
- manual departure.

Buy and replacement configs remain GUI-owned portable data. The hook copies
only authoritative scalar identities and never follows a native vehicle-config
pointer. Tag 12 is different: it contains a native vector of vehicle ids. The
hook validates the complete bounded vector and admits its one-selection case,
which maps to the game's documented scalar
[`make.sellVehicle(vehicleEntity)`](https://transportfever2.com/wiki/api/modules/api.cmd.html).
A multi-selection click remains blocked before mutation because it needs one
atomic canonical batch, not a sequence that could sell only half the selection.

This is exact-binary and automated integration proof. A 2026-08-09 disposable
exact-engine chain now additionally proves native buy, stop/start, two reverse
commands, per-part maintenance readback, replacement, and direct sale through
the production physical-postcondition projection. The new stock buttons have
not yet been exercised as a complete ordinary-widget matrix in two live
processes.

## Exact payload evidence

The offsets below were recovered from the pinned executable's visitor table and
the corresponding implementations. Every read is bounded and profile-specific.

| Tag | Command | Visitor / implementation RVA | Portable fields |
|---:|---|---|---|
| 6 | SetLine | `0x009D5610` / `0x009D9B10` | vehicle `+0`, line `+4`, stop index `+8` |
| 7 | Reverse | `0x009D5620` | vehicle `+0` |
| 8 | SetUserStopped | `0x009D5710` / `0x009D9E10` | vehicle `+0`, boolean `+4` |
| 9 | SetVehicleTargetMaintenanceState | `0x009D5720` | vehicle `+0`, float `[0,1]` at `+4` |
| 10 | SetVehicleShouldDepart | `0x009D5770` | vehicle `+0` |
| 11 | SendToDepot | `0x009D6260` / `0x009D96B0` | vehicle `+0`, sell-on-arrival boolean `+4` |
| 12 | SellVehicle | `0x009D6270` / `0x009D8C90` | x64 MSVC vector at `+0`; signed 32-bit vehicle ids |
| 13 | BuyVehicle | `0x009D6280` | native player `+0`, depot `+4`; config starts `+8` and is not read |
| 14 | ReplaceVehicle | `0x009D6430` / `0x009D8110` | vehicle `+0`; config starts `+8` and is not read |
| 30 | SetVehicleManualDeparture | `0x009D5F00` | vehicle `+0`, boolean `+4` |

The sale decoder validates the vector's begin/end/capacity ordering, element
alignment, used count (1-256), capacity (at most 1024), readable storage, and
every non-negative entity id. It exports the first id plus selection count; Lua
accepts exactly count one and visibly rejects a larger batch. The tag-14
implementation also consumes a complex config, but its target at `+0` is
independently usable because the stock replacement event supplies the bounded
named consist.

## V2 envelope and correlation

The hook returns `V2|tag|target|secondary|value` with decimal integers only.
For lifecycle commands `secondary` is zero. Booleans are exactly zero or one;
maintenance is rounded to basis points in `[0,10000]`. SetLine retains the
automatic stop sentinel `-1`. SellVehicle uses target = first selected id,
secondary = selection count, and value = zero. The complete envelope is limited
to 128 bytes.

Lua accepts V1 only for the old SetLine and BuyVehicle forms. It accepts V2 only
for the explicit tag set above and validates tag-specific unused fields. Buy
and replacement use strict FIFO correlation with the vehicle-manager event.
Replacement additionally requires the GUI target to equal the visitor target.
A mismatch, malformed float/boolean, missing config half, queue overflow, or
gate-reset drop stays non-mutating and produces a visible failure.

The successful path is:

1. the stock widget creates a native command;
2. the exact visitor suppresses it before mutation;
3. the hook copies the bounded scalar record into a 32-entry queue;
4. the GUI drains at most eight records per frame and creates
   `operation.capture`;
5. normal company authorization and host order create the canonical operation;
6. both peers replay through a one-shot authorization;
7. physical result consensus and the ordinary checkpoint barrier close the
   operation.

Internal station-barrier stop commands carry a one-shot tag-8 authorization,
so they bypass capture. A real player stop remains canonical metadata and the
barrier can distinguish it from its own temporary hold.

## Automated evidence

- Native tests build synthetic exact-layout buffers for every captured tag and
  verify the emitted V2 records.
- Negative native cases reject negative targets, non-boolean bytes, NaN,
  infinity, out-of-range maintenance values, empty or malformed sale vectors,
  and a negative id anywhere in a sale vector.
- GUI tests prove every V2 tag maps to the intended canonical capture, prove
  Buy/Replace config correlation, retain narrow V1 compatibility, and reject
  malformed, unsupported, or non-zero-unused fields. They also prove a
  multi-selection sale emits no intent and reports the atomic-batch limit.
- Lua and Python independently validate every lifecycle canonical field set and
  reject wrong boolean types and maintenance overflow.
- The production operation runtime now rejects a callback-success result unless
  stop, maintenance, consist, line, depot-sale, and name readbacks match the
  ordered transaction. Adversarial tests cover same-wrong-state consensus.
- `runtime/supported-api-probe/20260809-024229` bought, controlled, replaced,
  and sold a real consist on the exact executable; every production projection
  passed and the sold entity was observably absent.
- The source-boundary ratchet, 95 Lua core tests, 75 cross-language economy
  vectors, 108 Python tests, native CTest, pinned executable/signature gate, packaging,
  and installed-tree verification are the release gate for this slice.

## Two-process widget acceptance still required

Use a disposable two-process railway service and operate only an owned train.
In order: stop, start, reverse twice, set two maintenance values, request
departure, toggle manual departure on/off, send to depot without sale, replace
the consist, test a direct single sale, and finally test sell-on-arrival only
after saving disposable evidence. After every action verify the other peer,
ownership, canonical wallet, physical/checkpoint completion, tag mismatch
count, capture drop count, and session-fault state.

Then attempt the same controls on a rival train. The native command must remain
suppressed and the canonical authorization must reject it without mutation.
The single-selection sale remains automated-only until this destructive live
test passes. Do not claim multi-selection sale support until an atomic canonical
batch codec exists and passes destructive two-process tests.
