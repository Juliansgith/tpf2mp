# Rapid line edits and snapped-depot replay — 2026-08-26

## Outcome

Relay session `mp-094022e94f4ae9c3` exposed two independent ordering/topology
failures. The first session fault occurred while the stock Line Manager emitted
`CreateLine` followed immediately by two `UpdateLine` commands. The second was
an unsupported depot payload whose generated access edge silently snapped to
an existing canonical track node.

Neither failure was relay transport latency. The room remained paired and the
last healthy checkpoint was boundary 29 with core digest `404e181f`.

## Line-command root cause and correction

Vanilla line commands are deliberately allowed to finish on their origin so
the stock callback receives a real local line revision. `CreateLine` therefore
creates the local line before its ordered commit has assigned a canonical id.
The following `UpdateLine` captures were previously normalized immediately;
their local target could only be classified as an ambiguous pre-existing line,
which converted the already-applied native mutation into the correct but fatal
`origin-applied-capture-rejected` residue fault.

Raw `operation.capture` envelopes now enter the same bounded physical FIFO
before normalization whenever an earlier physical order, consensus barrier, or
queued action exists. Each capture is normalized only at the head of the queue,
after its predecessor has committed and created any required canonical binding.
Each raw origin mutation receives a persisted provisional custody marker, so a
save/reload while it is queued still faults closed instead of silently losing
the machine-local FIFO. Normalization replaces that marker with the ordinary
token-bearing custody record. Queue-overflow behavior remains fail-closed.

The cohesive capture/residue machinery now lives in
`network_origin_capture_runtime.lua`; the architecture budget remains enforced
instead of enlarging the intent coordinator.

## Depot evidence and correction

Depot proposal `mp-094022e94f4ae9c3:player1:30` used
`depot/train_depot_era_a.con`. Although the user placed the depot before drawing
the visible connecting track, Build 35924's placement helper auto-snapped its
generated access edge to canonical node
`node:event:mp-094022e94f4ae9c3:player1:24:5`. The captured transaction therefore
contained one new node and an edge whose other endpoint was an existing `cid`.

The safe `game.interface.buildConstruction` replay API accepts only the named
construction, parameters, and absolute transform. It cannot be told which
canonical track endpoint to reuse. Both helpers appeared to create a depot, but
the generated topology never converged to the same canonical postcondition;
the host reached core digest `7e3f6e98` while the peer retained `404e181f`.

Schema-7 validation now rejects a fresh depot build containing any existing
canonical edge endpoint before native mutation. Lua and Python enforce the same
rule. The user-facing error instructs the owner to place the depot with an
obvious gap from existing track, wait for synchronization, and connect it with
a separate track build. Isolated helper-built depots remain supported and avoid
the persistent stock-UI crash caused by typed depot replay.

Here, “wait for synchronization” means completion of the ordered physical
commit and its two-peer checkpoint—not merely seeing the depot render on both
screens.

## Automated proof

- A runtime regression sends one origin-applied `line.create` plus two immediate
  `line.update` captures. Only create is normalized initially; both updates
  retain FIFO order and persisted custody, normalize after the binding exists,
  release custody in order, and drain without a residue fault.
- Lua proposal tests accept an isolated depot but reject a structurally valid
  depot graph snapped to `node:pre:depot-approach`.
- Python protocol tests independently reject the same portable-wire shape.
- Game-script and network company-mapping integration suites still pass the
  helper-built isolated-depot lifecycle.

## Fresh live gate

Use a fresh session because the captured room is already faulted:

1. Create a line and add both stops quickly through the ordinary Line Manager.
2. Confirm the line appears and the session completes its checkpoint without a
   residue fault.
3. Place a rail depot with a visible gap from every track and wait until the
   multiplayer status is idle/ready.
4. Connect the depot with a separate track build and wait again.
5. Open the depot, buy a train, assign it to the new line, and confirm the train
   appears and moves on both peers.
6. Separately try placing another depot close enough to auto-snap. It must be
   rejected cleanly with the clear-of-track message and must not fault either
   game.
