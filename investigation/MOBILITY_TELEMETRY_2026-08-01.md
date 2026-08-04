# Passenger and cargo mobility telemetry — 2026-08-01

## Question

Can the prototype make native passenger/cargo behavior deterministic across multiple Transport Fever 2 clients?

Not yet. The repository now has the deterministic snapshot, protocol, and comparison pipeline, which is the prerequisite for knowing whether worlds agree and whether later steering works. The final live run also found that the tested Build 35924 mod states do not expose the required reads, so useful live counts are not yet available through this bridge.

## Supported read surface

The official engine API is read-only and exposes systems used by the implementation:

- `simPersonSystem.getCount()` for total native people;
- `simPersonSystem.getSimPersonsForLine(line)` for person membership on a line;
- `simCargoSystem.getSimCargosForLine(line)` for cargo membership on a line;
- `simPersonAtTerminalSystem.getEdgeInfoMap()` and `getNumFreePlaces(edge)` for aggregate terminal-edge/free-place evidence;
- the existing line/vehicle systems for canonical line identity and line vehicle count.

`world.mobilitySnapshot(registry)` calls these functions defensively and converts their results into:

- availability flags;
- total people;
- per-canonical-line passenger, cargo, and vehicle counts;
- summed passenger/cargo line uses;
- terminal edge and free-place aggregates;
- a deterministic digest over only those stable fields.

Native person, cargo, edge, line, and vehicle entity IDs never leave the function. Lines are bound through the existing canonical registry and sorted by canonical ID. Errors are reported for diagnosis but deliberately excluded from the digest so machine-specific error text cannot fabricate a structural mismatch.

## Live Build 35924 finding

`runtime/live-validation/20260801-183544/research.md` again reports all four required mod-state capabilities false in both the engine and GUI probes (the earlier `20260801-164040` result is identical):

- `simPersonCount`;
- `simPersonsForLine`;
- `simCargosForLine`;
- `simPersonTerminalInfo`.

The snapshot code therefore returns availability flags and an evidence digest but no useful person/cargo totals in that fresh world. The official read surface remains relevant for other Lua contexts and as a native anchor, but this live result prevents claiming that passenger/cargo observation already works from the production game-script state.

## Ordered network comparison

The UI button **Sample Pax / Cargo** submits a fieldless `probe.mobility` intent. It is host-authority-only, so the host assigns the event and sample identity. Each game then samples its own native world and emits a `mobility` record with that shared sample key and its digest.

The companion groups reports by sample key:

- two or more identical peer digests: `mobility sample ... converged`;
- differing peer digests: `MOBILITY DIVERGENCE ...`.

Protocol validation rejects client-supplied fields on the action. Tests cover both convergence and divergence. Research Markdown includes the latest digest and key totals.

## What this does and does not synchronize

The competitive demand/score model already runs authoritatively on the host; clients do not recompute it from local population. A local native-agent mismatch therefore does not directly corrupt the host score.

It still matters materially. Divergent passengers, cargo, queues, or town state can change what players see, route feedback, capacity inputs, and the validity or result of later physical commands. Empty trains winning an authoritative market would be a product failure, not a cosmetic detail.

The new telemetry:

- detects aggregate divergence;
- creates an acceptance metric for future steering;
- avoids pretending local agent IDs are stable;
- supplies forensic evidence keyed to the authoritative event log.

It does **not**:

- synchronize individual agents;
- inject passenger or cargo entities;
- force route/path choices;
- equalize queues or vehicle loads;
- control engine scheduling or RNG;
- prove two instances converge over time.

## Next experiments

1. Create competing passenger and cargo lines in a disposable asset-heavy save and record repeated samples at pause, normal speed, and after save/reload.
2. Run the same frozen starting save in two processes and identify time-to-first mobility divergence while structural inputs remain unchanged.
3. Compare authoritative demand allocation with native line counts/loads and define a directional-coherence acceptance threshold.
4. Test supported levers first: host-authored town capacities/cargo needs, industry manual development/output policy, service capacity, and discrete growth events.
5. If supported levers cannot meet the threshold, locate the smallest native mutation point that can inject/withhold/redirect cargo or passenger demand without replacing the entire agent scheduler.
6. Repeat mobility samples after every steering event and reject the feature if it creates structural or accounting side effects.

Exact agent-for-agent identity is not an MVP requirement. Directional agreement between authoritative demand and the visible operational world is.

## Primary references

- [Transport Fever 2 engine API and simulation systems](https://wiki.transportfever2.com/api/modules/api.engine.html)
- [Transport Fever 2 command API](https://wiki.transportfever2.com/api/modules/api.cmd.html)
- [Transport Fever 2 API types](https://wiki.transportfever2.com/api/modules/api.type.html)
