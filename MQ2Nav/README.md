# NeroMorte MQ2Nav XYZ integration

Created By: NeroMorte

Version **1.3.3.5**, internal plugin version **1.3305**. Original MQ2Nav source: [brainiac/MQ2Nav](https://github.com/brainiac/MQ2Nav), base commit `8513d189f96d1b8ada9435456be34f0ec855f22b`. Custom sources retain original code and per-block NeroMorte edit credits. `baseline/` is the installed 1.3.3.4 source used for guarded upgrade and rollback checks.

The binary is built for **RoF2 Win32**, against MacroQuest commit `8d97fa3c78d549fc0849aec332f0e25413a74293`. A Windows C++ build is required. This directory preserves the patched translation units, not a complete independent MacroQuest checkout.

## Settings

| Saved setting | Default | Command |
|---|---|---|
| Auto XYZ in water or while levitating | Off | `/nav ini XYZ 1` or `0` |
| Accept close stalled XYZ spawn arrival | On | `/nav ini XYZStallArrival 1` or `0` |
| XYZ stall seconds | 5 | `/nav ini XYZStallSeconds 5` |
| XYZ close distance limit | 5 | `/nav ini XYZStallDistance 5` |

The existing Nav UI exposes all four under Settings → General. Explicit `xyz=on/off` overrides the saved default for that route. Settings do not convert one-shot Nav into permanent follow: Triune reissues its own approach when the leader moves.

Mesh routing remains required. Direct live XYZ steering applies to tracked spawns in water or while levitating, with mesh visibility and actual line of sight. Ground movement and location/door/object routes retain ordinary behavior. Exact requested distance is tested first; zero uses a one-unit tolerance. Close stalled arrival requires horizontal arrival, total XYZ distance within the cap, and no meaningful progress for the configured window. Moving targets reset the window. Stalls beyond the cap cancel instead of reporting success.

## Completion TLOs

`Navigation.LastResult` (`None`, `Reached`, `Cancelled`), `LastResultSerial`, `LastTargetID`, `LastTag` and `LastXYZStallArrival` retain facts from the last active route completion. Inactive `/nav stop` does not replace them. Triune uses unique route tags plus the serial, current target/range/zone and bounded geometry; inactive Nav alone is never treated as a successful relaxed arrival.

## Install, test, publish

1. Stop Triune in every client and unload Nav everywhere. EQ may remain open. Run the exact-revision `tools/install_nav_integration_test.ps1` command supplied with the PR.
2. The native installer verifies source hashes, backs up DLL and source, compiles fresh per-project objects without Clean, verifies all Nav translation units and exported/resource versions, then replaces the unloaded DLL. Restore instructions are printed. Lua links are preserved; missing support-module links are added only when needed.
3. Load Nav, enable Auto XYZ, start Triune and test water/levitation Chase, close stalled arrival, moving leaders, ordinary ground routing, permitted combat movement and missing-path UW fallback.
4. Run `tools/publish_nav_test.ps1 -Revision <installed commit> -BuildBackup <printed integration backup>`. It verifies the runtime/staged DLL hash, exact sources and MacroQuest commit, then commits the real DLL and matching SHA metadata to the test branch. It never writes main or uses Git LFS. Retest the updater mapping and handoff before main merge.

`release.json` and Lua publication metadata remain disabled until step 4. Enabled metadata causes an add-only mapping migration for the existing NeroMorte updater profiles. Custom or disabled user mappings remain untouched. No new updater engine DLL is needed; use the existing independent Lua coordinator. Users still use their normal update controls, and Nav must be unloadable in every client sharing the DLL.

## Validation

`python3 MQ2Nav/test_movement.py` compiles the shipped movement/Stop implementations against isolated MQ/GLM doubles; `test_settings.py` checks the actual settings/route parser. Lua suites cover route ownership, accepted arrival invalidation, cancellation fallback, Nav-first Chase/combat and add-only profile migration. These tests cannot replace Windows compilation or in-game behavior checks.
