# Secure relay transport and support diagnostics (2026-08-24)

## Outcome

Prototype `0.39.0-alpha` has a transport wrapper around the already-tested Host
sequencer, Join client, and starting-save protocol. Both players connect
outbound to a separate HTTPS/WSS service; no player exposes gameplay or save
ports. Player 1 remains authoritative. The service pairs bytes and records
bounded support metadata, but cannot author, reorder, validate, or settle a
game action.

The service lives in the sibling `tf2mp-relay` repository rather than the game
repository. This keeps the public attack surface, deployment dependencies,
retention policy, and server release cadence outside the native-hook/mod
package.

## Invitation and trust boundary

- `POST /v1/sessions` allocates a non-secret `mp-<16 hex>` support ID plus
  independent 256-bit Host and Join tokens.
- The player-facing `TPF2MP1...` code contains only the room ID and Join token;
  it does not contain or redirect to a server URL. Both clients must use the
  release-pinned trusted relay URL.
- Tokens are accepted only in `Authorization` headers. The service stores keyed
  SHA-256 digests, not plaintext credentials. Local credentials are written to
  current-user ACL files and never printed or placed in process arguments.
- Role, room, and channel are immutable. Cross-room credentials, role
  impersonation, duplicate live roles, malformed messages, and unequal known
  match fingerprints are rejected.
- Plain HTTP is impossible outside an explicit loopback development switch.
  Production also refuses to start without an independent admin token and
  token-hashing pepper.

The design still assumes trusted game peers. Encryption and relay
authentication prevent network exposure; they do not make the native game or a
malicious player process trustworthy.

## Transport

The client creates two local-loopback bridges:

1. `gameplay`: one complete existing newline-delimited signed protocol frame
   per binary WebSocket message, bounded to 4 MiB;
2. `save`: bounded 64 KiB raw chunks carrying the existing manifest/hash/
   transactional-install protocol.

Host tunnels connect to local Host services. Join tunnels listen only on
loopback for local Join clients. Compression is disabled. TLS certificate and
hostname verification use the platform trust store. A tunnel break closes both
sides of that paired channel. The existing companion sees a normal TCP loss,
pauses/fences the session, reconnects, and replays its ordered backlog; there is
no silent direct fallback.

For a fresh match, Join starts both local listeners first, receives the complete
save, creates the ordinary match manifest, and only then connects gameplay.
Receipt-bound recovery remains peer-specific and bypasses ordinary save copy.

## Diagnostics and privacy

Each client tails only launcher-selected `.log`, `.txt`, `.json`, or `.ndjson`
files. It does not walk directories, accept binary/save extensions, or upload
raw crash dumps. Reads, lines, event batches, timestamps, recursion, strings,
queueing, requests, and per-room storage are bounded. Cursors advance only
after the service accepts the entire batch, including across log rotation and
the 128-event client batch boundary.

The client sends structured events; the server applies a second recursive
redaction for credential-like keys, bearer strings, invite codes, Windows/Unix
user paths, and IPv4 addresses. Gameplay audit rows contain protocol metadata
only: direction, bytes, protocol/kind, peer/sequence, action type, and a short
checksum value. The action payload and save bytes are forwarded but never
persisted.

Support lookup uses only the `mp-...` ID. Admin endpoints require an independent
bearer token and are designed to be blocked from the public network. The local
server command `tpf2mp-relay inspect mp-...` reads the dedicated database
without returning token hashes.

## Server containment

The supplied Compose definition runs one unprivileged UID, drops every Linux
capability, enables `no-new-privileges`, uses a read-only root filesystem and
bounded tmpfs, and caps CPU, memory, and PIDs. It mounts only its SQLite volume,
binds the application to host loopback, and expects a dedicated TLS virtual
host. It never receives the Docker socket, SSH keys, home directories, game
saves, or another hosted service's volume. Admin routes should additionally be
restricted to Tailscale/private management addresses at the reverse proxy.

Default rooms expire after eight hours; retained diagnostic metadata is pruned
after 30 days and capped at 100 MiB per room. SQLite uses WAL, full synchronous
commits, and a single bounded asynchronous audit writer. An audit-disk failure
drops/marks diagnostics without killing gameplay or deadlocking shutdown.

## Executed validation

Service tests: 25 passed, covering invite/token behavior, production TLS/
secret configuration, server-side redaction, API authorization, role closure,
cross-session rejection, diagnostic quotas, retention, bidirectional tunnels,
duplicate roles, content-fingerprint mismatch, bounded limiter memory, local
operator lookup, and audit-writer failure containment.

Main project: 137 Lua tests and 196 Python tests passed with all cross-language
parity, PowerShell/CMD syntax, manifest, installer, updater, save-sync, launcher,
and recovery tests.

A real local full-stack wrapper run used the same PowerShell launch path that a
release uses. It transferred `.sav`, `.sav.lua`, and `.jpg` totaling 54,455,136
bytes, produced identical bundle and match fingerprints, connected and
synchronized both companions, and uploaded both redacted timelines. The relay
record contained 76 events (28 Host-client, 18 Join-client, 21 protocol-frame,
and two paired events) with no credential value. Stopping the relay put both
tunnels into retry; restarting against the same database re-paired them and P2
reported one clean reconnect without a session fault.

## Remaining live gate

1. Deploy the separate repository behind a real named HTTPS endpoint.
2. Put that endpoint in the signed main-release `relay-config.json`.
3. Install the same clean `0.39.0-alpha` release on two physical computers.
4. Create/prepare a room, transfer a representative save, reach READY, perform
   construction/operation/economy actions, force one short network outage, and
   verify recovery plus the support-ID timeline.

No game processes need to remain running for deployment.
