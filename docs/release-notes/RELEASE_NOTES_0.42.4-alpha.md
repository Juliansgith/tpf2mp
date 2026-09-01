# TPF2MP 0.42.4-alpha

This release closes a native idle-peer selector crash during replicated track
construction. Gameplay authority remains state schema 34, checkpoint format 5,
construction proposal format 7, operation format 4, economy model 10, and
native hook 0.19.0.

## Native replay safety

- Every GUI-owned canonical BuildProposal now suspends `mainView` interaction
  before materializing temporary native entities.
- Replay waits one complete GUI update after suspension, preventing the stock
  selector from traversing a partially installed negative entity.
- Selection remains suspended through the native callback and a short bounded
  settle window, then restores independently of the longer finance/result
  quarantine.
- Success, rejection, explicit reset, and result completion all restore the
  prior interaction state.
- Every canonical endpoint referenced by a new edge is revalidated immediately
  before materialization as a live peer-local entity with `BASE_NODE`.

This fixes relay session `mp-00776ff0f75951f1`, where Player 2 stopped in
`UI::CSelector` while temporary track edge `-1` was acquiring its native
components. Player 1 completed the ordered proposal; Player 2 accepted its
commit but crashed before publishing native completion, after which consensus
correctly faulted closed.

## Regression protection

- GUI integration coverage proves the command cannot be created in the
  selector-suspension frame.
- The selector remains fenced across callback settlement and restores while the
  finance quarantine may continue.
- Live canonical attachment nodes pass the last-moment preflight; disappeared
  or component-incomplete nodes reject before native mutation.
- Existing topology demolition, connected-terminal, rejection, ownership,
  economy, recovery, relay, and cross-language replay suites remain green.

## Validation boundary

The exact cursor-dependent `CSelector` race cannot be reproduced in the
Lua-only harness. The complete automated repository suite, architecture/source
budgets, and release install/verify/uninstall gate pass; the next physical gate
is repeated connected track construction while the receiving peer is idle with
its cursor over the world.

Both players must install `0.42.4-alpha`. Mixed versions remain unsupported.
