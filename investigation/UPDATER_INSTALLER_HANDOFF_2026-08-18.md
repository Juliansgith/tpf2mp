# Updater installer handoff regression — 2026-08-18

## Live finding

The installed `0.38.0-alpha` updater successfully authenticated to the private
GitHub repository, selected `0.38.1-alpha`, downloaded it, and verified its
release metadata. It then failed before installation with:

```text
A positional parameter cannot be found that accepts argument
'C:\Users\Sepgi\AppData\Local\TPF2MP'.
```

No game or installed files were replaced by the failed handoff.

## Root cause

`update_release.ps1` constructed this array and splatted it into another
PowerShell script:

```powershell
@('-BundleRoot', $newBundle, '-InstallRoot', $install)
```

Windows PowerShell 5.1 treats an array splat as positional values; it does not
reparse strings beginning with `-` as named parameter tokens. The old tests
proved remote selection and `-CheckOnly` archive verification, while the
transactional installer suite invoked the installer directly with real named
syntax. Neither crossed the boundary between them.

## Correction

- The updater uses hashtable splatting for exact named values.
- The `0.38.2-alpha` installer accepts the one historical positional binding
  emitted by `0.38.0-alpha` and `0.38.1-alpha`, allowing those updaters to
  bootstrap into the fixed version.
- That compatibility grammar accepts only the expected bundle/install paths
  and known optional switches. Missing, duplicate, or unknown tokens fail.
- The release updater test now extracts a newer ZIP, invokes its installer,
  and verifies the exact received paths, including spaces.
- The transactional installer test invokes the real installer through the old
  array-splatted shape and verifies the installed pointer and mod copy.

`0.38.1-alpha` remains immutable and is marked superseded; corrected bytes are
published under the new semantic version `0.38.2-alpha`.
