# Slot-local station preflight regression - 2026-08-31

## Outcome

Relay session `mp-2b831d5eac67c488` faulted when Player 1 placed a second
modular rail station. The first station completed on both peers. The second
transaction removed two collateral constructions and then both peers rejected
the station replay with:

```text
canonical node preflight API is unavailable
```

This is a `0.42.4-alpha` regression in the last-moment canonical attachment
guard, not relay delay or peer divergence.

## Evidence

Proposal 8, digest `7fbee410`, was the first station. It contained 74 new
nodes, 72 new track edges, one construction, no existing canonical node
references, and no collateral. It completed on both peers and crossed
checkpoint 9.

Proposal 12, digest `bcc7bc62`, was the second station. It had the same
slot-local 74-node/72-edge shape and no existing canonical node references,
but it also named two collateral construction roots. Both peers completed the
collateral stage, then returned the same native failure. The host correctly
faulted closed as `native-rejection-mutated-prepared-core` because the
collateral stage had already changed the prepared world.

The relay remained paired throughout. Host and Join emitted the same error,
proposal digest, result digest, and authored post-digest.

## Cause

`gui_replay_reference_guard.validate` required GUI access to
`api.engine.getComponent` before it inspected the transaction. That API is
needed only when a new edge attaches to an already canonical node through a
`cid`. A fresh station's edges refer exclusively to negative transaction-local
`slot` nodes, so there is no live entity to preflight.

The first station remained on the ordinary construction helper. Collateral on
the second station selected the staged exact GUI path introduced for atomic
demolition plus construction, exposing the unconditional check.

The guard also used `type(value) == "function"`, although Build 35924 API
functions may be callable table/userdata wrappers. The rest of the runtime
uses the project's callable predicate for that boundary.

## Correction

The reference guard now:

1. collects unique canonical `cid` endpoints first;
2. returns success immediately when every endpoint is transaction-local;
3. requires the engine component API only when a canonical endpoint exists;
4. accepts Build 35924 callable function/table/userdata wrappers; and
5. retains fail-closed entity-existence and `BASE_NODE` checks for real
   canonical attachments.

## Regression protection

The GUI suite now covers the exact failed shape: a staged fresh station with
two collateral construction removals, slot-only edge endpoints, and no GUI
component API. It must pass preflight. Separate cases prove that a canonical
attachment still rejects without the API, accepts a callable wrapped API, and
rejects a disappeared node.

The faulted live session is restore-only; the fix prevents the failure in a
new session but cannot reconstruct its already staged physical mutation.
