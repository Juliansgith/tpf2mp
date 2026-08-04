# Two-instance localhost network proof on Build 35924

Date: 2026-08-02 (Europe/Amsterdam)  
Prototype: `0.15.0-alpha`  
State/checkpoint/proposal schemas: `12 / 2 / 2`  
Pinned executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

> Superseded evidence note: this document preserves the first one-origin run and its bring-up failures. Prototype 0.16 later passed two-origin replay, canonical quoted-cost finance, three checkpoints, and a 600-tick soak in `runtime/localhost-live/localhost-20260802-175636`. See [BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md](BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md).

## Result

Yes: this PC can run two real Transport Fever 2 Build 35924 processes and use them as independent `player1` host and `player2` client worlds over `127.0.0.1`. The passing run is:

`runtime/localhost-live/localhost-20260802-144832`

The disposable harness ended with:

```text
PASS two live game processes converged: core=818c056f, structure=65335255
audit valid: 4 commits, 3 controls, 38 telemetry records, 4 converged,
physical proposals complete/faulted/pending=1/0/0,
checkpoint barriers complete/faulted/pending=2/0/0
PASS disposable two-instance localhost live validation
```

This is the first end-to-end proof in this project that two actual game processes—not Lua interface simulations—can consume one ordered network session and converge after a native physical mutation.

## What the passing run exercised

The harness performed all of the following without human input:

1. Verified the exact executable hash, PE metadata, 17 native signatures, the BuildProposal visitor, and all 23 consequential-command visitors.
2. Started host/client TCP companions on `127.0.0.1:29742` with the same content fingerprint.
3. Started two ordinary-window game processes sequentially, injected the native hook into each exact PID, and entered two independently created disposable worlds.
4. Required both native BuildProposal and consequential-command authority gates to be active before network traffic was accepted.
5. Initialized the same canonical two-company match and normalized both canonical companies to 5,000,000 cash and zero competitive loan in each process.
6. Compared canonical companies/towns, model, structure, and finances at the initial all-peer checkpoint.
7. Issued a host-ordered native mobility probe and required matching peer digests.
8. Serialized, broadcast, materialized, and geometrically bound one private electrified track edge plus two nodes at `(1400,-1400)`.
9. Required both processes to report the same canonical outputs and physical/core result digest.
10. Normalized the Build 35924 wallet effect from the proposal origin, then required the second structural/financial checkpoint to converge.
11. Held the authored structure stable for 60 validation ticks and required a second mobility digest match.
12. Closed only the disposable PIDs, replayed the audit independently, removed temporary base-resource injection and `steam_appid.txt`, and restored `settings.lua` byte-for-byte.

Final canonical/core digest was `818c056f`; final structural digest was `65335255`. The audit retained four ordered commits, three ordered controls, one completed physical proposal, two completed checkpoint barriers, and no physical/checkpoint fault.

## Multi-instance startup findings

Build 35924 normally delegates direct executable startup to the already-running Steam client, which collapses a second launch into the existing application. A temporary `steam_appid.txt` containing app ID `1066780`, combined with `SteamAppId`/`SteamGameId` for the child processes, allowed two exact executable processes under the logged-in Steam account.

The two renderers share Steam userdata, settings, shader/profile caches, and the ordinary game log. Simultaneous cold startup was unstable. The reliable procedure is sequential:

- back up and minimally pin the shared settings;
- start process 1 and wait for its menu bootstrap;
- inject and validate its hook;
- start process 2 and wait for its menu bootstrap;
- inject and validate its hook;
- only then enter both worlds.

Hidden game windows have no targetable main-window handle, and minimized startup reached Build 35924's generic Internal error path. The harness therefore uses ordinary windows and exact-PID input automation. Calling `app.startGame()` from a menu-script update was also unsafe because it re-entered the UI stored-function renderer; the passing route issues the call through the exact-PID console path instead.

`app.startGame()` did not reliably activate the selected gameplay mod in this route. The harness temporarily mirrors only the TPF2MP game script/library into base resources, verifies each target is absent first, and removes the injection in `finally`.

These are laboratory constraints, not requirements for normal two-computer play, where each computer runs only one game process and has its own userdata/cache.

## Failures that made the proof stronger

The successful session followed several deliberately preserved failing runs:

- `localhost-20260802-141331`: initial checkpoint exposed machine-local match ticks and native seed-loan/player mapping in the consensus view. Canonical match state now excludes local ticks; canonical finance explicitly separates native loan principal.
- `localhost-20260802-142210`: the first initial barrier converged, then a client UI reentrancy/access violation showed that automated game worlds must avoid human-facing render/update work. Automated GUI lifecycle is now minimal.
- `localhost-20260802-142529`: native mobility converged, but Lua encoded empty removal tables as JSON `{}` while Python required `[]`. The strict boundary now accepts only an empty object as Lua's empty-list spelling and keeps its digest representation intact.
- `localhost-20260802-143217` and `localhost-20260802-144232`: both games created and bound the same track, but only the proposal-origin machine received the native 25,000 debit. GUI-state balance sampling returned a stale zero delta. Completion finance is now sampled in a later engine update; physical consensus excludes the engine-local wallet timing, the origin delta is authoritative, and the ordered outcome normalizes every canonical wallet.

The final pass therefore covers faults discovered at native startup, UI lifecycle, cross-language serialization, local player mapping, and asynchronous finance timing.

## User-facing launcher consequence

`LAUNCH_TPF2MP.cmd` now opens a control panel with:

- **Host + Launch Game**;
- **Join + Launch Game**;
- **Run 2-Instance Localhost Test**;
- connection/readiness status, exact content fingerprints, logs, and exact-session stop controls.

The launcher writes a short-lived validated `%TEMP%/tpf2mp_launcher/active.ini`. The installed mod reads it during setup, so peer, session, bridge path, and Network mode no longer have to be selected manually. Steam launch and exact-build hook injection are then performed automatically.

The packaged launcher backend was separately exercised as session
`release-shutdown-final-20260802`. Host and Join produced the same release
fingerprint, connected over TCP, exposed accurate service status, and stopped
cleanly. This caught a packaging-specific lifecycle issue: PyInstaller's
one-file executable retains a supervisor process around its service process.
Session state now records both PIDs, trusts the service PID only after matching
its session/peer/fingerprint status, validates the executable and command line
before stopping it, stops the supervisor first, and sweeps only matching
session/peer children. A delayed post-stop check left zero matching
`tpf2mp.exe` processes.

A normal gameplay mod cannot provide a dependable main-menu multiplayer button because gameplay mods are selected/loaded during game setup rather than acting as a persistent main-menu network runtime. The external launcher is therefore the authority boundary; the in-world panel remains the match and connection display.

## Honest remaining boundary

This proof validates the supported canonical linear road/track/node slice. It does not make the whole vanilla UI network-playable. Stations/constructions, complex topology, lines, vehicles, signals/edge objects, naming, sale/replacement, town/industry authority, and passenger/cargo steering still need category-specific capture, canonical codecs, replay, finance, and postcondition consensus. The native gate rejects the selected unsupported consequential commands instead of letting them diverge.

The two processes also shared one Steam userdata directory. That was controlled well enough for a disposable drift test, but it is not evidence for long-duration interactive dual-instance play on one account. Normal same-area multiplayer testing should now move to two PCs with a byte-identical starting save and identical fingerprints.
