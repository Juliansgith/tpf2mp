# Vanilla line-manager capture on Build 35924

Date: 2026-08-04 (Europe/Amsterdam)  
Implementation: prototype `0.21.2-alpha`, state schema `19`, operation schema `1`, native hook `0.12.0`

## Result

The ordinary Transport Fever 2 line manager now has an authority path for its
five stock command families:

- tag 3 `CreateLine` / **New Line**;
- tag 5 `UpdateLine` / add, remove, reorder, or change a stop/terminal;
- tag 4 `DeleteLine`;
- tag 29 `SetName` / rename;
- tag 28 `SetColor` / color chooser.

In network mode the exact native visitor still rejects the original local
command before mutation. Hook 0.12 first copies its typed payload into bounded
owned memory. GUI Lua consumes that record, replaces every machine-local line
and station-group ID with a canonical identity, and submits the existing
`operation.execute` transaction. Both worlds materialize their own native
command only after host order, report a local-ID-free physical result, and enter
the normal two-peer checkpoint barrier.

This is code-, automated-test-, native-boundary-, and stock-widget-live-proven
across two independent game processes. New Line, rename, color, Delete Line,
Add Station, and the per-stop remove button were exercised through the vanilla
Line Manager and displayed the same result on the peer. The remaining schedule
depth test is two populated stops with reorder and alternate terminals.

## Evidence used to map the payload

An earlier unrestricted native trace under
`%TEMP%\tpf2mp_bridge\operations-20260802-guided50` recorded queued CreateLine,
UpdateLine, and DeleteLine tags from actual line-manager clicks. It also showed
the vanilla sequence: New Line first creates a zero-stop entity; selecting the
first station then issues an UpdateLine containing one stop. Those intermediate
states are real editor states, so requiring two stops was incorrect.

Exact Build 35924 disassembly established these visitor/function anchors:

| Command or helper | RVA | Finding |
|---|---:|---|
| CreateLine visitor thunk | `0x009D5560` | jumps to typed visitor at `0x009D76A0` |
| DeleteLine visitor | `0x009D5570` | target entity begins at command offset zero |
| UpdateLine visitor thunk | `0x009D5600` | jumps to typed visitor at `0x009D9FD0` |
| SetColor visitor thunk | `0x009D5EE0` | typed visitor at `0x009D98A0` |
| SetName visitor thunk | `0x009D5EF0` | typed visitor at `0x009D9C40` |
| Line stop-vector walker | `0x001BB2A0` | advances by `0xA8` bytes per stop |
| Line-stop copy helper | `0x001D8140` | first three int32 values are group/station/terminal |

The pinned layouts are:

| Payload | Offset | Type |
|---|---:|---|
| CreateLine line | `+0x00` | `Line` |
| CreateLine name | `+0x28` | x64 MSVC `std::string` |
| CreateLine color | `+0x48` | three floats |
| CreateLine player | `+0x54` | int32 |
| DeleteLine target | `+0x00` | int32 |
| UpdateLine target | `+0x00` | int32 |
| UpdateLine line | `+0x08` | `Line` |
| SetColor target/value | `+0x00/+0x04` | int32 plus three floats |
| SetName target/value | `+0x00/+0x08` | int32 plus x64 MSVC `std::string` |
| Line stop begin/end/capacity | `+0x00/+0x08/+0x10` | three pointers |
| Stop station group/station/terminal | `+0x00/+0x04/+0x08` | three int32 values in a `0xA8`-byte record |

The hook does not serialize the native pointers. It validates readable memory,
vector ordering/alignment/capacity, at most 256 stops, string length at most 160
bytes, finite color components, non-negative native IDs, and terminal values at
most 4095. A mismatch remains suppressed, increments `invalid`, and is never
converted into gameplay traffic.

## Wire boundary

The same-process native-to-Lua handoff is a compact delimiter envelope:

```text
L1|tag|target|player|r|g|b|hexName|count|group,station,terminal;...
```

It is not the network protocol. Lua parses and bounds it, resolves local IDs,
and creates the existing checksummed canonical operation transaction. Empty Lua
tables are accepted as empty stop arrays only where the zero-stop line state is
valid; non-empty object-shaped tables still fail validation. Neither target IDs
nor station-group IDs cross between machines.

Vanilla clicks can occur while a previous physical result or checkpoint is
pending. The local deferred queue therefore holds 32 physical actions, including
`operation.execute`, in FIFO order. One action is released per completed
physical/checkpoint barrier. Overflow fails visibly instead of dropping or
reordering clicks.

A transport-level validation rejection must also release the origin queue. The
companion now emits a signed, ordered, non-mutating `network.intent_rejected`
control containing the origin peer/sequence and error code. Lua clears only the
matching latch and releases the next deferred action. This closes the deadlock
found by deliberately submitting an invalid intent during the first stock
widget session; the behavior has Python and end-to-end Lua regressions.

## Automated verification

The current suite verifies:

