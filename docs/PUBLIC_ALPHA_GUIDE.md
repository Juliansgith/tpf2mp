# TPF2MP public alpha guide

This guide is for the two-player `0.43.4-alpha` release. It supports the
Windows x64 Transport Fever 2 **Build 35924** only. This is an early alpha:
use a disposable or backed-up save and expect bugs.

## 1. Install on both computers

1. Download the complete TPF2MP release ZIP and extract it. Do not run it from
   inside the ZIP.
2. Close Transport Fever 2, then run `INSTALL_TPF2MP.cmd`.
3. Accept the optional desktop shortcut if wanted.
4. Open **TPF2MP Multiplayer** and confirm that it reports
   `0.43.4-alpha` and a compatible native hook.

For the first test, enable only TPF2MP. Later tests may use identical
data-only mods on both computers, with the same versions and load order.
Arbitrary script or executable mods are not supported yet.

Player 2 does **not** need a copy of Player 1's starting save. The launcher
transfers and verifies the `.sav`, `.sav.lua`, and preview automatically.

## 2. Player 1: create the starting world

Create a normal **Free Game** in Transport Fever 2. Choose the map, starting
year, difficulty, vehicles, and other ordinary game settings you want. Leave
the base-game sandbox/no-cost options disabled for a real economy test.

Enable TPF2MP in the game's mod list, open its settings, and use these values
for a first public-alpha match:

| TPF2MP setting | Recommended value |
| --- | --- |
| Local peer | `player1 (host)` |
| Startup mode | `Standalone / hot-seat` |
| Freeze autonomous development | `No` |
| Native-income neutralizer | `Off` |
| Standalone ownership mode | `Native turn proxy (recommended)` |
| Pause on company switch | `Yes` |
| Company starting cash | `50 million` |
| Economy difficulty | `Normal (100% revenue)` |
| Match length | `Unlimited` for testing; `24 hours` for a competitive match |
| Victory model value | `Disabled` for testing; `$500m` for a competitive match |
| Physical town growth | `Off (capacities only)` |
| Bankruptcy elimination | `On (3-hour grace)` |
| Competitive credit | `Standard` |
| Native crowd simulation | `Skeleton crew: 1 native person/building` |
| Developer validator | `Off` |

The launcher later supplies the real peer, session, network mode, and autonomy
controls. Starting cash, economy, victory rules, and crowd mode belong to the
save and therefore must be chosen while creating the world.

Generate the map, pause it, and immediately make a normal named save **before
building anything or initializing a standalone match**. Exit the game. This is
the clean starting save Player 1 selects in the multiplayer launcher.

The Skeleton crew option must be selected while generating a fresh world. It
cannot safely be retrofitted into an existing full-population save.

## 3. Start a match

Keep the TPF2MP launcher open for the entire match on both computers.

### Player 1 / Host

1. Leave **Use secure relay** checked.
2. Select the clean starting `.sav`.
3. Click **CREATE SESSION**.
4. Click **COPY CODE** and privately send the full join code to Player 2.
   The short `mp-...` value is only the non-secret support/session ID.
5. Click **HOST + LAUNCH GAME** and wait at the Transport Fever 2 title screen.

### Player 2 / Join

1. Leave **Use secure relay** checked.
2. Paste the private join code and click **PREPARE JOIN**.
3. Check that the displayed `mp-...` ID matches Player 1. Leave the save field
   empty.
4. After Player 1 reaches the title screen, click **JOIN + LAUNCH GAME**. The
   starting save is downloaded and verified automatically.

### Both players

1. On the Transport Fever 2 title screen, click **MULTIPLAYER**. Do not use the
   ordinary Load Game button.
2. Open the in-game Multiplayer panel and select **Alpha Status**.
3. Start only when both games say `READY`, the link is connected, the match is
   running, and there is no `BLOCK` or fault message.

Player 1 owns Company 1 and Player 2 owns Company 2. Each has a separate
wallet, assets, lines, and vehicles. Both may connect to public town roads, but
private rival track, stations, depots, constructions, lines, and vehicles are
protected.

## 4. While playing

- Let a build or edit appear on both computers before issuing another complex
  command. Fast batches are supported, but this makes alpha bugs easier to
  identify.
