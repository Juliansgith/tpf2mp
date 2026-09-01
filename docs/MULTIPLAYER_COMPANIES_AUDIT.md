# Multiplayer Companies reuse audit

Checked 2026-07-31.

- The referenced Steam Workshop item is [Multiplayer Companies, item 3710243057](https://steamcommunity.com/sharedfiles/filedetails/?id=3710243057), credited there to SwissDev.
- The Workshop page currently marks the item as removed and incompatible with Transport Fever 2.
- The item is not installed in the local Workshop cache.
- No source repository, source archive, or reuse licence was discoverable from the page or a targeted source search.

Conclusion: do not copy, bundle, or depend on that implementation. The prototype's company creation, naming, wallet payout, and ownership transfer were implemented independently against documented Transport Fever 2 scripting APIs. Revisit reuse only if the author provides source and explicit permission.

This closes the immediate licence decision. Native UI company switching is still not assumed because the documented `setPlayer(entity, playerEntity)` API changes entity ownership rather than the UI's active player.

The standalone prototype avoids assuming such a switch. It independently creates two company players and uses the original player as a temporary native UI turn proxy: active assets are leased to it, then returned with the signed turn balance delta. This is documented-API work, not a reconstruction of the unavailable Workshop implementation. Company creation and the empty-world wallet/cycle/payout path passed in Build 35924 on 2026-08-01; real asset types remain subject to the live matrix in `../investigation/LIVE_VALIDATION_CHECKLIST.md`.
