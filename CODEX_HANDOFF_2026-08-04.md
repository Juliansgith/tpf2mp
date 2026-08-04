# Handoff: audit and live-test the 2026-08-04 session's work

Audience: Codex (or any agent that can build, run, and interact with the
game). Author: Claude, working in this repository on 2026-08-04. Everything
below is pushed to `origin/main`. Three commits are in scope:

| Commit | Content |
|---|---|
| `498f982` | Module-split refactor (authored by the project owner; verified against the full offline suite and committed as-is) |
| `36e3b46` | Fail-closed handling for rejected origin-applied line operations |
| `13c309d` | Demand model v2: generalized cost, integer logit, share stocks, schema 20 |

Run `tools/run_tests.ps1` before anything else. It must end with
`All TPF2MP tests passed.` including the 104-event cross-language model
replay. If it does not, stop and report; do not run live sessions over a red
offline suite, and do not weaken an assertion to make it pass.

---

## Part 1 — What was changed and why

### Commit `36e3b46`: origin-residue fail-closure

Background fact (discovered earlier on 2026-08-04, documented in
`investigation/VANILLA_LINE_MANAGER_CAPTURE_2026-08-04.md`): the five vanilla
line-manager command tags (3 CreateLine, 4 DeleteLine, 5 UpdateLine,
28 SetColor, 29 SetName) cannot be suppressed at their native visitors —
Build 35924 feeds an invalid EntityRev into the Line Manager callback and
asserts. The hook therefore passes them through: **the origin's native world
mutates before host order**, and the ordered transaction later binds the
already-applied local result while the peer replays normally.

Consequence closed by this commit: any rejection of such an origin-applied
operation after native application leaves a one-sided world mutation that can
never be ordered. Previously three paths whispered to the status line and
continued with silently diverged worlds. Now:

1. **Capture-time authorization is a strict superset of commit-time
   `operationAccess`.** `bindLocal` inside `normaliseOperationCapture`
   (game script `tpf2_mp.lua`) now rejects rival-owned targets — resolved via
   `world.logicalOwnerOf` OR binding metadata, exactly like commit-time — and
   ambiguous pre-existing bindings, for every operation kind and for line
   stops. The `line.delete` origin-applied branch got the same owner
   resolution.
