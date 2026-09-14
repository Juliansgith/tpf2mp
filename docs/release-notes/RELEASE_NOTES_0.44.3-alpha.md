# TPF2MP 0.44.3-alpha

Construction-capture overhead reduction and save-browser diagnostics. This
remains an experimental two-player testing release.

## Changes

- Remove 21 redundant memory-range checks per captured track/road edge and
  six per node. Validate the entire vector, then decode bounded local records.
  Added and removed topology share this optimization. Pointer bounds, unreadable
  and guard-page rejection, finite geometry checks and ownership rules remain.
- Reduce performance-monitor overhead with a 128-sample circular buffer and
  one sort for both reported percentiles. Sampling cadence is unchanged.
- Inspect nearby save metadata before opening the native Load Game browser.
  Produce a bounded, advisory report without executing Lua, moving saves or
  attempting repairs. Unsupported mod metadata is not automatically corruption.

## Verification and limits

- Windows native regression tests cover page boundaries, protected pages,
  invalid vector layouts, NaN geometry and 16,384-edge captures. The production
  MSVC build, DLL fail-closed load test and all 19 pinned signatures passed.
- Full automated gate passed: 164 core Lua tests, 402 Python tests and the
  1,024-event cross-language replay, including performance-window and save checks.
- No new live two-player construction qualification or reliable FPS/build-latency
  measurement accompanies this patch. Fewer checks are not a promised FPS gain.
- This optimization affects multiplayer capture, not ordinary single-player
  construction. Experimental render-worker binary patches, registry changes,
  downloaded tools and benchmark artifacts are not installed by this release.
- Earlier construction/transport coverage gaps and host-snapshot recovery limits
  remain; see [0.44.2 notes](RELEASE_NOTES_0.44.2-alpha.md).

## Update

Back up your saves, close active sessions and update both players to
**0.44.3-alpha** before starting a new session. Windows x64, Build 35924 and two
trusted players remain required. Protocol/state schema versions are unchanged.
Report bugs in #bugs-logs with the session support ID and what you were doing.
