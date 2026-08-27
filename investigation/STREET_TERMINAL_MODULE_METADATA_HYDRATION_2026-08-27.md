# Street-terminal module metadata hydration - 2026-08-27

## Live failure

In relay session `mp-23bcbc168adb0862`, Player 1 attempted several large
bus/tram terminal placements, including a disconnected terminal on flat empty
ground. Every click was captured, but the local codec rejected it before any
network submission with:

`construction module metadata contains an opaque projected value`

The repeated failures therefore did not come from road attachment, terrain,
collateral demolition, relay latency, ownership, or peer consensus.

## Cause

Build 35924's GUI-side proposal projector represents a native module
`MetadataMap` as the exact string sentinel `<userdata>`. The construction codec
correctly rejects opaque projected values in player-authored payloads, but it
also applied that rule to module metadata. Module metadata and `updateScript`
are immutable resource facts supplied by the module named in the construction,
so serializing the engine userdata itself is neither possible nor necessary.

## Fix

The codec now recognizes only the exact module-metadata sentinel and reduces it
to an empty portable map. Other opaque values remain fail-closed. Immediately
before typed native replay, the materializer resolves every module through
`api.res.moduleRep` and restores its metadata and dynamic update script from the
local content-attested resource.

This is resource-name driven rather than a hardcoded vanilla-terminal list, so
mod-defined terminal modules follow the same path as stock bus, tram, and truck
terminals.

The same audit found an independent over-broad validation guard: every depot
snapped to a canonical endpoint was rejected even though the original live
failure concerned hidden rail-depot track snapping. The guard now remains
fail-closed for rail depots attached directly to existing track, while stock
road/tram depots may reconstruct their declared `STREET` snap against the
synchronized road geometry.

## Verification

- all 216 combinations of six street-terminal templates, four platform counts,
  three lengths, and three tram modes accept the live `<userdata>` shape;
- the stock road depot and both tram-depot catenary variants retain their
  separate non-modular `STREET_DEPOT` path;
- a road depot snapped directly to an existing road passes both Lua and Python
  validation, while the corresponding rail-depot track snap remains rejected;
- a different opaque sentinel remains rejected;
- typed replay preserves repository-provided custom metadata and dynamic update
  scripts;
- source-size and architecture guards pass;
- the complete Lua, Python, PowerShell, launcher, companion, native-profile,
  recovery, packaging, integration, and replay suite passes.

## Required live check

The running `0.41.4-alpha` processes cannot receive this Lua change. In a fresh
process using `0.41.5-alpha`, Player 1 should place one large bus/tram terminal
on flat empty ground, one snapped to a road, and one with collateral demolition.
Each must appear once on both peers without a proposal-codec failure.
