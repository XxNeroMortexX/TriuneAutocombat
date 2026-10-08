# Windows MQ build-artifact layout test

Created By: NeroMorte

This local Windows tool uses the read-only preflight report to configure the successful shared MacroQuest C++ projects. It leaves deployed DLL/EXE destinations intact and groups build-only output beneath `E:\MQ2Next\macroquest\build\artifacts`.

| Output | Folder beneath artifacts |
| --- | --- |
| Compiler intermediates, compiler PDBs, PCH, incremental data | `obj/<platform>/<configuration>/<project>` |
| Static libraries, import libraries and matching EXP files | `lib/<platform>/<configuration>` |
| Linker PDBs | `symbols/<platform>/<configuration>` |
| Configuration backups, pre/post evaluation logs and rollback manifest | `Backup/layout-<timestamp>` |
| Preserved older library copies and unusual runtime build files | `legacy-runtime` |

Separate-client builds use client subfolders within this same artifact parent. Runtime binaries keep their existing `build/bin/...` paths. Vendor-supplied third-party libraries are inputs and are not relocated.

## Preflight and installation

Run the read-only preflight first and review its report. The default report path is the most recent `%TEMP%/MQ-artifact-preflight-*/preflight.txt`; alternatively supply `-PreflightPath`. The reported `Release/Win32` settings are checked again before any configuration edits. The October 8 report contained 134 successful shared MQ projects, one standalone legacy ZLib project and two failed legacy DanNet helper projects. The standalone/failed projects are outside this configuration change.

Close Visual Studio and finish builds before installation. The installer does not compile, unload plugins, or replace DLLs/EXEs. Ordinary VS/MSBuild builds then inherit the saved shared settings. Explicit command-line intermediate-directory overrides used by isolated test/build scripts retain their staging directories.

The shared artifact directory and library search paths are configured in `src/Common.props` and `src/Plugin.props`. A new `src/NeroMorte.Artifacts.targets` applies final linker defaults after project-specific overrides, including MQ2Nav/MQ2DanNet import-library overrides. The existing Actors test project intermediate-directory overrides are updated when present. Every edited block is marked.

After edits, the installer evaluates each reviewed shared project and requires its effective intermediate/library/PDB paths to lie beneath artifacts. Runtime targets must retain the preflight target/output paths; static library targets must move beneath artifacts. Only then are old `build/obj`, `build/lib` and build-only files in runtime release/plugin directories moved. File hashes are checked, destination conflicts are preserved separately where appropriate, and every move is recorded. It never follows runtime Lua links.

This keeps existing native binaries unchanged. Their embedded PDB paths may still name the old locations; when debugging those binaries, point the symbol search path to the relocated symbols directory. Future builds embed the new symbol path. Moving compiler caches can cause recompilation or regeneration on the next build.

## Rollback

Stop builds, then use the exact restore command printed by installation with `-Action Restore -BackupPath <printed folder>`. Rollback restores configuration backups and reverses recorded moves. Manual restore stops if settings or moved runtime artifact files changed after installation, preserving subsequent work for review. Keep the backup and test a normal build before removing anything.

Main Triune runtime/version and the Box Network EQBC test branch are unchanged by this tool. No plugin version bump or runtime release is performed. Actual Windows/MSBuild evaluation and the later native rebuild are still required; Linux validation covers script syntax, XML structure and reviewed output-path definitions.
