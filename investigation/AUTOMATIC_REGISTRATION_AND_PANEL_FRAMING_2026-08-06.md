# Automatic line registration and competitive panel framing

Date: 2026-08-06 (Europe/Amsterdam)  
Scope: two usability defects found by playing the prototype rather than
testing it. Neither was a correctness bug; both made the game read like a
research harness.

## Defect 1: the economy did not know about your line until you asked it to

`line.register` was a manual button. A player could build stations, lay
track, create a line, buy a train, and watch it run — with no market, no
share, no revenue, and no board — until they found *Register Selected Line*
in the mod panel. The competitive game was opt-in per line, and nothing in
the interface said so.

### Registration is now a consequence of running a service

Any ordered operation that changes a line's shape or its vehicle set makes
the owning peer re-derive that line's facts:

| Operation | Why it re-derives |
|---|---|
| `line.create` | a new service exists |
| `line.update` | stops changed, so distance, journey, and the market's town pair can all change |
| `vehicle.assign` | vehicle count changed, so headway and capacity change |

`line.delete` already deregisters (round-2 audit fix S1-1).

Trigger points differ by mode for one reason: **facts must be derived from a
world the rival also sees.**

- *Network*: registration fires from the `network.operation_outcome` handler,
  after both peers have agreed on the physical result. Deriving earlier would
  read a world the other peer has not yet reached.
- *Standalone*: there is no consensus outcome, so a completed local operation
  is itself the trigger, injected into the operation runtime as
  `env.autoRegisterLine`.

The owning peer alone derives and carries the facts; every other peer applies
the ordered result, exactly as with a manual registration. Nothing about the
origin-computed/wire-carried invariant changes.

### The authorization hole this forced us to close

`line.register` was in `HOST_AUTHORITY_ACTIONS`, so in network mode **only
the host could ever register a line** — the round-2 audit flagged this
(finding S1-8) as needing a design ruling. Automatic registration decides it:
registration is company-bound, like `proposal.prepare` and
`operation.execute`. `player2` may register for `company:2` and nothing else,
and the embedded service payload must name the same company as the acting
one. It also joins the connected-peers gate, since it is now consensus-bound
traffic rather than a host-side bookkeeping call.

The manual button remains as *Re-check Selected Line* for lines that predate
a match or whose facts a player wants refreshed on demand.

## Defect 2: two simulations presented as one

The panel showed model allocations and native agent counts with equal
billing, leaving the player to work out which was authoritative. They are not
the same simulation and were never going to agree exactly, so the interface
has to say which one is the game.

Changes, all presentation-only:

- The market section is introduced as **the contest**, with the explicit
  note that people on platforms are scenery.
- Markets report in player terms — `600 of 1000 travelling (60%), 400 stayed
  home` — instead of raw demand and outside counts. Induced demand becomes
  visible as a number that moves.
- Each service reports what a player acts on: passengers carried, share now,
  where share is heading, and a `GAINING`/`LOSING`/`holding` trend (2% band),
  plus revenue. The generalized-cost breakdown moves to its own line, phrased
  as *costs the passenger $13.12 = fare + time + wait + transfers + crowding
  − comfort*.
- Native agent counts are demoted below the contest and labelled
  **`Native agents (scenery, not scored)`**.

This is the framing an agents-off world would want too, so none of it is
throwaway work: if the pivot lands, the diagnostics line simply reports
zero.

## Tests

- `tests/test_companion.py`: `line.register` rejects a client acting for a
  rival company, rejects a payload whose service names a different company
  than the action, and accepts a client registering its own line.
- `tests/run_runtime_module_tests.lua`: the rendered panel contains the
  scenery framing, the travelling-versus-stayed-home line, carried
  passengers with a trend, the legible cost breakdown, and the demoted
  native-agent label.
- Full offline suite passes (56 Lua, 69 Python, boundaries, 104-event
  cross-language replay with an unchanged final model digest).

## Live verification owed

- A line created through the vanilla Line Manager appears in the market
  panel with no player action, in both modes.
- Assigning a second train changes headway and capacity without a click.
- A client-created line enters the economy at all (previously impossible).
- `factsSource` on an auto-registered service still reports the computed
  path.
