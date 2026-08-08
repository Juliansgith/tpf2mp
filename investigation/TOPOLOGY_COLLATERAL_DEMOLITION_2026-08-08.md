# Atomic topology edits with collateral demolition

Date: 2026-08-08 (Europe/Amsterdam)

Status: implemented and fully offline-tested in prototype `0.29.0-alpha`;
fresh two-process proof through houses and a tunnel portal remains required.

## Problem

A normal Transport Fever 2 road/track click can be one native transaction that
both changes topology and removes obstructing constructions. Schema 7 formerly
required exactly one construction change and routed construction removal through
a separate engine helper. A track or tunnel through a house could therefore be
rejected, or worse, be split into a demolition and a later topology build.

Splitting is not acceptable for multiplayer. One peer could demolish the house
and fail the track, leaving finance, bindings, and physical worlds in different
states.

## Portable representation

For a topology edit with construction removals, capture now:

- canonicalizes every removed construction/asset identity;
- chooses the canonically first item as the construction source;
- records the rest as sorted, unique collateral;
- rejects a duplicated source, invalid kind, local id, or unsorted payload;
- retains all ordinary named street/track, node, signal, waypoint, resource,
  cost, ownership, and dependency fields.

The compound path is intentionally narrow. It requires new/replacement topology
in the same transaction. A station or ordinary construction bulldoze that only
removes its generated edges/nodes remains on the established multi-tick
construction helper path.

## Atomic replay and settlement

Every peer preflights the portable transaction. At the ordered physical phase,
the GUI runtime materializes one native `BuildProposal` containing both the
street/track proposal and the complete `constructionsToRemove` vector. The
engine therefore accepts or rejects the click atomically.

Native success alone is not enough. Before canonical bindings are retired or
money is charged, finalization verifies that each original construction/asset
component kind has actually disappeared. Entity-id reuse by the same native
command is tolerated only when the old kind is gone. A retained obstruction
fails the physical proposal closed.

## Evidence

Lua codec coverage proves deterministic source/collateral ordering, duplicate
rejection, portable validation, and materialization of two local construction
ids into one proposal. GUI tests prove schema 7 selects the GUI BuildProposal
path. Runtime tests prove collateral postcondition checking and that compound
edits never enter the split construction helper. Python independently validates
the same fields and bounds.

The full network-company integration suite also proves that delayed generated
station topology still waits on the old construction lifecycle. That regression
failed when the compound predicate was initially too broad and is now an
explicit boundary test.

## Live acceptance

On both Player 1 and Player 2:

1. lay ordinary track through one house;
2. lay a tunnel whose portal removes one or more houses;
3. confirm the track/tunnel and every demolition appear together on both peers;
4. confirm only the issuing company pays;
5. immediately perform another build and a station bulldoze to prove both
   proposal paths remain usable.
