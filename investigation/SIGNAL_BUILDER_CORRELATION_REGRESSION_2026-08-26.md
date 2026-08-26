# Signal/waypoint builder correlation regression

Date: 2026-08-26 (Europe/Amsterdam)

Status: corrected twice and fully offline-tested after live relay discovery;
fresh `0.41.1-alpha` two-computer proof remains required.

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
the live GUI source id `streetTerminalBuilder`. Its simplest projected shape is
an `edge-object` change. The source guard matched the word `terminal` before the
word `street` and required a `construction` proposal, therefore rejecting every
valid signal ghost as if it came from a stale station tool.

The first `0.41.0-alpha` repair covered that simple shape, but the synthetic GUI
regression only checked the event's nil return contract. In fresh relay session
`mp-fe91932968bf9db3`, the real carrier-edge rewrite was classified as
`mixed-transport`; 345 captured rejections carried that exact
`streetTerminalBuilder`/`mixed-transport` pair. The original test therefore
proved too little and the release remained broken.

## Repair

`streetTerminalBuilder` is now treated as the one exact live-proven stock
terminal builder that may carry construction, edge-object, or mixed-transport
proposals. Other terminal, station, construction, depot, and asset builders
remain construction-only, so the semantic anti-reordering guard is not
generally weakened.

Unit coverage proves both observed source/family pairs and rejects a mixed
payload from another terminal builder. GUI integration coverage now sends the
live mixed-topology shape through the real event runtime and requires a nonzero
native correlation token; this fails on the `0.41.0-alpha` implementation.

## Fresh live acceptance

1. Place a signal from each peer and confirm it appears on both worlds.
2. Place two signals in succession on the same track.
3. Place and remove a waypoint.
4. Confirm a player cannot modify a rival private signal/track.
5. Confirm no `stale build-tool preview rejected` message or correlation-reject
   storm appears and the next checkpoint converges.