- Pause and game speed are shared. A remote pause may take a moment to arrive.
- The in-game date is shared authored state. TPF2MP freezes Transport Fever
  2's independent recurring calendar and advances both games only with an
  automatic five-minute economy settlement. The pace is copied from the
  starting save (normally `2000 ms/day`), so the default settlement advances
  150 days and unlocks the same vehicles on both peers. A developer/manual
  settlement does not advance the date.
- Stop building while the panel says waiting, reconnecting, saving, or
  checkpointing.
- If one player disconnects, do not continue alone. The session pauses and
  allows up to 120 seconds for automatic reconnect and backlog replay.
- Native yellow station icons, income popups, and exact mid-leg vehicle
  positions are cosmetic. Use TPF2MP's Multiplayer views for authoritative
  passenger, cargo, and financial values.

## 5. Save and continue a healthy match

TPF2MP prepares coordinated recovery points automatically, normally about
every 15 minutes. Let a save/checkpoint operation finish before editing.

For an ordinary clean continuation:

1. Wait until both Alpha Status panels say `READY` and show the same current
   checkpoint.
2. Pause the shared game.
3. Player 1 makes a normal, clearly named Transport Fever 2 save.
4. Exit both games and close both launchers.
5. Next time, Player 1 creates a **new relay session** and selects that save.
   Player 2 prepares the new join code and receives the save automatically.

Never use a save made while disconnected, faulted, or while physical work is
still pending. A healthy initialized multiplayer save preserves both company
wallets, shared date, and canonical world bindings; the new session establishes
a fresh two-peer checkpoint before play resumes.

The Multiplayer panel also has **Prepare & Save Restore Point**. This creates
a stricter coordinated recovery boundary and makes a separate save for each
role. Those two role-specific saves are for fault recovery; they are not a
single ordinary save to copy between players.

## 6. If the session faults

Stop issuing commands and read **Session recovery** in the Multiplayer panel.

### If it says in-place recovery is READY

Press **Recover / Resync Session** once. Wait until both games report
`RECOVERED`, then `READY`, before selecting a speed and continuing.

This works only when both worlds prove the same safe state, such as a rejected
operation that changed neither world. It cannot repair genuinely different
geometry.

### If it says RESTORE REQUIRED, or a game crashed

1. Do not make a new normal save and do not continue on the surviving game.
2. Close both games and launchers, then reopen TPF2MP Multiplayer.
3. On Player 1, click **LOAD LATEST RESTORE** and answer **Yes** when asked if
   this machine is Host/Player 1.
4. On Player 2, click **LOAD LATEST RESTORE** and answer **No**.
5. Player 1 creates a new relay room and privately sends the new join code.
6. Player 2 prepares that code. Player 1 launches Host, then Player 2 launches
   Join.
7. Both click **MULTIPLAYER** at the title screen and wait for a fresh shared
   checkpoint and `READY`.

Never copy Player 1's restore save over Player 2's restore save. Each role must
load the save attested for that role and the same recovery boundary. If no
valid restore point exists, return to the last healthy Player 1 normal save or
start a new world.

## 7. Report bugs in `#bugs-logs`

Please paste this template:

```text
TPF2MP version: 0.43.4-alpha
Support/session ID: mp-________________
Player: P1/Host or P2/Join
Approximate local time and timezone:
What I was doing:
What I expected:
What happened:
Did the session fault, freeze, or crash?:
Screenshot or exact error text:
```

The `mp-...` support ID is safe to post and lets the developer find both
clients' redacted relay logs. **Never post the secret full join code** (it
starts with `TPF2MP1`).

For a construction problem, also mention the exact tool or building, whether
it connected to existing infrastructure, whether it demolished buildings or
changed terrain, and which player placed it. For a crash, photograph the fatal
error and include the minidump path if one is shown. Crash dumps are not
uploaded automatically; the developer may ask for the file privately.

## Alpha boundaries

- Exactly two trusted players; no hostile-peer security or host migration.
- Windows x64 Transport Fever 2 Build 35924 only.
- Secure relay is the recommended internet path; direct LAN/VPN is a fallback.
- Vanilla and identical data-only content are the supported baseline.
- This is an early alpha. Keep backup saves and report failures with the
  `mp-...` support ID.
