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
 - ordered physical town development
 - shared clock and per-station train rendezvous
 - exact synchronized model passenger queues and train loads in the TPF2MP HUD
 - finance and journal probes
 - file bridge for the external host/client companion
 - replayable state digests, event-shape probes, and research export

This is a research prototype, not finished multiplayer. Tracked road/track edges keep logical company ownership; their native holder is normally the shared turn desk, while depot/station ownership cascades may put attached edges on their rightful company. Rival edits are rejected before commit. The supported canonical construction, line, train-purchase/assignment, clock, station-rendezvous, finance, checkpoint, town-development, and passenger-display slices have two-process localhost proof at differing levels. A human two-computer run, broader vehicle controls/topology/mod callbacks, industry/cargo authority, disconnect recovery, and product hardening remain explicit gates. Native people are bounded scenery; the TPF2MP passenger HUD is authoritative.

Do not remove this mod from an initialized save: company players and asset ownership persist in the save. Reconcile the active turn and keep the mod enabled.
]],
    },
  }
end
