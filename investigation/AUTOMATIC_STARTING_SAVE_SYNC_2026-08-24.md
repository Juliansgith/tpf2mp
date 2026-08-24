# Automatic starting-save sync (2026-08-24)

> Later the same day, prototype 0.39 carried this unchanged bounded TCP
> protocol through authenticated WSS. See
> [Secure relay transport and support diagnostics](SECURE_RELAY_2026-08-24.md).

## Outcome

The next TPF2MP release adds a launcher-level **SYNC FROM HOST** action for a
fresh normal match. Player 1 selects the authoritative starting save and clicks
**HOST + LAUNCH GAME**. The host companion pins that save before hashing the
match and exposes only the pinned `.sav`, adjacent `.sav.lua`, and optional
`.jpg` on `gameplay TCP port + 1`. Player 2 copies the normal session/address/
port values, clicks **SYNC FROM HOST**, and receives a verified local copy in
the discovered Transport Fever 2 Steam save directory. The launcher fills the
save field only after the receipt is independently rechecked.

Receipt-bound recovery is intentionally excluded. Restore v6 gives each role a
different attested native save; copying the host restore to player 2 would be a
protocol violation rather than a convenience.

## Why this is pre-session

The ordinary companion handshake pins the starting-save hashes in the match
fingerprint. A Join peer without the save cannot authenticate that gameplay
connection, so sending the save over the already-authenticated gameplay stream
would be circular. A small adjacent listener exists only while the host
companion exists. The unchanged gameplay handshake remains the final proof that
both roles selected identical bytes.

## Wire and filesystem boundaries

- Protocol version 1 uses signed, size-bounded JSON control frames followed by
  exact-length binary file bodies.
- The request must name the exact session and `player2`; the server publishes
  no arbitrary path or directory listing.
- A SHA-256 manifest pins roles, sizes, total bytes, and content. Required role
  order is `.sav`, `.sav.lua`, then optional preview.
- Limits are three files, 8 GiB per file, 12 GiB total, two concurrent streams,
  and eight admitted download attempts per host process.
- The receiver stages data in a private directory inside the validated Steam
  save root. It verifies each body before installation.
- Metadata and preview are renamed first; `.sav` is renamed last. An interrupted
  transfer therefore never exposes a loadable partial save.
- Existing different files are never overwritten. An identical prior download
  is reused; a name collision gets a bounded numeric suffix.
- A receipt records the final paths and hashes. The PowerShell worker and GUI
  both re-hash it before populating the launcher's save field.

This is still the trusted-LAN/private-VPN alpha profile. The session id is a
scope value, not a public-Internet authentication secret. Tailscale or the
trusted LAN supplies transport privacy; the protocol supplies bounded file
exposure and end-to-end content integrity. A future public relay requires an
authenticated invitation and encrypted relay protocol rather than reusing this
listener unchanged.

## Operational behavior

Default gameplay TCP `29742` uses save-sync TCP `29743`. Host startup rejects a
busy adjacent port and does not report ready unless the save listener publishes
the expected session, port, and 64-hex bundle identity. Launcher status shows
`SAVE READY:<port>`. Join retries the save connection for 30 seconds so it can
be clicked while Host is still starting. Gameplay launch remains a separate
button after transfer, keeping the selected save visible and inspectable.

## Automated coverage

The companion tests cover:

1. complete triplet transfer and byte equality;
2. idempotent re-download/reuse;
3. wrong-session rejection;
4. collision handling without overwrite;
5. interrupted-stream cleanup with no visible `.sav`;
6. manifest tamper and missing-metadata rejection;
7. the packaged CLI receive path and durable receipt.

The PowerShell suite additionally builds the WinForms launcher, parses every
tool, accepts one complete worker receipt, and rejects that same receipt after
metadata tampering. The remaining live acceptance is one real two-computer
transfer of a representative large save followed by the existing fingerprint
and world-ready gates.
