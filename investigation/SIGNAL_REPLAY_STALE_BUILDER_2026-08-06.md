# Signal replay stale-builder failure — 2026-08-06

## Outcome

The populated localhost session `modal-pause-protection-20260806-1416`
reproduced an origin-only Transport Fever 2 internal error after several rapid
signal edits. The canonical transaction was valid and the native replay itself
applied on both processes. The failure occurred afterward: Player 1's still-open
`streetTerminalBuilder` emitted a new signal ghost backed by an edge that the
delayed canonical replay had just replaced. Projecting that stale proposal
userdata from `guiHandleEvent` entered Build 35924's internal-error path.

The host correctly failed closed with
`proposal-completion-timeout:player1`; it paused the session and admitted no
later gameplay work. The affected run is not resumable because consensus did
not receive Player 1's completion before the fault deadline.

Source now quarantines all builder previews from the instant a canonical
BuildProposal is issued until its `proposal.result` crosses back into engine
state. The quarantine never reads the event payload. A second click during the
short interval returns a visible “previous multiplayer build is still
synchronising” error instead of creating unsafe overlapping work.

## Exact live evidence

- Game: Transport Fever 2 Build 35924, Windows x64.
- Executable SHA-256:
  `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`.
- Player 1 PID: `36024`; Player 2 PID: `45868`.
- Last agreed checkpoint: commit `260`.
- Prepare/build commits: `262` / `263`.
- Proposal ID:
  `modal-pause-protection-20260806-1416:player1:263`.
- Proposal digest: `285ef22a`; quoted cost: `16,000`.
- Captured bundle:
  `runtime/manual-network-evidence/modal-pause-protection-20260806-1416-20260806-150142`.
- Audit replay: valid; nine physically complete proposals and this one faulted
  proposal.

The schema-5 transaction replaced private catenary track edge
`edge:event:modal-pause-protection-20260806-1416:player1:251:1` and removed its
signal object
`edge_object:event:modal-pause-protection-20260806-1416:player1:251:1`.
It retained the same canonical endpoints and created one replacement edge.

Player 2 returned a successful physical completion:

- core digest `4ad0abe5`;
- result digest `73535429`;
- finance delta `-16000`;
- output `edge:event:modal-pause-protection-20260806-1416:player1:263:1`.

Player 1's native status independently records the ordered BuildProposal apply
as successful (`localSequence=196406`, tag 15). It then records another
GUI-thread signal-builder proposal (`localSequence=196451`). At 14:43:21 the
game wrote minidump `7809e266-b530-41c8-b285-0780afe6aae4.dmp`; its crashtrace
identifies:

```text
tpf2_mp.lua - game/res/config/gameScript/tpf2_mp.lua_guiHandleEvent()
id = "streetTerminalBuilder", name = "builder.proposalCreate"
```

Player 1 stopped producing GUI outbox records at local sequence `2671`, tick
`22931`, so its already-scheduled post-build wallet sampling never emitted the
physical completion. Player 2 continued normally. The companion eventually
raised the missing-player completion fault rather than guessing that the two
native worlds matched.

## Why only the origin failed

The remote peer had no active signal placement tool. It materialised the same
canonical proposal, applied it, sampled the wallet, and returned completion.
The origin had suppressed the player's immediate native click, waited for
prepare/order consensus, and replayed the command later while the original
signal tool remained active. That timing creates a UI lifetime not present in
ordinary single-player play: the live ghost can retain a reference to the old
edge across its delayed replacement.

The queued-action FIFO was not the corrupting mechanism. The final transaction
referenced an edge that still existed and the native hook confirms that it
applied. The bug was dereferencing a post-replay ghost during result settlement.

## Implementation

`gui_replay_quarantine.lua` owns the machine-local lifetime:

1. arm before `api.cmd.sendCommand(BuildProposal)`;
2. keep the guard through native callback and delayed wallet samples;
3. ignore `builder.proposalCreate` without touching `param`;
4. reject `builder.apply` visibly while guarded;
5. release only after `proposal.result` is sent to engine state;
6. reset the local guard on GUI initialisation.

`gui_state.lua` exposes counters for quarantined previews and rejected clicks,
and the multiplayer panel shows them beside the existing build-bridge metrics.
The main event runtime remains within its 1,450-line architecture budget by
delegating the policy to the focused module.

## Automated proof

The GUI test constructs an in-flight canonical replay, then passes a poison
proposal object whose index and iteration hooks throw. It proves that:

- the replay arms the quarantine;
- a `streetTerminalBuilder` preview is ignored without one payload read;
- a click is rejected with the synchronisation message;
- no capture leaks into the ordinary action queue;
- the guard releases at the engine-result boundary.

The complete combined local suite passes:

- source/architecture boundaries (`tpf2_mp.lua` is 3,388/3,400 lines);
- 65/65 Lua model/runtime checks, including the poison-payload quarantine;
- 73 cross-language economy parity scenarios;
- game-script, network-company, hot-seat, GUI, native fixture, launcher,
  tooling, and deterministic replay tests;
- 75/75 Python companion tests;
- the 5-event engine checkpoint replay and all 104 events in the long replay
  trace, with matching final model digests;
- `git diff --check`.

## Required fresh-session regression

This source fix cannot repair the already-faulted live process. In a fresh
two-process session:

1. build one catenary track segment;
2. keep the signal tool selected and place several signals in quick succession;
3. remove or replace a signal-bearing segment while its ghost remains active;
4. deliberately click once more during the replay-settlement interval;
5. verify either a normal placement after settlement or the short explicit
   synchronisation rejection, with no internal-error dialog;
6. verify matching post-build checkpoint/core digests on both peers.

The expected diagnostic is `proposal-replay-preview-quarantined`; any new
minidump, missing completion, or digest mismatch is a failed regression.
