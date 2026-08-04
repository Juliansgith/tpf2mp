function data()
  return {
    en = {
      TPF2MP_NAME = "TPF2:MP Competitive Prototype",
      TPF2MP_DESCRIPTION = [[
Early vertical slice for live competitive Transport Fever 2.

Included now:
 - deterministic contested-demand economy
 - canonical identity and authoritative event log
 - canonical road/track transaction schema with quoted-cost finance and asynchronous native replay
 - two-phase physical completion consensus with fail-closed timeout/divergence
 - native turn-proxy hot-seat with separate company wallets/assets
 - pre-commit protection against modifying another company's tracked infrastructure
 - exact-build native BuildProposal and consequential-command gates
 - delayed vehicle attribution and turn reconciliation
 - town/industry autonomy controls
 - finance and journal probes
 - file bridge for the external host/client companion
 - replayable state digests, event-shape probes, and research export

This is a research prototype, not finished multiplayer. Tracked road/track edges keep logical company ownership; their native holder is normally the shared turn desk, while depot/station ownership cascades may put attached edges on their rightful company. Rival edits are rejected before commit. The supported canonical road/track slice has bidirectional two-live-game replay, finance, checkpoint, and 600-tick localhost proof. A human two-computer run, station/line/vehicle codecs, autonomous-world replication, and passenger/cargo steering remain explicit go/no-go gates.

Do not remove this mod from an initialized save: company players and asset ownership persist in the save. Reconcile the active turn and keep the mod enabled.
]],
    },
  }
end
