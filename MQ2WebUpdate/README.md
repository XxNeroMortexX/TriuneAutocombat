# MQ2WebUpdate

Created By: NeroMorte. Transactional MacroQuest updater for mapped GitHub files.

MQ2WebUpdate 4.1.8 skips matching local Git blobs before downloading.
Changed public files use commit-pinned raw URLs; private profiles keep authenticated
contents requests. Every downloaded payload must match the tree size and Git hash.

Reference metadata may be up to 30 seconds old, so repeated immediate checks reuse
one resolution. Immutable trees are reused for compare/stage. Anonymous metadata
and quota cooldowns are shared under `webupdate_cache` between EQ clients using the
same runtime folder, including plugin reloads. Authenticated metadata stays in
process memory; credentials are never written into cache files. Cooldown keys use
credential digests. Cache write failures fall back to process-local state.

All request entry points use the same pacing and cooldown policy. Rate-limit errors
stop the operation and show reset/retry timing; retry once that time passes. Ordinary
transient errors retain bounded retries. Raw hosting also has limits. Other PCs and
separate runtime folders do not share these local caches/cooldown files.

The published Win32/RoF2 4.1.8 DLL is the exact Windows build verified against its
build record. NeroMorte confirms version loading, repeated comparisons, and a
one-file README download/apply with zero errors and all 40 Lua links protected.
Automated regressions cover quota cooldowns and private credential isolation;
these do not imply a captured live GitHub rate-limit response from every client.

The focused `tools/install_updater_rate_limit_test.ps1` and restore script preserve
settings, Lua links, stashes and untracked files when building from the test branch.
Normal installations acquire the published DLL through their existing mapping.
