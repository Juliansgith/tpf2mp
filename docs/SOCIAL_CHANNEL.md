# Social channel: chat, pings and build previews

The social channel carries player-to-player messages that never touch the
authoritative match: chat lines, canned pings, and the live outline of a
build the other player is still planning. It is advisory only. Nothing on it
enters an intent, a commit, an event record, a checkpoint digest or the
audit replay. Losing or reordering a social message can never fault a
session.

## Why a side channel

The ordered path (`intent` -> host commit -> `game_inbox`) serialises one
intent per peer and derives the checkpoint convergence key from the inbox
sequence. Chat or a five-hertz preview stream on that path would stall
construction and perturb convergence. The social channel therefore bypasses
the numbered outbox and inbox entirely and lives in two small files under the
per-peer bridge root, which the GUI Lua state and the companion exchange.

## Files

Both files live in `<bridge root>/companion_state/` next to
`companion_status.json`. Writers replace them atomically (write a temporary
file, then rename). Readers ignore a file that fails to parse.

- `social_out.json`: written by this peer's game GUI state, read by this
  peer's companion. Holds the most recent outgoing items.
- `social_in.json`: written by this peer's companion, read by this peer's
  game GUI state. Holds the most recent items received from the other peer.

Shape of both files:

```json
{"schemaVersion": 1, "session": "mp-0123456789abcdef", "peer": "player1",
 "seq": 17, "items": [ ... ]}
```

`seq` increases on every write. `items` is ordered by ascending `id` and
holds at most 32 items in `social_out.json` and 64 in `social_in.json`.

## Items

```json
{"id": 5, "peer": "player1", "channel": "chat", "at": 1789000000,
 "body": {"text": "wait for me"}}
```

- `id`: integer, increases monotonically per origin peer for the life of the
  GUI state. Receivers keep the highest id seen per peer and process only
  higher ids.
- `peer`: the origin peer, `player1` or `player2`.
- `channel`: `chat`, `ping` or `preview`.
- `at`: the sender's wall clock (`os.time()`), integer seconds.
- `body`: channel-specific, exact key set per channel:
  - `chat`: `{"text": <1..240 printable characters>}`.
  - `ping`: `{"kind": "wait"|"ready"|"look"|"pause"}` plus, for `look`
    only, `"x"` and `"y"` world coordinates (finite numbers).
  - `preview`: one of
    - `{"kind": "off"}`;
    - `{"kind": "road"|"rail", "invalid": true|false,
       "curves": [[x0, y0, x1, y1, tx0, ty0, tx1, ty1], ...]}` with 1 to 24
      curves of finite numbers (a cubic Hermite per new segment, XY only);
    - `{"kind": "construction", "invalid": true|false, "file": "<name>.con",
       "x": .., "y": .., "z": .., "transf": [16 finite numbers]}` where
      `file` matches `^[%w_./%-]+%.con$` and is at most 128 characters.

The sender keeps only the latest `preview` item in its ring; a newer preview
replaces the older one (the id still increases). Chat and ping items are kept
until the ring overflows.

## Wire frame

The companions exchange social items as one extra frame kind on the existing
TCP or relay session, outside the commit sequence:

```json
{"kind": "social", "protocol": 1, "session": "mp-...", "peer": "player1",
 "items": [ ... ]}
```

A frame carries at most 32 items and at most 32 KiB of canonical JSON.
Frames failing validation are dropped and counted; they are never fatal.
The host does not re-broadcast: with two peers, every frame has exactly one
recipient.

## Companion behaviour

Each companion loop (host and client) pumps the channel once per poll:

1. read `social_out.json`; forward every item whose id is above the last
   forwarded id for this peer, batching into one frame;
2. on a received `social` frame, validate it, drop items already seen for
   that peer, append the rest to `social_in.json`, trimming to 64 items.

State is in memory only. A companion restart re-forwards the current ring;
receivers deduplicate by `(peer, id)`.

## Game behaviour

The GUI Lua state (`res/scripts/tpf2_mp/gui_social_runtime.lua`) owns both
ends inside the game:

- outgoing: chat text from the panel input, ping buttons, and the preview
  captured from `builder.proposalCreate` while the road, track or
  construction builder is open; publishes at most five times per second and
  only when something changed (unchanged content is re-sent once per second
  as a keepalive by rewriting `seq`);
- incoming: reads `social_in.json` at most five times per second, appends
  chat to the panel, shows pings as notices (a `look` ping also draws a
  marker on the ground for ten seconds), and draws the other player's preview
  as tinted ground ribbons with `game.interface.setZone`, cleared when the
  preview goes `off`, changes, or is older than four seconds.

Previews are ground outlines only. They do not evaluate the remote proposal,
do not show bridges or tunnels in height, and never call `api.cmd`.

## Limits and trust

Both peers are trusted, but every field is still bounded and validated on
both the companion and the game side. Text is limited to printable
characters; file names are charset-checked; coordinates must be finite; no
resource indices or entity ids are ever sent.
