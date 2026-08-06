# Transport Fever 2 — Live Competitive Multiplayer

**Concept document · working title: TPF2:MP**

---

## What this is

A mod that lets two players build rival transport companies on the same Transport Fever 2 map, at the same time, in real time — and then actually compete for the same passengers and freight.

Not turn-taking. Not two people on separate maps trading resources through a shared file. Both players run their own copy of the game, but both copies consume the same ordered, host-authoritative stream of consequential world events. They build against each other in one logical world, with a shared scoreboard and a structural state — topology, ownership, companies, lines, and vehicles — that both machines continuously verify.

The end state is something close to what Railway Empire offers: you see your rival's track go down, you see them open a line into a town you were about to serve, and you have to respond — undercut them on price, run more frequent service, or go find demand they haven't claimed yet.

---

## Why this doesn't already exist in the game

TPF2 was designed as a solitaire optimisation game, and its economy reflects that. Two things follow from this, and both have to be solved:

**There's no netcode.** The engine has no concept of a second player. Nothing in the simulation was built to be shared, synchronised, or reconciled across two machines. Native entity IDs are local implementation details, player actions are not exposed through one documented universal interception point, and autonomous systems can mutate the map without asking the multiplayer layer first.

**There's nothing to compete *over*.** This is the deeper problem, and it's the one people miss when they ask for multiplayer. TPF2's economy is not zero-sum in any direction:

- Industries scale their output to whatever demand exists. Supply is effectively unlimited.
- Towns grow in response to service quality rather than being fought over. Serving a town well doesn't deny it to anyone.
- There's no land scarcity, no route exclusivity, no bankruptcy pressure, no meaningful cost to being second.

Nothing you build takes anything away from anyone. Bolt naive multiplayer onto that and you get two people playing singleplayer in the same window. The networking is the visible problem; the absence of contention is the real one.

---

## The core idea: contested demand

The mechanic the whole design hangs on is that **passengers and freight choose between operators**, and that choice is driven by things players control.

A town-to-town demand pool exists independently of who serves it. Each player's line into that pool is scored on:

- **Frequency** — how often service actually departs
- **Journey time** — real end-to-end time, including waiting and transfers
- **Price** — a per-line fare the player sets directly
- **Capacity** — whether the service can absorb the demand it attracts
- **Comfort / quality** — vehicle class, directness, transfer count

Demand then splits between competing operators in proportion to how attractive each option is. Not winner-takes-all — a split, so being slightly worse costs you share rather than everything, and there's always a way back.

This single mechanic produces the entire competitive game:

- Your rival runs Berlin–Munich hourly at a premium fare. You run it every 30 minutes at half price and start pulling their traffic.
- They respond by adding trainsets, which costs them capital and drops their margin.
- You've now started a price war on one corridor while quietly monopolising three regional routes neither of you were serving.
- Whoever over-commits capital to a contested corridor loses the flexibility to claim an uncontested one.

That's a real strategic game, and none of it exists in vanilla — not because the engine can't express it, but because nobody ever needed it to.

Layered on top: **exclusive supply contracts** with industries, **capped total industry output** allocated by who delivers first, **station and platform capacity limits**, and **route or land claims** — each adding a different flavour of scarcity so competition isn't only ever a price war.

---

## What a match looks like

Two players, one logical map, one shared clock, starting from the same save and the same capital.

Each runs a separate company. Your infrastructure is yours — your rival can't demolish your track, can't use your stations unless you lease them access, can't buy your vehicles. Shared public infrastructure (roads, and any station either player chooses to open up) is the negotiation surface.

You each see the other's construction appear live after the host accepts it. You see their lines, their published fares, and their headways — this is a game of visible competition, not hidden information. What you don't see is their balance sheet.

The scoreboard is company value, revenue, and network reach, all computed identically for both players and never in dispute.

A match ends on a year, a valuation target, or bankruptcy.

---

## Design principles

**Competition must be legible.** If you lose share on a corridor, the game tells you why — slower, dearer, less frequent. A competitive economy the player can't read is just noise.

**Both players see the same truth.** One machine is authoritative for everything that decides the outcome and for the ordered history of consequential world changes. Money, demand allocation, construction, ownership, town growth policy, and industry allocation are never independently decided on two machines and hoped to match.

**Autonomy has one owner.** Any native subsystem capable of changing geometry, topology, player-addressable entities, or competitive inputs must be disabled, made deterministic, or replaced by ordered host-generated events. The native engine may realise those events, but it may not invent consequential changes independently on each machine.

**Simulation fidelity is negotiable; structural and scoring fidelity are not.** If a train on your rival's screen is a few seconds behind where it is on yours, nobody cares. If a station exists only on one machine, a line points at a different local entity, or revenue differs by a coin, the game is broken. Effort goes where correctness matters.

**Vehicle drift is bounded at service boundaries.** Replicas need not integrate identical mid-leg physics, but they share one negotiated clock and every canonical vehicle rendezvouses at each stop. A train may be slightly ahead between stations; it may not silently gain an extra trip because one player opened a pause menu or one computer ran faster.

**The visible world must support the competitive truth.** Native passengers and freight do not have to match the economic model agent-for-agent, but directionally they must tell the same story. A service winning most of a market cannot routinely show empty trains while the loser appears full. Loads, queues, and score should agree closely enough that players can read the contest from the game world.

**Being second must hurt.** Every mechanic added should create a reason to move first, commit early, or accept risk. If a player can wait, copy, and lose nothing, the mechanic isn't doing its job.

**Vanilla feel stays intact.** This is not a total conversion. Building, vehicles, terrain, and the general rhythm of the game should feel like Transport Fever 2. What changes is that someone else is in the world with you, demand is finite, and autonomous growth follows competitive host-owned rules.

---

## How it works, in one paragraph

The host runs a deterministic economic model and an authoritative world-event log alongside the native game. Player intentions go to the host; the host validates and commits them, assigns stable canonical identities to created objects, and broadcasts ordered events whose references each machine translates to its own local engine IDs. Autonomous systems such as town and industry development are frozen or driven by the host through the same event stream. The model owns demand pools, route attractiveness, fares, revenue, contracts, and industry allocation, using host-read, canonicalised world facts rather than independently sampled client state. Native passengers, freight, and vehicle motion remain the operational presentation layer, but the mod steers or calibrates them so they agree directionally with the authoritative allocation. This avoids requiring every internal simulation detail to run in perfect lockstep without tolerating structural divergence between the two worlds.

---

## What this is not

- **Not co-op in one company.** Two players sharing one balance sheet and one network is a different mod with different problems. It may be a later mode; it isn't the goal.
- **Not a lobby game.** Two players, private sessions, friends playing friends. No matchmaking, no ranking, no persistent world.
- **Not multiplayer bolted onto the vanilla economy.** The competitive ruleset is the product. Networking is what makes it live.
- **Not a total conversion or an overhaul mod.** Asset and vehicle compatibility remains a goal, but the first multiplayer release uses a pinned, verified mod set rather than promising arbitrary Workshop compatibility.
- **Not cheat-proof public multiplayer.** The host is trusted. The target is private sessions between friends, not hostile-client anti-cheat.

---

## What "done" looks like

Two players on separate machines, consuming the same verified world-event history for a full simultaneous session, each building an independent company and competing for the same traffic on contested corridors. Topology and ownership remain coherent, visible loads tell roughly the same story as market share, and the scoreboard gives neither player a reason to doubt it — leaving only a reason at the end to argue about who played better.

Everything else is in service of that sentence.
