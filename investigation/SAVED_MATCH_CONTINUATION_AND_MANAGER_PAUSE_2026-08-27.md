# Saved-match continuation and manager pause capture

Date: 2026-08-27  
Observed release: `0.41.3-alpha`, state schema `33`.  
Implementation state: `0.41.4-alpha`, state schema `34`.

## Live evidence

Relay session `mp-1e828bfc275b79a6` loaded a save from an earlier multiplayer
match. Four train assignments completed and were checkpointed; the relevant
ordered commits were sequences 70, 74, 77, and 80, followed by one coalesced
line-registration refresh. The deferred FIFO neither overflowed nor
livelocked.

The visible pause was not four assignment barriers. The stock line/vehicle
manager selected speed zero at sequence 57, the shared pause became effective
at sequence 58, and speed two was restored at sequences 84/85. The effective
pause lasted about 48.3 seconds while the player used the manager and the
ordered assignment tail drained.

The same run exposed a separate continuation defect. `0.41.3-alpha` discarded
the saved authoritative state when the launcher's new relay session ID did not
equal the session ID embedded in the save. It rebuilt both canonical accounts
at the configured $50 million starting balance and left inherited line
identity outside the new manifest. A later inherited-line edit therefore
raised the local origin residue fault
`origin-applied-capture-rejected:selected pre-existing object is ambiguous
across peers`.

That old live session is useful as soak evidence, but it is not a valid source
for proving continuation: its ledger was already reset before this correction
existed.

## Exact saved-match continuation

State schema 34 adds `recovery.continue`. A launcher-managed host now marks a
prior initialized network save for continuation and supplies both peers with
the exact starting-save/content fingerprint. The games retain the saved:

- canonical company balances, loans, history, and economy state;
- logical ownership and canonical object maps;
- line, station-group, and vehicle bindings; and
- registered services and presentation/economy ledgers.

Only session-local sequencer, checkpoint, clock-rendezvous, and in-flight
transport state is reset. The host and joiner attest industry content, compare
the migrated saved core, order `recovery.continue`, and must complete a new
two-peer checkpoint before gameplay is released.

Continuation fails closed if the save is faulted, dirty, contains an in-flight
operation/checkpoint, retains origin residue, has a different fingerprint, or
does not converge. A fresh ordinary Transport Fever 2 save still takes the
normal `match.initialise` path and receives starting cash exactly once.

The regression fixture preserves a non-default balance plus manifest-bound
line, station-group, and vehicle identities independently on host and join.

## Scoped manager hold

The GUI clock capture policy now recognizes the stock line manager, vehicle
manager, and depot-manager modal transition. Only the speed-zero event emitted
within the narrow 12-frame modal-open window is treated as UI mechanics.
Explicit speed controls and a visible Escape menu remain real shared pause
requests.

The first line/vehicle operation in a running game creates one shared safety
hold. That hold spans the whole local physical FIFO, generated follow-ups, and
checkpoint tail, then restores the prior shared speed once. A real clock
request by either player cancels automatic resume. This prevents rapid
multi-select assignment from repeatedly pausing and resuming between trains
without weakening the operation consensus boundary.

## Fault propagation correction

The live origin-residue fault was initially visible only in Player 1's game
health. Companion health processing now promotes a peer-local `faultCode` to
one durable ordered `network.sync_fault` after that peer has consumed the
current ordered tail. The other peer can no longer keep running or save an
apparently healthy world after one game has entered origin residue.

## Automated proof

- Lua game/runtime suites cover strict continuation admission, state
  preservation, startup fencing, manager-pause classification, batched hold,
  explicit-pause cancellation, and retry.
- Python companion tests cover host/join continuation ordering, fingerprint
  and core mismatch refusal, clean/faulted boundaries, and peer-local fault
  promotion without duplicate durable faults.
- Cross-language schema validation accepts only the exact continuation action.
- The complete source, parity, integration, launcher, relay, updater,
  packaging, syntax, and replay gates pass with state schema 34.

## Next live gate

Create a clean match in `0.41.4-alpha`, alter both companies' balances, build
and bind at least one line and vehicle, save normally, exit both games, then
host that exact save under a new relay room. Verify that both balances and all
manager identities survive before assigning four vehicles together. The old
`0.41.3-alpha` session cannot retroactively recover the ledger it discarded.
