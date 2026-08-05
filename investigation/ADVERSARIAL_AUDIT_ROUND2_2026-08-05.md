# Adversarial audit round 2: corridor binding, cargo v4, residue, vehicles

Date: 2026-08-05 (Europe/Amsterdam)  
Auditors: two independent adversarial agents, one per subject pair.  
Subjects: `db643e7` (corridor binding), `43c5b40` (model v4 cargo),
`7df9e04` (residue hardening) and the vehicle purchase/assignment slice.  
Result: **corridor binding failed its audit** — three HIGH findings composing
into an unbounded free-money exploit; **residue hardening failed its stated
invariant** at one reachable seam. Both are fixed in this commit. Cargo v4
and the vehicle slice passed.

## Corridor binding: three HIGH findings, all confirmed, all fixed

**S1-1 — registered services were immortal.** `economy.removeService` had
zero callers anywhere in the mod or companion. The ordered `line.delete`
unbound the canonical id and cleared ownership, but the economy service
stayed `enabled` with its registration-time capacity and settled revenue
every epoch forever. Deterministic on every peer, so no digest could catch
it. Pre-existing, but corridor binding raised the payout from `max(50,
vehicles*100)` to a measured 2000/epoch: register, delete the line, sell the
stock, collect indefinitely.  
*Fix:* `operation_runtime.lua` now calls `economy.removeService` when a
`line.delete` operation completes.

**S1-2 — a rival could permanently deflate a shared market.** Market demand
was recomputed on every registration from *the registering line's* routed
distance, and `upsertMarket` is a full replace, while the market cid keys
only on the town pair. Reproduced: the incumbent's direct corridor sized the
market at 30000; a rival registering a deliberately circuitous line over the
same town pair collapsed it to 3564 — an 88% permanent ratchet, since
nothing recomputes demand afterwards and (per S1-1) the attacking line never
needed maintaining.  
*Fix:* the market belongs to the town pair, not the line. Demand is now
sized by the *shortest* route anyone has found between those towns
(`metadata.corridorMeters`, monotonically minimised) and an existing
market's demand is only ever revised upward. Registration also preserves an
existing market's `kind` rather than forcing `passenger` (which closes
audit finding S2-3's latent cargo-flip path at the same seam).

**S1-3 — lines with no rolling stock earned money.** `math.max(1, vehicles)`
in the headway and capacity terms, plus the 100-seat fallback, gave an empty
two-station line 400 capacity per epoch. `makeLineService` gated only on stop
count and distinct towns, never on rolling stock.  
*Fix:* zero vehicles now yields zero capacity — a nominal headway is still
computed for display, but the service can never be allocated passengers.

## Corridor binding: MEDIUM findings fixed

**S1-4 — the fallback ladder was dishonest.** `positionOfEntity` returns a
`{0,0}` sentinel rather than nil, so an unresolvable stop measured as a real
origin coordinate and fabricated distance: one measured case produced
88 km of phantom geometry reported as `factsSource = "computed-consist"`.
Two further mislabels: a resolved consist without a usable `topSpeed`, and a
zero-seat consist, both silently took defaults under the `computed-consist`
label — so `computed-default-speed` never fired in the case it was named
for. This mattered doubly because `factsSource` is the live-verification
mechanism the slice ships for Build 35924.  
*Fix:* `world.lua` gains a strict `resolvedPositionOfEntity` returning nil
when nothing resolves (`positionOfEntity` keeps the sentinel for its other
callers), so a legitimate station at the world origin still measures
correctly while an unresolvable stop fails the computed path honestly. The
ladder now reports `computed-consist`, `computed-default-speed`,
`computed-default-seats`, `computed-defaults`, or `estimated-legacy`
according to what actually ran.

**S1-7 — station boards multiplied load by stop count.** Each stop received
the whole service's allocation: a measured 5-stop line carrying 900
passengers reported 900 at every board, 4500 summed, and ranked a tiny halt
level with a terminus.  
*Fix:* a corridor's passengers board once and alight once, so the load
distributes across stops; per-stop rows now sum back to the line's own
allocation, with the whole-line figure retained as `lineAllocated`.

## Cargo v4: passed

Every parity claim verified by execution rather than inspection: Lua/Python
generalized cost agree including the `waitWeightPm = 0` versus absent case
(both use explicit nil/None tests); v1→v4, v2→v4 and v3→v4 converge on one
field set; v3 replay is bit-identical before and after the v4 stamp
including with non-default `params.transferSeconds`; the seeded freight
corridor matches field for field across both languages; service stocks are
correctly preserved across a market kind flip. The four expected fact values
(12500 m, 536 s, 656 s, 2000) reproduce by hand from the constants.

