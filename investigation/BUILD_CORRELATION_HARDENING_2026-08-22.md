# BuildProposal correlation hardening

Date: 2026-08-22 (Europe/Amsterdam)
Target: TPF2MP `0.38.7-alpha`, native hook `0.19.0`, Transport Fever 2 Build 35924

## Incident

During the live Player 1 test, a long ordinary track click produced no track.
The captured action was instead a valid cargo modular-station transaction: one
`.con`, 25 nodes, 24 track edges, nine cargo modules, and the transform/cost of
an earlier station ghost. Both peers rejected the same wrong transaction, so
checkpoint 17 remained converged; this was a capture-correlation failure, not
simulation drift.

The old bridge had only a cumulative suppression counter and one mutable
"latest preview" latch. The construction performance cache survived a
station/bulldozer/track transition, and click-time rebase mutated that cached
graph. A delayed visitor/apply callback therefore had no immutable identity
with which to prove which preview caused it.

## Correction

Hook `0.19.0` replaces counter inference with an explicit bounded hand-off:

- every GUI preview receives a positive, process-local correlation token;
- Lua arms that token before the native visitor can commit;
- every suppressed tag-15 visitor receives its own process-monotonic native
  generation and records the armed token in a 64-entry FIFO;
- Lua consumes `S1|generation|correlation|tag` records and looks up the exact
  retained preview, rather than selecting the newest preview;
- FIFO overflow discards the ambiguous prefix and emits a sticky `F1` fault;
- any non-zero historical drop count permanently disables further build
  capture for that game process, even after the `F1` record is consumed;
- repeated modular-station visitors may coalesce only when every native record
  carries the same token and the payload is a construction.

The GUI additionally binds each preview to company, source builder, action
family, tool generation, template signature, and frame. It rejects stale,
missing, reordered, reused, cross-company, cross-source, and cross-family
matches without submitting a network action. In particular, a track or road
builder cannot serialize a station `.con`.

Construction templates are now immutable. Rebase creates a deep private copy,
then changes that copy exactly once at the click boundary. Cached state is
invalidated on tool/family changes, build controls, cancel/close, access or
authoritative rejection, bulldozer completion, replay quarantine, company
change, network-mode change, and session change.

Network readiness requires both the native queue status and the GUI-side arm
and consume functions. A partial native injection therefore fails before
initialisation rather than advertising authority it cannot exercise.

## Automated proof

The gate now covers:

- native FIFO order, monotonic generations, exact token encoding, overflow
  fail-closed behaviour, uint64 token parsing, and status projection;
- B2 compact-sample and S1 event decoding;
- station-to-track invalidation and builder-family rejection;
- apply-source mismatch and native disarming on cancellation;
- immutable optimized construction rebase compared byte-for-byte by canonical
  digest with an isolated slow reference;
- full GUI station -> tool switch -> track reordering, explicit stale-token
  rejection, and a clean track retry;
- the previous large-station, multi-visitor edit, graphless asset, ownership,
  and preview-performance regressions.

## Required live transition gate

Use a fresh two-instance session. Exercise station -> bulldoze -> long track,
construction -> Escape/cancel -> road, signal/waypoint, rejection -> retry, and
actions originating from both peers. Wait for a clean checkpoint, then run:

```powershell
.\tools\verify_build_transition_gate.ps1 -Session <session>
```

The verifier requires active hook `0.19.0`, no FIFO drops or pending events,
strictly increasing/unique accepted identities, no ambiguous rejection in the
fresh acceptance run, construction/track/street/edge-object coverage, at least
one bulldozer action, work from both peers, and the same agreed checkpoint.

This remains a physical live gate because no automated harness can assert that
the ghost under a human cursor visually matches the intended terrain location.
The code path now makes the safe failure deterministic: if the engine emits no
usable preview for a click, nothing is replicated; an older station payload is
never used as a substitute.
