# Native lobby acceptance — 2026-09-15

## Scope

Local source changes and disposable tests. No release, public relay deployment,
or personal-save edits. Generated worlds have unpredictable tpf2mp_worldgen_lab
names; original New Game/MP saves were not used. No physical clicks, keyboard
paste, fullscreen manipulation or native executable patching.

## Confirmed live results

- runtime/worldgen-configured-17: native Medium 44×44, 1980, seed 7654321,
  hilly, low towns, high industries, Relaxed economy, vanilla crowd, growth off.
  Clean generation, complete native save/metadata/JPG and clean exit.
  Exact request hash and native input observations retained. Console game.config
  is unavailable, so no console-side agent-policy readback is claimed.
- runtime/lobby-native-acceptance/lobby-native-20260915-01: actual TCP bundle
  transfer and two direct native loads of that Medium world. Both authority
  gates/pause pumps ready; shared initialization checkpoint 3; games closed.
- runtime/lobby-relay-native-20, mp-e74abc99e1562b91: real lobby configure,
  Ready and Start → native generation → save-ready → authenticated relay
  bundle transfer → two direct loads → shared checkpoint, PASSED. Small 32×32,
  1850, seed 931581, mountainous, high towns, low industries, Hard economy,
  skeleton crowd, growth off. Both games/session processes cleaned up.
- runtime/lobby-relay-native-22, mp-cf05f70ccd1ddefc: repeated full relay
  generation/transfer/direct-load/checkpoint PASS with Large 56×56, 2000,
  seed 20490123, flat, low towns, medium industries, Easy economy, empty crowd.
  Host checkpoint 3, restoreStatus complete, no fault, both games closed.
  This run includes the disposable native terrain-argument ownership fix.

The relay test uses start_lobby_match.ps1 -PrepareOnly for real generation and
publication, then one pair-harness autosave guard covers both local games.
Normal launches retain the one-game-per-PC guard. This is not a cross-machine
or deployed-relay qualification.

## Defects caught in the development adapter/tests

- Default generator was desert: now explicitly temperate with corrected
  name→index cache. Reordering resource entries alone paired the wrong callback.
- Native ModParams is a nested serialized-Variant table, not an integer map.
  Parameter namespace is !tpf2_mp_1; enabled-mod identity is !tpf2_mp.
- Terrain-widget argument is consumed. Iterating it after the call caused an
  invalid read/Out of memory failure in disposable run 16. Observe before
  transfer and pass a disposable placement-constructed copy, avoiding both
  reuse of a destroyed global object and a second automatic destructor.
- Windows venv Python redirects to its base executable. Readiness now identifies
  the actual runtime rather than rejecting it for differing from Scripts/python.
- The pair test assumed client status contained host checkpoint fields. It now
  checks host consensus and the client's synchronized commit cursor.
- First PowerShell 5.1 Utility autoload inside a function could hide Get-FileHash
  outside that scope. Worker imports Utility globally.
- Large maps are 56×56 tiles on this build. Run 21 correctly generated that
  size, but a mistaken 64×64 verifier expectation rejected it before transfer.
  The verifier now uses the observed native size table; run 22 passed.
- The broad offline gate exposed a pre-existing retry-archive test fixture
  exceeding Windows PowerShell 5.1 MAX_PATH. The archived files existed, but
  Test-Path rejected their 267/268-character paths. Shortened only the fixture
  directory label, preserving every archive assertion; standalone and full
  reruns passed.

## Final offline verification

- Full tools/run_tests.ps1 gate PASSED, including 421 Python tests, Lua and
  PowerShell gates, and cross-language checkpoint/model replay (1,024 events).
  Evidence: runtime/lobby-full-gate-20260915-02.log.
- Local relay suite: 43 tests passed; real HTTP lobby loopback passed.
- Native build and CTest: 3/3 passed, including unsupported-process rejection.
- Host/join lobby and launcher construction smoke tests passed. No claim of
  full visual/click coverage.
- Final process check found no TransportFever2 processes. Personal saves were
  not used; all disposable live game instances were closed.

## Limits

The dialog has construction/smoke tests, not full visual/click testing.
See docs/LOBBY_DEVELOPMENT.md for fixed generator settings and Workshop limits.
Public relay needs its matching lobby backend deployed. Release and a two-PC
lobby test remain separate next steps. Gameplay construction/economy/ordering
rules were not changed. Direct load retains all existing authority gates.