**S2-1 (fixed here):** `util.integer` and Python's `_integer` disagreed on
coercion — `4.9999999` became 5 in Lua (epsilon before floor) and 4 in
Python; booleans and hex/exponent strings also diverged. Corridor binding
made this reachable through wire-carried `line.register` facts. Fixed on
both sides: `_integer` now treats booleans as absent like Lua does, and the
protocol validator requires every numeric market/service field to arrive as
an exact integer, so a fractional value is rejected at the boundary instead
of replaying to two different models.

## Residue hardening: the tenth path existed

All nine documented loss paths verifiably fault, with regression coverage on
the important ones. But the invariant did not survive `script.load`:

**F1 (HIGH, fixed) — save/load wiped pending origin-applied custody
silently.** The deferred FIFO, the awaiting-order latch, and the token
registry are all module-locals; `resetTransientRuntime` cleared them without
faulting, while the native mutation sits inside the saved world. An
origin-applied line capture deferred behind a routine consensus barrier and
then saved/loaded was never emitted: no operation record existed, the
companion never armed a timeout, and canonical state remained *equal* on both
peers, so every checkpoint, structure and finance digest passed forever with
the worlds physically divergent.  
*Fix:* a custody marker and the token counter now live in saved state
(machine-local, outside every digest). A non-empty marker after a reload
raises `origin-applied-custody-lost-on-reload` and the ordered pause;
monotonic tokens survive the reload, closing the collision wrinkle where a
stale commit could consume a fresh capture's registry entry. The marker is
released when an ordered commit takes the record.

**F2 (HIGH primitive, fixed) — the command-gate clear discarded applied
records without a drop count.** `NativeEnableCommandGate` cleared
`g_suppressed_line_commands` — records of mutations that *already applied* —
without incrementing `dropped`, so the sticky F1 sentinel never fired. The
GUI bootstrap retry loop can re-run this mid-session.  
*Fix:* both gate transitions now count cleared line records as drops, so the
existing sentinel reports the loss and Lua faults closed. Both functions
also deduplicate into one `SetCommandGate` helper (which kept the file
inside its architecture budget rather than raising it).

**F3 (MEDIUM, fixed) — `normaliseOperationCapture` was not exception-safe.**
A throwing normalizer escaped to `handleEvent`'s outer pcall and became a
status-line message, losing an already-applied mutation.  
*Fix:* the call is wrapped and a throw converts into the same
`origin-applied-capture-rejected` fault. Also, the token table's 64-entry
overflow now *refuses* the capture (which faults) instead of evicting the
oldest entry, which silently discarded custody.

Four new regressions cover the throwing normalizer, the deferred-emit
failure variant, and the reload fault (both the faulting and non-faulting
cases, including token monotonicity across the reload).

## Vehicle slice: passed

Confirmed **not** origin-pass-through — tags 6/13 suppress before mutation,
so no money moves at click time and the feared origin-applied-purchase
residue class does not exist. Every rejection path of an ordered vehicle
operation faults through consensus, including finance failures. The codec is
strict and cross-language congruent with no machine-local IDs and no cost
field to tamper (cost is realized natively). `SellVehicle` and every other
undecoded vehicle tag are genuinely fail-closed at the native boundary.

## Accepted, not fixed here

- **S1-5 (MEDIUM):** `normaliseForNetwork` binds into the *live* canonical
  registry during pre-commit normalisation, so a rejected intent can leave
  origin-only bindings; corridor binding widened this from 3 binds to 3+N
  station groups. Pre-existing; the same commit codified the opposite rule
  for proposals. Needs the identify-without-binding treatment.
- **S1-6 (MEDIUM):** the ordered `line.register` handler compares wire fields
  to wire fields and never validates the actor or the market/corridor
  relation. Host-authority-gated, but the host is a player, not a referee.
- **S1-8:** in network mode only the host can register a line at all — a
  design ruling is owed before the network path gets tests.
- **S1-9/10/11/12/13, S2-2/3/4:** glyph saturation above 8000, per-snapshot
  board recomputation, dropped legacy diagnostics, cargo tonnage counted as
  seats, unclamped fallback demand, the `_economy_version` default asymmetry,
  and unvalidated market metadata size.
- Native-side drop-latch and mode-immutability C++ tests.

## Verification

Full offline suite passes after the fixes: 55/55 Lua, 46 Python, boundary
budgets, native Release build against the pinned Build 35924 executable, and
the 104-event cross-language replay with an unchanged final model digest.
