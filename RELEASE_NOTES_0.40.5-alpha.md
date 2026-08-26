# TPF2MP 0.40.5-alpha

This release combines three reliability slices: complete launcher-owned session
cleanup, ordered handling of rapid stock line edits, and a narrowly proven
in-place recovery path for non-mutating proposal timeouts. It advances the save
state to schema 32; checkpoint format 5, the relay wire protocol, and native
hook 0.19.0 remain unchanged.

## Recover a safely rejected timeout

- Real native construction-step progress now renews the ordinary proposal
  deadline, subject to a hard upper bound. Large builds that are still making
  progress no longer fault at the original short deadline.
- When a proposal does time out, both games may later prove the same empty
  native failure, identical authored core, no finance change, no queued work,
  and no origin-applied residue.
- The Multiplayer panel then reports **READY** and enables
  **Recover / Resync Session**. Recovery is an ordered action followed by a
  mandatory fresh all-peer structural/world-manifest checkpoint.
- The fault clears only after that checkpoint converges. The session remains
  paused; resume deliberately and retry the rejected player action manually.
- Different peer results, any mutation or residue, missing evidence, later
  unsafe work, operation/checkpoint faults, and structural disagreement remain
  restore-only. There is no unsafe "clear fault" switch.
- The complete proof remains in the authority log and survives companion
  restart and independent replay.

## Rapid line edits and safe depot capture

- Stock Line Manager sequences such as Create Line followed immediately by
  multiple Add Station/Update Line commands now retain raw origin captures in
  the bounded physical FIFO. Each command is normalized only after the prior
  commit has established its canonical line binding.
- Persisted provisional custody makes a queued, already-applied native edit
  fail closed across save/load instead of becoming invisible residue.
- Build 35924 can silently snap a newly placed depot's generated access edge to
  an existing canonical track node. The public construction helper cannot
  reproduce that hidden endpoint deterministically, so this shape is rejected
  before mutation with a clear message. Place a depot with a visible gap, wait
  for synchronization, and connect it using a separate track build.

## Complete lifecycle ownership

- Every GUI launch records the launcher and game's exact PID, executable, and
  process start time and starts a hidden lifecycle supervisor.
- Closing Transport Fever 2 tears down that session's companion, relay tunnel,
  diagnostics, menu/recovery helpers, bridge profile, and autosave guard.
- Closing the launcher performs the same teardown and also closes its exact
  game. **Stop session** now ends the complete verified process group.
- A new Host/Join launch may reclaim a prior TPF2MP port or autosave owner only
  after its session state and exact process identity verify. Unknown or
  mismatched processes are never terminated.
- Autosave settings are restored synchronously after the exact game exits, and
  a verified stuck guard watcher is bounded and cleaned.

## Compatibility and verification

- Both players must install `0.40.5-alpha`; mixed versions are unsupported.
- Schema-31 saves migrate through the existing state migration path, but use a
  fresh disposable match for the first recovery/depot acceptance run.
- The complete automated suite passes: 171 packaged Lua files, 74 PowerShell
  files, 201 Python tests, cross-language parity and 1,024-event replay,
  launcher/relay/session lifecycle checks, and transactional install/update
  verification.
- The new recovery path is automated and audit-replay proven but still needs
  its first deliberate two-computer live timeout/requalification test.

Keep the launcher open while playing; closing it is intentionally equivalent
to **Stop session**.
