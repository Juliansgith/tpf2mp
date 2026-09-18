# TPF2MP 0.45.5-alpha

Chat, pings and live build previews between the two players, a panel that
tells you what to do next, and a launcher that walks you through a match.
The native hook gains a preview renderer; protocol and state schemas are
unchanged. This remains an experimental two-player testing release.

## Changes

- Social channel (see `docs/SOCIAL_CHANNEL.md`): an advisory frame beside
  the commit stream carries chat lines, four canned pings (Wait, Ready, Look
  here, Pause please) and the other player's planned build. Nothing on it
  enters an intent, a commit, a checkpoint digest or the audit replay.
- Build previews: while one player drags a road, track or building, the
  other sees it at once. With the native hook the preview is drawn by the
  game's own builder renderer, so it looks like a local ghost, terrain shaping
  included, and turns red when the game marks it invalid. Without the hook a
  tinted ground outline is drawn instead. The preview never reserves land,
  costs money or enters the match. `TPF2MP_NATIVE_PREVIEW=off` disables the
  native renderer; its state is reported under `hooks.preview` in the native
  status file. The renderer is a port of silver2127's MIT tpf2-multiplayer
  preview plugin (see the third-party notices).
- In-game panel: a next-action line under the badges, a Notices feed with a
  short-lived pop-up for rejections, pings and chat with plain-English
  reasons, collapsible sections with a Compact mode remembered per player,
  developer sections hidden unless the developer flag is set, a Scoreboard
  with an end-of-match summary, and a Chat and pings section with a text
  field. A "Look here" ping marks the ground under your cursor on the other
  player's map for ten seconds.
- Launcher: a live four-step checklist, invite links
  (`tpf2mp://join?code=...`) that open the launcher with the join prepared
  (a per-user protocol handler is registered on install and removed on
  uninstall, no admin rights), a "Copy invite link" button, a recent-matches
  list with "Resume last match", and a pre-launch comparison of active mods
  against the host's when an invite link carries the host's digest.
- Native hook: the preview renderer adds seven prologue-verified detours
  around the builder renderer factory, scene, proposal conversion and height
  modification. Every pinned region is byte-checked before anything is
  hooked; a mismatch leaves previews off and the rest of the hook arms as
  before. The hook now uses only Windows locks in injected code because the
  game ships the 2017 C++ runtime, and the source gate refuses `<mutex>`
  under the hook.

## Verification and limits

- Full automated gate passed (core Lua suites, 451 Python tests including the
  social channel, the 1,024-event cross-language replay), plus the
  documentation, source-boundary, launcher, lobby, entrypoint and install
  transaction suites. CTest covers the preview renderer's request state
  machine, proposal limits, palette policy and terrain composition against
  the pinned executable.
- Live on two instances: chat, pings and injected previews rendered on both
  peers; the scripted track-build suite converged with the native renderer on,
  and Player 2's own window showed Player 1's track ghost at the build site
  while the drag was still in progress and before the build was paid for.
- Only track previews were exercised live. Road and construction previews
  use the same code paths and the ported limits but are untested in-game.
  Junction fidelity follows the prior art: the preview shows the new segments
  only, not how they join existing track.
- The pop-up notice window and the "Look here" ground marker were verified by
  unit tests and log evidence, not by screenshot.
- No new live two-player construction or transport qualification accompanies
  this release. Earlier coverage gaps, the intermittent native Load Game stall
  and the lobby's two-computer path remain as in the
  [0.45.4 notes](RELEASE_NOTES_0.45.4-alpha.md).

## Update

Back up your saves, close active sessions and update both players to
**0.45.5-alpha** before starting a new session. Reinstall from the bundle
(not only the mod folder) so the invite-link handler is registered. Windows
x64, Build 35924 and two trusted players remain required. Protocol/state
schema versions are unchanged. Report bugs in #bugs-logs with the session
support ID and what you were doing.
