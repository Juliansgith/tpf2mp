# Restore profile binding and launcher resume path

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

The receipt-bound restore plan proved the checkpoint boundary, peer roster,
core digest, convergence key, and each peer's main `.sav` hash. It did not name
the source session's match-content policy. `start_network_session.ps1` would
therefore generate its new manifest and runtime configuration from the current
launcher defaults. A restore could load the correct authored state while
silently changing `agentMode` or whether physical town development is enabled.
The mandatory post-load core checkpoint did not cover that machine-local input.

The ordinary launcher also had no resume workflow. The scripts could accept a
plan and peer save, but a player had to construct the command line and know that
Host needs player1's save while Join needs player2's save.

## Implemented boundary

Restore plan version 3 adds one exact `matchContentProfile` object:

```json
{"schemaVersion":1,"agentMode":"skeleton","townDevelopment":false}
```

No additional or missing keys are accepted. Agent mode is limited to the three
runtime-supported values and the town-development value must be a JSON boolean.
The profile participates in the existing canonical plan checksum. Automatic
host plan generation reads the immutable profile file already used by the
match manifest. The manual archive path does the same when session state makes
that file available. Existing version-2 plans remain readable and retain their
old, explicitly policy-unbound behavior.

Restore startup performs the checks in this order:

1. verify the plan and this peer's selected `.sav` hash through the companion;
2. for v3, adopt the plan's agent and town-development values;
3. reject an explicitly supplied conflicting launcher value;
4. generate the resumed match profile and content fingerprint from those
   resolved values;
5. include the same restore-plan file in both peers' match fingerprints.

The launcher now exposes **SELECT RESTORE PLAN...**. It verifies plan structure
and checksum before displaying or trusting metadata, locks the session field to
`resumeSession`, identifies the Host/player1 versus Join/player2 save rule, and
passes both selected paths to the existing strict startup path. `New name`
leaves restore mode. Disposable localhost/capture labs reject restore mode so a
peer-specific restore save cannot accidentally be treated as an ordinary
shared starting save.

## Compatibility and trust limit

Version 2 remains accepted because the already live-proven boundary-8 evidence
uses it. Startup prints a warning and uses the explicitly selected/default
policy. Version 3 is required for every newly automatic plan. The command-line
generator also requires either a profile or the explicit
`--allow-legacy-unbound` escape hatch, preventing an accidental new v2 plan.

`protocol.sign` is an Adler-32 integrity checksum, not a secret-key signature.
This change closes accidental/corrupt configuration drift and binds both peers
to identical bytes through the match fingerprint; it does not authenticate a
hostile plan author. TPF2MP remains a trusted-LAN/VPN prototype.

The plan currently attests the main `.sav` through the ordered receipt while
the recovery archive separately hashes the complete native save set. The fresh
post-load checkpoint still fails closed on wrong script state. Unifying those
two file-integrity layers is a separate hardening item and is not claimed here.

## Offline evidence

- Legacy v2 construction and verification still pass.
- V3 construction, exact profile retention, malformed field/type rejection,
  missing-profile rejection, and re-checksummed tampering rejection pass.
- PowerShell tests cover v3 policy adoption, explicit conflict refusal, and v2
  fallback.
- The companion exposes metadata-only plan verification for the launcher; this
  mode explicitly refuses simultaneous save arguments so it cannot be mistaken
  for restore readiness.
- PowerShell parsing, launcher construction smoke, source boundaries, full
  Lua/Python replay, release, and install tests pass in the associated change.

## Remaining live gate

Create one automatic restore point in a populated two-process network match,
close both games, distribute the host's v3 plan, and use the launcher picker on
both machines. Host must select player1's attested save and Join player2's.
Verify that both load, the restore checkpoint converges, the saved agent/town
policy is retained, and trains/freight resume. Repeat once with a deliberately
wrong peer save and once with an explicit conflicting script parameter; both
must fail before gameplay.
