# EQBC servers — NeroMorte updater test

Created By: NeroMorte

Both server EXEs belong beside `MacroQuest.exe`. They use the standard RedGuides MQ2EQBC client plugin; no special client DLL is included or required.

- `EQBCS.exe`: the supplied, verified RedGuides server 1.9; native source is retained unchanged in `native/EQBCS.cpp`.
- `EQBCS-Go.exe`: eqbc-go with NeroMorte INI support, explicit command-line overrides, separate `EQBCS-Go.ini` with legacy `EQBCS.ini` fallback, and internal Triune packet logs hidden by default. Version: `1.0-NeroMorte.2`.

The Go build was cross-compiled for Windows amd64 with Go 1.24.0, `CGO_ENABLED=0`, `-buildvcs=false` and `-trimpath`. Source and upstream MIT license are in `Go/`; `EQBCS-Go.exe --license` displays that notice. The native server is Windows x86. Exact sizes and SHA256 hashes are in `release.json`.

## Settings

Existing INIs are never updater mappings and are never overwritten. When an EXE exists and its INI is absent, Triune creates settings once. Native defaults to port 2112. A fresh Go INI defaults to 2113 so both servers can run together; if a legacy shared INI exists, Go's new INI copies those existing settings to preserve connections. Change either port as needed.

Go reads `[Settings]` keys `Host`, `Port`, `Password`, `Verbose`, `NoTimestamp`, `NoColor`, and `ShowInternalPackets`. Explicit flags override INI values; `--ini PATH` selects a file and `--no-ini` ignores settings. Action flags `--help`, `--version` and `--license` do not need INI entries. Set `ShowInternalPackets=true` or pass `--show-internal-packets` to display internal `//ac net _eqbc` transport logs. Chat, ordinary commands, connections and errors remain visible. Packet delivery is unchanged.

Client-window echo settings remain MQ2EQBC preferences, separate from server logging. The existing quiet settings are `/bccmd set silentcmd on`, `/bccmd set silentinccmd on`, `/bccmd set silentoutmsg on`, and `/bccmd set echoall off`.

## Updater integration

MQ2WebUpdate 4.1.7 adds a flat `mq` destination root. Add-only registration creates optional nonrecursive EXE mappings in enabled NeroMorte main-download profiles, preserves existing/custom/disabled mappings, and waits for backend capability. Server files use normal Check, Stage and Apply with verified Git blobs, backups and rollback. Close the server before applying a server update; a running/locked EXE blocks the entire Apply preflight. The updater never starts or terminates either server.

The test installer fully rebuilds MQ2WebUpdate locally, backs up source and binaries, preserves runtime Lua links and existing INIs, and installs the exact test revision. Its DLL is not published until the Windows build and game test are confirmed. This is a test branch, not a completed main release.
