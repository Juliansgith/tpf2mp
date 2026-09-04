# Third-party notices

TPF2MP is licensed under the [MIT License](../LICENSE). It includes, links, or
depends on the third-party material below. Nothing else in the repository is
copied from another project.

## Vendored source

- **MinHook** (`native/third_party/minhook/`) — Copyright (C) 2009-2017
  Tsuda Kageyu. BSD-2-Clause. MinHook bundles the **Hacker Disassembler
  Engine (HDE)** by Vyacheslav Patkov under its own BSD-2-Clause terms; both
  texts are in `native/third_party/minhook/LICENSE.txt`, and packaged releases
  ship that file as `licenses/MinHook-BSD-2-Clause.txt`. The hook DLL links
  MinHook statically.

## Python dependencies (not vendored)

Declared in `companion/pyproject.toml` and installed from PyPI, or frozen into
the packaged `bin/tpf2mp.exe`:

- **websockets** — BSD-3-Clause. Relay tunnel and save-transfer transport.
- **zstandard** — BSD-3-Clause; bundles the **zstd** library (BSD-3-Clause).
  Save and diagnostic compression.
- **PyInstaller** (build-time only) — GPL-2.0-or-later with the bootloader
  exception. Used to freeze the companion; the frozen executable is not
  subject to the GPL.

## Test and CI tooling

- **Lua 5.1.5** — Copyright (C) 1994-2012 Lua.org, PUC-Rio. MIT. The
  automated code gate runs the Lua test suites under a stock 5.1.5
  interpreter; `tools/ci/build_lua51.ps1` builds it from the official source
  archive on continuous-integration runners. The interpreter is not
  redistributed in releases — the game embeds its own Lua runtime.
- **pytest** — MIT. Python test runner only.

## Not included

- **Transport Fever 2** (Urban Games) is not part of this project and is not
  redistributed. The native hook supports exactly one pinned game executable,
  validates it before enabling, and patches it in memory only. For the
  duration of a session the launcher may place a game-script overlay file in
  the game's `res/config/game_script/` directory and removes it at cleanup;
  Steam's "Verify integrity of game files" restores the stock installation.
  This project is not affiliated with or endorsed by Urban Games.

## Acknowledgements (no code included)

- **"Multiplayer Companies" by Swiss** (Steam Workshop item 3710243057) was
  audited as prior art for the engine's multi-company APIs; see
  [MULTIPLAYER_COMPANIES_AUDIT.md](MULTIPLAYER_COMPANIES_AUDIT.md). No code
  from it is included, and TPF2MP's company handling is an independent
  implementation against the documented engine API.
