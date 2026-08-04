# Adversarial model, residue, and manifest audit

Date: 2026-08-04 (Europe/Amsterdam)  
Auditor: Codex  
Scope: `36e3b46`, `13c309d`, and the handoff in
`CODEX_HANDOFF_2026-08-04.md`  
Result: four material defect classes reproduced and closed; offline and native
build gates pass; fresh human live tests remain pending.

## Executive result

The audit did not validate demand v2 or origin-residue handling as written.
It found:

1. a reachable Lua/Python arithmetic divergence above Lua 5.1's exact integer
   range;
2. a repeatable fare-harvesting strategy worth thousands of times the best
   steady fare, plus a separate one-passenger cutoff exploit;
3. multiple post-native-apply loss paths that could still continue without a
   session fault, including the disclosed native queue overflow;
4. a real manifest design omission behind the shell-dependent test
   accommodation: private starting edges had canonical ownership but were not
   members of the operational world manifest.

All four now have code fixes and regression coverage. The economy is versioned
as model 3 so the corrected cutoff and fare-shock behavior are explicit; normal
model-v2 replay retains its legacy cutoff path.

## Finding 1: cross-language aggregate precision

### Reproduction

The public input bounds permit demand up to `1,000,000,000` and fare up to
`100,000,000` cents. Their product can exceed `2^53`, where Lua 5.1's IEEE-754
number can no longer represent every integer but Python still can.

One deterministic vector produced:

| Input/result | Value |
|---|---:|
| Allocated passengers | `999,984,937` |
| Fare | `99,999,989` cents |
| Lua revenue | `99,998,482,700,165,696` cents |
| Python revenue | `99,998,482,700,165,693` cents |

The three-cent difference is enough to fail embedded-result verification and
model checkpoints on otherwise identical peers.

### Fix

Authored v2+ revenue, demand, ledger, company, total, and scoreboard aggregates
now use matching saturating add/multiply helpers in
`economy.lua` and `checkpoint.py`. The pinned ceiling is `10^15` cents, safely
below `2^53` and unreachable in ordinary play. Legacy v1 replay keeps its old
arithmetic path.

The new differential harness generates Lua results first and independently
replays them in Python. Its 71 scenarios cover the demo trajectory, negative
glide, capacity cascades, clamps, re-upsert stock preservation, maximum
products, legacy-v2 cutoff behavior, an actual v3 hike/recovery transition,
and 64 deterministic fuzz cases. It also
proves both pinned exponential tables equal each other and the high-precision
definition `round(65536 * exp(-k/10))` for `k=0..80`.

## Finding 2: fare milking was economically dominant

### Reproduction under model v2

`tools/audit_demand_milking.py` warms the exact Python mirror to steady state,
then compares repeating one-epoch hikes plus recovery with a grid of constant
fares.

With the uncrowded two-service audit corridor and `alphaDownPm=250`:

| Measurement | Result |
|---|---:|
| Baseline at $10 | `377,000` cents/epoch |
| Best constant fare ($7) | `511,700` cents/epoch |
| Max-fare one-shot allocation | `377 -> 283` passengers |
| Max-fare one-shot revenue | `377,000 -> 28,300,000,000` cents |
| Best repeating hike/recover average | `3,966,766,000` cents/epoch |
| Cycle / best constant | `7,752.132x` |

The old asymmetric glide did punish recovery, but a line retained 75% of its
excess share for the hike epoch. Because the fare clamp is $1,000,000, that one
epoch dominated any recovery cost.

Changing all downward movement to `1000` removed retained-rider harvesting but
failed the existing crowding-stability invariant. It also exposed a second
problem: the 8-theta cutoff returned weight `1`, not zero. Under a crowded
rounding case, a permanently dominated max-fare service could receive one
passenger and earn `100,000,000` cents every epoch.

### Model-v3 fix

Model 3 makes two narrow changes:

- `lastFareCents` is authored service state and is included in the checkpoint
  digest. If the fare increased and equilibrium fell, that service adopts the
  lower equilibrium immediately for that settlement. A fare decrease still
  recovers at `alphaUpPm=80`; non-price deterioration, including lagged
  crowding, retains the stable `alphaDownPm=250` glide.
- An option at least eight theta above the best option receives weight zero.
  The model-v2 evaluator keeps its old weight-one cutoff solely for replay.

The post-fix adversary reports:

| Capacity | Best constant | Best tested hike/recover | Ratio | Max-fare allocation/revenue |
|---:|---:|---:|---:|---:|
| `5,000` | `511,700` | `363,979.21` | `0.711x` | `0 / 0` |
| `600` | `630,000` | `460,602.97` | `0.731x` | `0 / 0` |

All prior conservation, entrant-ramp, exact-convergence, and crowding-dither
invariants still pass. This is model-level proof against the searched
hike/harvest/revert family, not a substitute for a human balance test.

