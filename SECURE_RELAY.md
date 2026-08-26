# TPF2MP secure relay

TPF2MP 0.39 adds a transport and support layer; it does not change the tested
game authority model. Player 1 still orders every commit and both independent
worlds still prove physical results and checkpoints. The relay only pairs two
authenticated byte streams.

## Player flow

The launcher enables **Use secure relay** by default.

1. Host selects the starting save and clicks **CREATE SESSION**.
2. Host copies the opaque join code and sends it privately to Player 2.
3. Join pastes it and clicks **PREPARE JOIN**.
4. Host launches, then Join launches. Join's complete starting save is
   transferred and verified automatically; no ports or manual file copy are
   required.
5. Either player can report the visible `mp-...` support ID when something goes
   wrong. The support ID cannot authenticate or join a room.
6. Keep each launcher open while playing. Closing it is an intentional clean
   end-session action: its exact game, companion, tunnel, diagnostics, recovery
   helpers, and autosave guard are stopped together. Starting a new match also
   reclaims a previous session only when its recorded process identities verify.

There is no fallback from relay to direct mode during a match. A tunnel loss
enters the existing pause/reconnect fence; missed commits replay before the
world becomes ready again. If recovery fails within the bounded grace period,
the session faults closed.

## What leaves a player's computer

- encrypted gameplay and save-transfer bytes while their peer is connected;
- bounded metadata for gameplay frames: direction, byte count, protocol kind,
  peer/sequence, action type, and a short checksum field; and
- bounded lines/snapshots from explicitly named companion status/log files.

The relay never stores save-transfer bytes or gameplay command payloads. The
diagnostic reporter cannot discover arbitrary files and rejects save/binary
extensions. Both client and server redact secret-looking fields, bearer values,
join codes, Windows/Unix user paths, and IPv4/IPv6 addresses. Raw crash dumps
and memory dumps are never uploaded automatically.

Default retention is 30 days, with an eight-hour room lifetime and a 100 MiB
per-room diagnostic ceiling. These are server policy values and may be reduced.

## Credentials

Host and Join receive different 256-bit random credentials. They appear only in
authorization headers and current-user-protected files under
`%LOCALAPPDATA%\TPF2MP\relay-drafts`; they are never printed in launcher logs or
placed in URLs/process arguments. The service stores only keyed SHA-256 token
digests. Closing a Host session invalidates both roles.

The join code contains the Join credential, so it should be sent privately.
The `mp-...` support ID contains no credential and is safe to quote in a bug
report.

## Server isolation

The relay is maintained in the separate `tpf2mp-relay` repository. Its supplied
Compose deployment:

- binds the application only to `127.0.0.1` behind a dedicated HTTPS/WSS
  reverse-proxy virtual host;
- runs as an unprivileged UID with all Linux capabilities dropped,
  `no-new-privileges`, a read-only root filesystem, and CPU/memory/PID limits;
- mounts only a dedicated SQLite data volume; it never mounts Docker control,
  SSH keys, home directories, game saves, or another hosted service's data; and
- returns `404` for `/v1/admin/*` at the public Nginx host. Support lookup uses
  the local container CLI; the service retains independent admin authentication.

An operator can look up one support ID using the protected admin API or locally
on the server with `tpf2mp-relay inspect mp-...`. Neither route returns player
credentials.

Plain HTTP is rejected except for an explicit loopback-only development mode.
The deployed endpoint is `https://tpf2mp.213-133-98-90.sslip.io`; HTTP redirects
to HTTPS and its Let's Encrypt certificate renews automatically.
