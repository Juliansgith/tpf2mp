# TPF2MP 0.44.1-alpha

Focused road-depot junction fix. This remains an experimental testing release.

## Fixed

- Placing a road depot on an existing public road node could leave a partial
  depot and safety-fault both peers. The repair tried to create an invalid
  approximately 0.585 m connector. The full affected road junction is now
  captured and authorized before any native construction is applied, and the
  depot entrance becomes the junction without that extra connector.
- Preserve the depot's position, parameters and cost, plus public-road
  ownership, resource names, tangents, bus lanes and tram features. Existing
  one-branch road endpoints use the same normalization.
- Reject incomplete, mixed rail/road, object-attached or construction-frozen
  junction neighborhoods before creating a depot. Unsupported topology is not
  allowed to bypass ownership checks or partially mutate the world.

The earlier successful road-depot tests split the middle of a road segment;
they did not cover snapping to an already-existing node. This patch adds that
missing case, not a claim that every construction variant is now supported.

## Verification and limits

- The fixed existing-node placement passed twice through real stock widgets
  in two local game instances. Both physical worlds agreed on geometry,
  ownership, the single buyer debit and all three checkpoint barriers. The
  final candidate included the frozen-infrastructure guard.
- A repeatable UI recipe now checks exact topology changes; a detached depot
  or an extra connector cannot pass. Added Lua regressions cover the original
  geometry, deterministic ordering, idempotence, road features and safe
  rejection paths. The offline gate passed 368 Python tests, Lua/native/
  PowerShell checks and the 1,024-event cross-language replay.
- Broader bus and tram reruns were blocked by the separate native Load Game
  hang before gameplay. They are not passes, and that hang is not fixed here.
- These targeted development runs are source-bound evidence, not a complete
  physical-UI qualification of the final versioned package. Combined building
  demolition/terrain/attachment, all transport variants, arbitrary Workshop
  constructions and save/load/recovery remain incompletely requalified.

See the [dated incident and evidence](https://github.com/Juliansgith/tpf2mp/blob/v0.44.1-alpha/investigation/DEPOT_EXISTING_ROAD_JUNCTION_2026-09-06.md)
and the [inherited 0.44.0 testing limits](https://github.com/Juliansgith/tpf2mp/blob/v0.44.1-alpha/docs/release-notes/RELEASE_NOTES_0.44.0-alpha.md).

## Update

Close the old session, update **both players to 0.44.1-alpha** through the
launcher and create a new session. Windows x64 / Transport Fever 2 Build 35924
and exactly two trusted players remain required. Protocol schemas and native
hook version are unchanged; matching release/content checks still apply.

Back up saves. This does not repair already-faulted worlds or certify every
old save. If a session faults, stop issuing commands and use an available
verified recovery point or a backed-up save. Report the action, player,
approximate time and non-secret `mp-...` session ID in Discord **#bugs-logs**;
never post the secret join code.