## Finding 3: origin residue still had silent exits

The four documented trigger sites were not complete. The audit found these
additional ways an already-applied native line mutation or its token could be
lost before an ordered commit:

- authority not ready after capture normalization;
- canonical network finance unavailable after match initialization;
- immediate bridge emission returning failure;
- normalization or bridge emission throwing instead of returning failure;
- the local deferred physical FIFO being full;
- the native 32-record post-visitor queue dropping its oldest applied record;
- the native Lua consumer throwing or returning an undecodable envelope;
- GUI-to-engine dispatch popping the action before a failed send;
- changing from network to standalone after match initialization, discarding
  the network controller's pending origin state.

Corrections:

- `network_intent_runtime.lua` converts every token-bearing rejection above
  into the same first-fault-retaining `origin-applied-*` session fault and
  best-effort ordered pause. Normalization and bridge calls are exception-safe.
- `hook_dll.cpp` exposes a sticky `F1|queue-overflow|N` sentinel before later
  line records whenever the native queue has dropped an applied command.
- `gui_event_runtime.lua` converts overflow/read/decode loss into
  `network.origin_residue`; GUI dispatch now peeks and removes only after a
  successful send, so transient dispatch failure retries the exact action.
- Match mode is immutable after initialization.

The remaining architectural limit is deliberate and visible: residue is
faulted, not inversely repaired. The local worlds may already differ at the
fault, so continued play is forbidden and recovery must start from an agreed
boundary.

## Finding 4: manifest-binding accommodation hid an omission

The network company-mapping test previously accepted either `rival-owned` or
`ambiguous across peers` for the same pre-existing edge and was reported to
vary by invoking shell.

The edge was canonically owned in `world.logicalOwners`, but
`canonicalManifest()` enumerated stations, lines, vehicles, edge objects,
assets, and constructions—not the private edges/nodes seeded from the shared
starting save. Later structural probing bound the edge without
`manifestBound`, making ambiguity the expected result.

The manifest now admits exactly logically owned starting edges and terminal
nodes. It does not enumerate autonomous town roads. A unit fixture proves the
same topology digest and three manifest-bound identities across deliberately
different local IDs. The integration test now requires the exact rival-owned
rejection; that strict test passes from both PowerShell 5.1 and Git Bash.

The other test accommodation is valid: `script.save()` intentionally returns
the live state table, so the test reads `bridge.emitted` into a number at the
measurement boundary. It does not use an aliased table as a frozen snapshot
and therefore does not hide a counter bug.

## Digest completeness result

The evaluator-read market parameters, service operating facts, share/residual/
crowding stocks, and new `lastFareCents` latch are all present in
`economyDigestView`. A regression mutates every projected evaluator input one
at a time and requires the authored digest to change. The Python v2/v3 upsert
field set matches that projection; service metadata remains intentionally
outside both.

No additional reachable Lua/Python arithmetic mismatch was found after the
aggregate fix. The intentional Lua one-based/Python zero-based exponential
table indices select the same literals, and both negative glide divisions
floor toward negative infinity.

## Verification receipt

After all fixes:

- `tools/run_tests.ps1`: PASS;
- source/architecture budgets: PASS;
- Lua: `40/40`;
- Lua/Python economy differential scenarios: `71/71`;
- runtime, edge ownership, game-script, network mapping, hot-seat, GUI,
  launcher, Lua syntax, and PowerShell syntax gates: PASS;
- Python unit tests: `43/43`;
- independent event replay: `104` events, verified;
- Git Bash strict manifest fixture: PASS;
- native Release build: PASS;
- CTest: `2/2`;
- exact executable: SHA-256/profile valid and all `17` signatures unique at
  their pinned RVAs.

No Transport Fever 2 live world was launched for this audit. The results above
are code, simulated-interface, cross-language, native-build, and exact-binary
proof—not new human gameplay evidence.

## Next live sequence

1. Fresh hot-seat match: seed the demo and settle repeatedly. Confirm an upward
   fare change drops to the new equilibrium on the next settle, reverting
   recovers gradually, and crowding remains delayed by one epoch without a
   visible relay cycle.
2. Localhost network match: settle once from host and once from client. Both
   embedded results must independently verify and converge at the following
   checkpoints.
3. Through the vanilla widgets, try a rival rename/recolor/stop edit/delete.
   The expected pass is an `origin-applied-capture-rejected:*rival-owned*`
   session fault and ordered pause on both games.
4. Submit two own stop edits rapidly behind a pending barrier. Both must emerge
   FIFO with no fault.
5. Run the five-minute owned-depot **Buy** probe and capture native tag counters;
   an assert/crash selects optimistic vehicle pass-through, while a clean
   rejection selects suppress-before-mutation.
6. Keep the two-computer populated, unpaused drift gate separate. Localhost is
   useful engineering evidence but must not be reported as that gate.
