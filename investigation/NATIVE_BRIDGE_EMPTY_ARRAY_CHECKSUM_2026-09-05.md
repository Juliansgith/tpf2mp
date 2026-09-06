# Native bridge empty-array checksum regression (2026-09-05)

## Live incident

Session `localhost-depot-collateral-user-20260905-fix4` first converged a
compound road-depot build on both peers. The depot graph, ownership, company-2
finance delta, and checkpoint boundary 11 all agreed. A later Player-2
`vehicle.buy` was captured and ordered but never reached either game.

The first missing game acknowledgement was not the purchase. Automatic
recovery emitted control sequence 20, a `network.checkpoint_request` whose
`vehiclePhaseProof.vehicleRounds` value was the JSON empty array `[]`. Both
Lua games remained at commit 19 while the companions advanced through later
durable records. The pending purchase at sequence 22 consequently timed out.

## Root cause

Lua tables do not intrinsically distinguish an empty JSON array from an empty
JSON object. `json.decode` preserved that distinction with a private weak
identity marker, but `bridge.verify` deep-copied the decoded message before
hashing it. The copy lost the marker, so the Python-authored `[]` was hashed by
Lua as `{}`. For the live sequence 20 the signed checksum was `35c49f57` and
the old Lua verifier calculated `4d649f97`.

The native asynchronous bridge transports opaque bytes. Its take operation
removed sequence 20 before Lua authentication. Once Lua rejected it without
advancing `nextInSeq`, subsequent native takes destructively exposed sequences
21 onward as unexpected records. That made a single checksum mismatch look
like a later operation deadlock.

## Repair

- Empty arrays decoded by `json.lua` retain their wire identity while alive.
- `bridge.verify` now excludes the top-level checksum with a shallow copy, so
  every nested decoded identity remains intact during read-only hashing.
- Any invalid or out-of-sequence native inbox record leaves the Lua cursor
  unchanged and deactivates that transport generation. The next poll
  reconfigures the process-owned FIFO at the same durable sequence before it
  may consume later ordered work.
- Native bridge diagnostics now expose the Lua cursor, rewind count, last
  rejected sequence, and local error in the public performance snapshot.

## Proof boundary

- The exact cross-language empty-array envelope is a pinned Lua regression
  vector.
- A mocked destructive native delivery proves rejection, cursor retention,
  reconfiguration, and successful redelivery.
- The native C++ test proves a taken durable inbox record is readable again
  after configuring the unchanged input sequence.
- Lua tests pass 162/162, the full repository gate passes, the Release native
  build and CTest pass 2/2, and documentation/source-boundary checks pass.

Two attempted follow-up engine runs did not reach their pinned world because
Windows refused the harness foreground handoff and the background Load Game
click did not expose the save selector. Both attempts were terminated at the
pre-authority boundary. They neither contradict nor count as live gameplay
proof; the next fresh interactive pair should exercise recovery followed by a
purchase again.