2. **Every rejection of an origin-applied operation raises
   `state.world.operationConsensus.sessionFault`** (errorCode prefix
   `origin-applied-*`) and emits a best-effort ordered pause
   (`clock.request` speed 0 — the one intent a faulted session may still
   apply). Four trigger sites, all in
   `tpf2_mp_1/res/scripts/tpf2_mp/network_intent_runtime.lua` unless noted:
   - normalise failure of a capture with `capture.originApplied == true`
     (in `submitIntent`);
   - `network.intent_rejected` control matching an awaiting-order intent
     whose latch carries `originCaptureToken` (the latch now records the
     token in `emitNetworkIntent`);
   - emit failure of a deferred intent carrying `originCaptureToken`
     (in `processDeferredNetworkIntent`);
   - the GUI CreateLine 120-frame timeout ("completed without an
     identifiable local output") now queues a `network.origin_residue`
     action (`gui_event_runtime.lua`), a new intent type handled at the top
     of `submitIntent`.
   The first fault is retained; later residues do not overwrite it. Pause
   emission failures are logged as `origin-residue-pause-failed`.
3. **Commit-time rejection already faulted both peers** through the
   companion's operation-outcome control; unchanged, now relied upon
   explicitly.

Tests added: a fault harness block in `tests/run_runtime_module_tests.lua`
(origin-applied rejection faults; plain mod-panel rejection does not;
GUI-reported residue faults; standalone mode refuses) and an end-to-end
extension at the bottom of `tests/run_network_company_mapping_tests.lua`
(token visible on the wire, tokenless rejection releases the FIFO latch
without fault, token rejection faults with the ordered pause written to the
outbox, first-fault retention, capture-time rival rejection).

Docs corrected in the same commit: the investigation doc's summary previously
claimed the visitor "rejects the original local command before mutation" —
false for the origin peer. It now names the pass-through model and the
residue closure. README's equivalent claim fixed.

### Commit `13c309d`: demand model v2

Replaces the additive attractiveness weights
(`100 + 3600000/headway + 7200000/journey + quality*25 − fare*2`) with a
discrete-choice model. All arithmetic is integer and deterministic.

**Lua**: `tpf2_mp_1/res/scripts/tpf2_mp/economy.lua` (complete rewrite,
`M.VERSION = 2`). **Python mirror**: `companion/tpf2mp/checkpoint.py`
(`_upsert_market_v2`, `_upsert_service_v2`, `_generalized_cost`,
`_logit_weight`, `_glide_step`, `_evaluate_market_v2`, `_evaluate_all_v2`),
dispatched on the replayed economy's `version` field so recorded v1 traces
still verify on the legacy code path.

Model, per market evaluation:

1. **Generalized cost in cents** per service:
   `GC = fare + votCentsPerHour·journey/3600 + vot·min(headway/2, maxWait)·2/3600
   + vot·transfers·480/3600 + crowd − quality`, floored at 1. `crowd` =
   in-vehicle time cost scaled by `clamp(lagLoadPpm − 700000, 0, 300000)/300000`
   where `lagLoadPpm` is the **previous** epoch's realized load factor
   (lagging kills the within-epoch fixed point and the denial-relay
   oscillation).
2. **Integer logit**: `weight = exp(−(GC − GCmin)/θ)` scaled to 65536, via a
   pinned 81-entry table `round(65536·exp(−k/10))`, linear-interpolated in
   centinats, cut off at 8θ. The table literals are duplicated byte-for-byte
   in both languages. The outside option enters with its own
   `gcOutsideCents`, so improving the best service shrinks the anchor gap
   and grows ridership (induced demand).
3. **Equilibrium shares** in ppm via the existing largest-remainder
   `proportional` split (unchanged; its cid tie-break is the determinism
   anchor).
4. **Share is a stock**: each service glides
   `share += floor(((eq − share)·α + resid)/1000)` with the residual carried
   (drift-free, converges exactly — no `1000/α` stall). α is
   `alphaUpPm = 80` toward gains, `alphaDownPm = 250` toward losses: entrants
   climb from zero, abandoning a position is ~3× faster than building one
   (the milking defense). A service upserted fresh starts at `sharePpm = 0`;
   a re-upserted service keeps its earned stocks; a migrated v1 service has
   `sharePpm = nil` and initializes at equilibrium on its first evaluation
   (grandfathering).
5. **The outside option is the conservation residual**
   (`1e6 − Σ service shares`), so conservation is exact and a collapsing
   service dumps riders to not-traveling immediately while survivors climb at
   `alphaUp`.
6. Allocation of `market.demand` by glided shares through the existing
   capacity cascade (unchanged), then `lagLoadPpm` writeback.

Authority/replay integration:

- `acceptAuthoritativeResults` now verifies host-embedded results by
  **independent local re-evaluation on a deep copy plus canonical digest
  comparison** (`hash.value`), adopting the copy's epoch/services/lastResults
  only on match. A tampered or divergent result rejects without mutating
  local stocks (a unit test asserts this non-mutation).
- Python `economy.settle` replay for v2 re-executes `_evaluate_all_v2` (so
  the stocks advance in the replayed model) and, when the recorded action
  embeds results, verifies them by `checksum` equality.
- `economyDigestView` in `checkpoint_runtime.lua` now projects the v2 market
  parameters, service `transfers`, and the three stocks
  (`sharePpm`/`shareResid`/`lagLoadPpm`) — they decide future allocations, so
  they are authored convergence state. This projection is also exactly the
  model the Python replayer mutates; its field set must remain identical to
  what `_upsert_*_v2` writes (services deliberately carry no `metadata` on
  the Python side because the digest view does not project it).
- `STATE_VERSION` 19 → 20; `state_schema.lua` routes saved economies through
  `economy.migrate`. Docs updated (README, PROTOTYPE_STATUS,
  REMAINING_FROM_BRIEF headers and the demand row).

New invariant tests in `tests/run_lua_tests.lua`: cent-factor sum equals GC;
induced demand; exact conservation every epoch with an entrant present;
monotone entrant ramp reaching ≥90% of equilibrium in 60 epochs; milking
asymmetry (one-epoch loss > 2× one-epoch recovery); exact integer
convergence `sharePpm == equilibriumPpm` after 400 epochs; crowded steady
state bounded within 1000 ppm (measured amplitude ≈196 ppm, caused by
one-passenger allocation quanta flipping one cent of crowd cost — a relay
cycle would swing tens of thousands); digest-equal independent replays.

---

## Part 2 — Audit assignment

Audit adversarially. The claims most worth attacking:

1. **Cross-language arithmetic parity.** Diff `M.generalizedCost` against
   `_generalized_cost`, `M.logitWeight` against `_logit_weight` (note the
   deliberate index-base difference: Lua reads `EXP_TABLE[index+1]` and
   `[index+2]`, Python `[index]` and `[index+1]` — same entries), `glideStep`
   against `_glide_step` (Lua `math.floor(delta/1000)` on negative deltas
   must equal Python `delta // 1000` — floor toward −∞, not C truncation),
   `evaluateMarket` against `_evaluate_market_v2` line by line, iteration
   order (`util.sortedKeys` vs `sorted()`), and the upsert clamps. Any
   mismatch is a real divergence bug even if the current test corpus does not
   hit it. Also verify both exp tables equal
   `round(65536·exp(−k/10))`, k = 0..80, and treat the literals as pinned:
   regenerating them with a local libm at runtime would defeat their purpose.
2. **Digest-view completeness.** `economyDigestView` must project every field
   the v2 evaluator reads (params, market vot/gcOutside/theta, service
   operating facts + transfers + three stocks). A missing field is a hidden
   divergence class: peers could differ there while checkpoints stay green.
   Check I missed nothing; check the Python `_upsert_*_v2` field sets match
   the projection exactly.
3. **Residue-path completeness.** I closed four rejection paths. Hunt for a
   fifth: any way an `originApplied` capture or token-carrying intent can
   die without `raiseOriginResidueFault` running. Known, deliberate
   remainder: the native hook's capture queue drops its **oldest** record
   when full (`kSuppressedLineCommandQueueLimit`); a dropped record is an
   applied mutation that never reaches Lua. It is observable in the hook's
   drop counters and session audits but does not fault. Judge whether that
   is acceptable or should escalate too.
4. **The α-asymmetry milking claim.** The invariant test asserts a specific
   inequality; try to construct a fare schedule that profits from
   hike-harvest-revert anyway (e.g., exploiting the one-epoch lag or the
   revenue on the glide path). If one exists, the α values or the settle
   cadence need retuning; the parameters live in `economy.defaultParams()`.
5. **Test honesty.** Two spots earned extra scrutiny during the session:
   the company-mapping extension accepts either "rival-owned" or "ambiguous
   across peers" as the rival-rename rejection because the fixture's
   manifest-binding state differs between invoking shells (see Part 4); and
   the harness's `script.save()` returns live-aliased state, so tests must
   freeze counters as numbers (a comment marks this). Verify neither
   accommodation hides a real defect.

---

## Part 3 — Live test assignment

Tooling: `tools/multiplayer_launcher.ps1` (Host / Join / automated Localhost
Test / status / logs / stop), `tools/run_localhost_live_validation.ps1`
(disposable two-instance harness), `tools/get_network_session_status.ps1`,
`tools/get_native_hook_status.ps1` (per-tag gate counters),
`tools/collect_live_evidence.ps1`. Follow the house rule: every live session
gets an evidence bundle, and findings become dated files in
`investigation/`. A session fault during tests 3–4 below is the *expected
pass outcome*, not a failure to debug away.

### Test 1 — Hot-seat demand playtest (highest value)

Launch hot-seat, initialise the match, click **Seed Demo Market**, then
**Settle Epoch** repeatedly. The market panel prints, per service:
`eff $X = fare F + time T + wait W + xfer 0 + crowd C - comfort Q | share a.b% -> eq c.d%`.

Expected trajectory (tolerances loose; interpolation rounding shifts a few
units): both seeded services start near zero share and climb ~8% of their
gap per settle. Approximate equilibria: company-1 service ≈ 40.0% (GC 1312),
company-2 service ≈ 59.7% (GC 1212), outside ≈ 0.3%. First settle allocates
roughly 32 and 48 passengers of 1000; by settle 30+ roughly 320/480; wins go
to company 2 throughout.

Then run a fare war with the **Fare -1.00 / Fare +1.00** buttons on a
selected line: cutting company-1's fare by $2 should flip the equilibrium
and the shares should visibly chase it; raising a fare must bleed share
noticeably faster than the recovery after reverting (watch three settles
each way). Deliberately keep one service's capacity small relative to its
share and confirm a nonzero `crowd` term appears the epoch *after* it runs
full, pushing its equilibrium down.

Report subjectively too: does the corridor feel like a contest with
momentum, or a spreadsheet? Is per-settle α = 80/250 too slow or too fast at
the cadence you actually clicked Settle? That judgment feeds the parameter
table directly.

### Test 2 — Network settle (embedded-results verification live)

In a localhost two-instance session: seed and settle from the host, then
settle again from the client. Every settle now ships host-evaluated results
that BOTH peers must independently re-derive and checksum-match before
adoption. Expected: clean ordered commits, no `operationConsensus` fault,
converged checkpoints afterward. A fault here means cross-machine model
divergence — collect both evidence bundles immediately; that would be the
most important bug this handoff can catch.

### Test 3 — Acceptance item 4: rival edit through vanilla widgets

In a localhost session, first confirm an own-asset lifecycle still works
(New Line, rename, add stop, delete — all previously live-proven). Then, as
player 2, attempt to rename/recolor/edit/delete a player-1 asset through
the ordinary game UI (entity window rename, line manager if reachable).
Expected: the origin's native world applies the edit locally (pass-through),
the capture is rejected at normalise, the session faults with
`origin-applied-capture-rejected:...rival-owned...` (or the ambiguity
variant on a pre-existing asset), BOTH games receive the ordered pause, and
the overlay shows FAULTED. Anything else — especially a healthy-looking
session with a one-sided edit — is a live gap in the residue closure: bundle
evidence and file it.

### Test 4 — FIFO stress

Same session shape: submit two vanilla stop edits in quick succession while
a barrier is pending. Expected: both apply in order on both peers via the
deferred FIFO; no fault, no lost click.

### Test 5 — Vehicle assert probe (five minutes, decides the next slice)

In a network session with gates active, open an owned rail depot and click
**Buy** on any locomotive. Record which of two outcomes occurs:
(a) the game asserts/crashes → vehicle tags need the optimistic pass-through
model, like lines; (b) the click is silently rejected, no crash, no vehicle
→ plain suppression is viable for vehicles. Either outcome is a successful
measurement. Capture `get_native_hook_status.ps1` output before/after (the
per-tag suppressed/passthrough/invalid counters are the receipt). Do not
build any vehicle capture code yet — this measurement selects the design.

### Deferred (needs a second physical machine / human)

The two-computer populated unpaused run (gate 2 in
`REMAINING_FROM_BRIEF.md`) remains the decision-quality gate and now doubles
as the moving-world drift measurement. Out of scope for a single-machine
agent; do not simulate it with localhost and claim the gate.

---

## Part 4 — Known open items (pre-existing or explicitly deferred)

- **Manifest-binding nondeterminism**: `tests/run_network_company_mapping_tests.lua`
  yields `manifestBound == true` for pre-existing edge 92 under git-bash but
  not under PowerShell 5.1 (fresh bridge dirs, same lua.exe). Possibly mock-
  harness looseness, possibly a real path/iteration-order sensitivity in
  manifest binding — which would be a cross-peer ambiguity vector in
  production. Untriaged; a task chip exists for it.
- Origin residue is faulted, not repaired; inverse-repair (and its
  Delete-Line floor) is documented as future work in the capture doc.
- α is per-settle, not per-game-time; if settle cadence becomes automatic,
  re-derive α from the calendar.
- One market per service; shared capacity across segments (multi-stop lines
  spanning multiple markets) is a known v2-model cliff, deliberately not
  built.
- Hook capture-queue overflow drops oldest applied records (observable, not
  faulted) — see audit item 3.