- exact profile/layout constants in the native tests;
- hook 0.12 compilation, fail-closed load, all 17 executable signatures, and
  the 23-entry visitor table against the installed executable;
- deterministic zero-stop CreateLine and one-stop UpdateLine validation and
  materialization in Lua;
- both JSON spellings of an empty Lua stop array in Python;
- GUI decoding of real-shaped CreateLine, two-stop UpdateLine with non-zero
  station/terminal values, DeleteLine, SetName, and SetColor envelopes;
- GUI replay without the engine's userdata-unsafe global `unpack`. Build 35924
  throws a table-valued native exception when `unpack` copies `Line`/`Vec3f`
  arguments, so the replay layer invokes the closed command-factory arities
  explicitly and tests with a deliberately failing `unpack`;
- existing peer/company authorization, physical operation consensus, and
  checkpoint sequencing.

On 2026-08-04, `tools/run_tests.ps1` passed 31/31 Lua tests, all game-script,
network, hot-seat, replay, GUI, launcher, syntax, and 40 Python tests. The native
Release build passed both CTest targets and exact Build 35924 validation.

The focused localhost session
`runtime/localhost-live/line-manager-replay-20260804-1428` then exercised the
same native visitor boundary across two independent game processes:

- CreateLine: host captured/consumed `1/1`, replay calls were host `2` (one
  suppressed original plus one authorized replay) and peer `1`; both peers
  completed with result digest `bf847e84` and core digest `51a46392`;
- UpdateLine: the host captured its own local line ID, the ordered transaction
  targeted canonical line
  `line:event:line-manager-replay-20260804-1428:player1:13:1`, and both local
  replays completed with result digest `19976097`;
- DeleteLine: both local replays completed with result digest `5b095d0b`, and
  the following checkpoints on both peers had zero retained line bindings and
  matching core/canonical digests;
- every native invalid/mismatch counter remained zero, and all three operations
  passed physical consensus plus the subsequent checkpoint barrier.

The lifecycle was then repeated from player 2. Host ordering bound it to
`company:2`; commits 22/25/28 were create/update/delete against canonical line
`line:event:line-manager-replay-20260804-1428:player2:22:1`. Both processes
reported matching result digests `5aff7ef9`, `97e5611e`, and `63bc5d16`, and the
final checkpoints again converged with no retained line. Each process ended
with exactly three suppressed local captures and two authorized replays of each
tag, proving both origin directions without invalid or tag-mismatch events.

## Stock-widget localhost acceptance

Two later sessions exercised the real Line Manager rather than synthesizing
operation payloads:

- `vanilla-lines-final-v12-20260804`, archived under
  `runtime/manual-network-evidence/vanilla-lines-final-v12-20260804-20260804-181812`,
  visually proved New Line, rename to **Northern Connector**, color selection,
  and Delete Line on both processes. Hook 0.12 recorded the expected tags with
  zero invalid records; the audit validated 9 commits, 17 controls, 9
  convergences, and no pending physical/checkpoint work.
- `vanilla-line-stops-v12-20260804`, archived under
  `runtime/manual-network-evidence/vanilla-line-stops-v12-20260804-20260804-183950`,
  first placed a stock station through the normal ordered proposal path. The
  host then activated vanilla `lineEditor.addStation`, clicked Bromborough, and
  used the stop row's vanilla remove button. Both processes recorded exactly
  two queued/applied UpdateLine commands; the origin captured/consumed `2/2`,
  the final stop count was zero on both, and all native invalid/drop/error
  counters remained zero. The audit validated 5 commits, 7 controls, 5
  convergences, one completed physical proposal, and two completed checkpoint
  barriers with nothing pending.

The screenshots `host-after-stock-add-stop.png`,
`client-stock-line-stop.png`, `host-after-stock-remove-stop.png`, and
`client-after-stock-remove-maximized.png` in the second session's
`runtime/localhost-live` directory are the visual receipt. Both disposable
two-instance harnesses ended PASS and archived source/installed fingerprints.

## Remaining focused acceptance

Use the vanilla line manager on both peers, not the mod panel:

1. Place a second disposable station through the synchronized construction path.
2. Add both stations and confirm their order on both processes.
3. Reorder them and select an alternate terminal where the stock UI permits it.
4. Repeat populated edits from player 2 and try a rival edit/delete.
5. Submit two stop edits in quick succession to stress the deferred FIFO.

Expected latency is approximately the existing physical-consensus/checkpoint
round trip. A newly created line may need to be selected manually after it
appears because the locally suppressed CreateLine callback returned failure to
the original editor before the authoritative replay completed.

## Still outside this slice

- Vehicle purchase, consist editing, assignment, replacement, sale, and control
  commands are gated and have partial canonical codecs, but do not yet share a
  complete transparent vanilla capture layer.
- Schedule settings beyond the copied native `Line.Stop` group/station/terminal
  tuple (for example richer load/waiting/waypoint state) need separate mapping
  before they can be claimed. The `0xA8` stop is intentionally not copied as an
  opaque byte blob.
