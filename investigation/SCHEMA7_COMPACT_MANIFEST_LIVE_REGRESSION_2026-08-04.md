# Schema 7 compact-manifest live regression

Date: 2026-08-04 (Europe/Amsterdam)  
Build: Transport Fever 2 Build 35924, SHA-256
`782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`  
Prototype: `0.20.0-alpha`, state schema `19`, edge schema `5`, construction schema `7`

## What failed

The first final two-process run, `runtime/localhost-live/schema7-final-20260804-030645`,
and an unchanged retry, `runtime/localhost-live/schema7-retry-20260804-031318`,
both reached the same initial checkpoint and then opened Transport Fever 2's
generic `Internal error` dialog on the host while applying the first
host-origin 25,000 track proposal. The client remained connected and eventually
reported the missing host physical result. Native evidence recorded an exact
Build 35924 profile, no unknown command tags or layout mismatches, and a
successful BuildProposal visitor return immediately before each engine crash.
Both minidumps and runner trees were retained; neither failed run was counted as
a passing gate.

## Cause and correction

Schema 19 strengthened construction and `ASSET_GROUP` fingerprints with named
rendered models and construction parameters. That correctly distinguished
objects, but it also turned hundreds of generated town buildings and decorative
assets into eagerly bound operational canonical entities. The complete row
inventory and all bindings were retained in persistent game-script state, which
Build 35924 copies at a native proposal boundary. The same proposal passed in
the preceding compact state and failed twice after this expansion.

The corrected policy separates shared-world verification from operational
identity:

- every construction/asset still contributes its stable fingerprint to the
  world-manifest digest;
- unselected construction and asset roots are not eagerly inserted into the
  operational canonical registry;
- a selected root is bound lazily by the ordinary proposal capture path, using
  the same stable pre-existing canonical ID;
- persistent probe state keeps only manifest version, digest, and counts rather
  than the full row inventory;
- the GUI exposes the number of deferred scenery fingerprints.

This is also the right gameplay boundary: autonomous town scenery is shared
world evidence, not player-owned multiplayer state.

## Passing live result

`runtime/localhost-live/schema7-compact-20260804-032006` repeated the exact gate
with two real game processes and both native hooks active. It crossed the
previously crashing host proposal, completed a client-origin proposal, and
agreed the corresponding checkpoint barriers.

- Player 1 checks: `32`, passed.
- Player 2 checks: `27`, passed.
- Final core digest on both peers: `73af1552`.
- Final structural digest on both peers: `53bb77bb`.
- Audit: 7 commits, 5 controls, 127 telemetry records, 7 convergences,
  2/0/0 complete/faulted/pending physical proposals, 3/0/0 checkpoint
  barriers, 6 checkpoints, and 38 events (30 chained).
- Settings were restored byte-for-byte; temporary bootstrap, game-script, and
  library injections were removed; both disposable game processes were closed.

The offline regression suite now has a dedicated test proving that decorative
assets/constructions remain deferred while a selected asset binds lazily.

## Remaining boundary

This result proves the current state-19/schema-7 build still performs
bidirectional physical proposal and checkpoint consensus in independent live
worlds. The depot, arbitrary-construction, signal, and station-edit engine
shapes have separate exact-build one-process proof. Their remaining gate is the
ordinary player-UI two-process matrix, followed by a two-computer playtest.
