# MQ2WebUpdate

Created By: NeroMorte. Transactional MacroQuest updater for mapped GitHub files.

The 4.1.8 source candidate skips matching local Git blobs before downloading.
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

The shipped DLL and `release.json` remain 4.1.7 until Windows verification and game
testing finish. Use `tools/install_updater_rate_limit_test.ps1` for the candidate;
it preserves settings, Lua links, stashes and untracked files.
