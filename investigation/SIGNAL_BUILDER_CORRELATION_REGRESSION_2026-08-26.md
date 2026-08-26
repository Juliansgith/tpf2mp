# Signal/waypoint builder correlation regression

Date: 2026-08-26 (Europe/Amsterdam)

Status: fixed and fully offline-tested after live relay discovery; fresh
two-computer release proof remains required.

## Live evidence

In relay session `mp-2190a9e01aa42d23`, opening and moving the vanilla signal
tool produced `TPF2MP: stale build-tool preview rejected`. The local game log
showed a preview-frame storm rather than a genuinely old click: consecutive
correlations were rejected with `builder source and proposal action family do
not agree` before any proposal could enter consensus. The companion remained
connected, synchronized, and healthy.

The active local installation was `0.40.9-alpha`; the defect is also present in
`0.40.8-alpha` because it originated in the `0.40.7-alpha` semantic-correlation
hardening.

## Cause

Transport Fever 2 Build 35924 reports the vanilla signal/waypoint tool under
the live GUI source id `streetTerminalBuilder`. Its proposal is correctly
classified as an `edge-object` change. The source guard matched the word
`terminal` before the word `street` and required a `construction` proposal,
therefore rejecting every valid signal ghost as if it came from a stale station
tool.

## Repair

`streetTerminalBuilder` is now treated as the one live-proven dual-use terminal
builder: it may carry either a construction proposal or an edge-object proposal.
Other station, construction, depot, and asset builders remain construction-only,
so the semantic anti-reordering guard is not generally weakened.

Unit coverage proves the exact source/family pair and rejects an edge-object
payload from `constructionBuilder`. GUI integration coverage sends a network
signal preview through the real event runtime and requires that it is admitted.
The complete repository suite passes: 140 Lua tests, 7 transport-network tests,
3 alpha-readiness tests, all cross-language parity/stress vectors, and the full
network/company integration scenarios.

## Fresh live acceptance

1. Place a signal from each peer and confirm it appears on both worlds.
2. Place two signals in succession on the same track.
3. Place and remove a waypoint.
4. Confirm a player cannot modify a rival private signal/track.
5. Confirm no `stale build-tool preview rejected` message or correlation-reject
   storm appears and the next checkpoint converges.
