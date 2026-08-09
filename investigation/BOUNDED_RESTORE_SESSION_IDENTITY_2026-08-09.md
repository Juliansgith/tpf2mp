# Bounded restore session identity

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

Launcher-managed session ids are deliberately limited to 64 portable ASCII
characters. A source session may itself occupy all 64, while the original
restore rule appended `-r<boundary>`. The restore-plan verifier accepted source
ids up to 160 characters, but the launcher and Lua restore action accepted only
64. A perfectly legal match could therefore create a verified plan that no
launcher could resume.

## Implemented contract

`session_identity.py` and `restore_session_identity.lua` now share one rule:

- validate the source as a normal 1-64 character session id;
- retain `<source>-r<boundary>` whenever it fits;
- otherwise retain a source prefix, add two independent eight-hex Adler tags
  over the full source/boundary identity, append the readable boundary, and
  cap the result at exactly 64 characters.

The tags resist accidental filesystem/session aliasing; they are not hostile
participant authentication. The restore plan still carries the full source
session, boundary, core, convergence key, peer save hashes, and checksum.

Current v4 plans use the bounded rule. V2/v3 retain their historical readable
formula and now fail early if that historical result is not launcher-safe;
this does not invalidate a formerly launchable plan. The legacy recovery-plan
analyzer also emits and verifies the bounded identity.

Lua saved-state migration derives the expected identity independently instead
of trusting the launcher's string. Python plan verification does the same.
PowerShell continues to enforce the final 64-character portable shape.

## Offline evidence

- Python and Lua produce
  `session-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-hae6020ae6d5e203d-r7`
  from the same 64-character source and boundary 7.
- The result is exactly 64 characters and changes when the truncated source
  tail changes.
- A current v4 plan carrying it verifies; an overlong legacy formula is
  rejected before launch.
- State migration accepts the bounded id only when its source/boundary
  attestation derives the same value.
- The launcher accepts the bounded value and rejects 65 characters.

## Remaining live gate

The ordinary automatic restore test remains the important gate. A deliberately
long source-session run is now safe to add as a low-frequency regression after
the populated v4 two-process restore succeeds.
