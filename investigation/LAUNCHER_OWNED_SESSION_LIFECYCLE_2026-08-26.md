# Launcher-owned session lifecycle

Date: 2026-08-26 (Europe/Amsterdam)

## Incident

After a previous match `mp-7d2bdc91f0283d40` was visually closed, a fresh
Host launch found TCP 29742 still owned by companion PID 39388. A second room
could select a free gameplay/save pair, but the machine-wide native-autosave
guard still correctly identified exact Transport Fever 2 PID 38560 as its live
owner and refused to transfer the lease.

This was not stale JSON. The old game and companion were still running. The
launcher had historically started the game, companion, relay tunnel,
diagnostics, and watchers as detached processes, while its FormClosed handler
removed only a temporary invite file. Successful launch returned without a
parent that owned their joint lifetime. The Stop button also stopped only the
companion by default and deliberately left the game open.

## Correction

GUI Host/Join now passes the launcher's exact PID, executable, and UTC process
start time into the launch chain. Once the exact game exists, a hidden
supervisor binds those launcher facts to the game's equivalent identity and the
session/peer state.

- Exact game exit calls the normal session stop path and reclaims every
  detached helper.
- Exact launcher exit calls that path with game closure enabled.
- Relay launch defers supervisor creation until relay and diagnostic PIDs are
  durable in session state, so teardown cannot miss late helpers.
- Stop waits for the exact game, bounds a stuck autosave watcher, and restores
  the original autosave setting only when the global lease still names this
  session and peer.
- A new GUI launch may replace an existing owner found on its host port or in
  the active autosave lease. It invokes the same verified stop path. Missing
  state, reused PIDs, different executable/start time, or a non-TPF2MP command
  line are refused rather than guessed.

The launcher subtitle states the resulting UX contract: keep it open while
playing; closing it cleanly ends that game and session.

## Faulted-session and failed-launch follow-up

A later update attempt found no Transport Fever 2 process but was still
blocked by two `relay-diagnostics` processes from failed Join launches for
`mp-581f1d52a380d7fb`. Both used the same exact installed companion and relay
credential. Their launch worker and PyInstaller supervisor had exited, but the
re-parented service children remained. The partial session had failed before
the diagnostic PIDs and relay fields were durably added to session state, so
the normal recorded-PID teardown could not find them.

A second lifecycle hole existed for successfully launched faulted matches:
the watcher treated launcher state `failed` as already terminal and exited.
That state is intentionally recoverable while the game remains open. If the
user later closed the game, no watcher remained to reclaim its helpers.

The correction is credential-scoped and fail-closed:

- relay diagnostic/tunnel shutdown now repeatedly discovers every process
  matching the exact companion executable, exact command, and exact credential
  path, stops supervisors before children, and rescans through the PyInstaller
  handoff window;
- the same sweep is used by failed-launch cleanup and explicit session stop,
  so an unpublished or stale PID cannot strand a matching child;
- lifecycle watchers remain active through recoverable `failed` state and run
  normal teardown when the exact game or owning launcher later exits;
- unrelated executables, relay commands, and credential paths are never
  touched.

## Automated evidence

`tests/run_session_lifecycle_tests.ps1` starts disposable PowerShell processes
as the game and launcher and independently proves:

1. launcher death produces `launcher-process-ended`, requests game closure,
   and reaches a `cleaned` lifecycle receipt;
2. game death produces `game-process-ended` without asking to kill it again;
3. an exact active old autosave lease is replaced under its recorded old
   session/peer and receives `replaced-by-<new-session>/<peer>`; and
4. a faulted session remains watched until its exact game exits; and
5. the production stop script terminates a verified companion and publishes a
   terminal state with the supplied reason.

`tests/run_relay_diagnostic_process_tests.ps1` additionally starts two
diagnostic processes with one exact credential and proves that stopping one
handle discovers and removes both, including unrecorded children. Invalid
startup status still fails closed without leaving its reporter alive.

The complete repository suite then passed, including autosave crash recovery,
relay port remapping/diagnostic handoff, launcher boundaries, release manifests,
transactional update/install, restore handoff, and all Python, Lua, and
PowerShell checks.

## Boundary

This deliberately supports one GUI-owned Transport Fever 2 multiplayer match
per computer. Direct developer launches without a GUI still receive game-exit
cleanup, but have no launcher process to own game closure. The implementation
does not kill an arbitrary listener to make a port available; an unverified
owner remains an explicit error requiring the user to close that process.
