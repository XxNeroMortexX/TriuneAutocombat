# Morte changes after the Triune 3.1 baseline

The published [v3.1-Morte.1](https://github.com/XxNeroMortexX/TriuneAutocombat/releases/tag/v3.1-Morte.1) tag points to commit `3b2ce131a5496eac319a698471f317e1b4ec9265`.
That release uses Gennro's Triune 3.1 Lua code with the separate MQ2WebUpdate integration. The tag is the baseline for subsequent Morte gameplay tweaks; it will not be moved.

Changes after that tag are listed here. Test status is recorded separately from publication so shared testing on main is not mistaken for completed validation.

## Auto AA controls — published for shared testing

- Auto AA: per-ability ignore, target rank, and purchase order; optional all-standard-AA mode. Fireworks and Consume Experience have independent purchase-table rows as well as cap spender choices above the scrolling list. For repeatable AAs, Stop at limits verified purchases during one Triune run (0 means unlimited); ordinary AAs still stop at the selected rank. Fireworks activation can inventory, leave, or delete only the verified item ID 22309 on the cursor. Consume Experience can activate AA 17789 after a verified purchase, with an equipped Power Source and ready AA.
- Validation: the controls and Consume Experience row were checked in game. Lua syntax and isolated purchase-count/limit checks passed. Actual purchases, Fireworks cursor handling, and Consume Experience activation/item XP still need shared in-game testing.
- Restart observation: a native MQ2Lua crash occurred during `/ac restart` while testing. Restoring the original files loaded successfully; stopping Triune, installing the test files, and starting it separately also succeeded. The crash cause is unconfirmed. Use separate `/lua stop triune` and `/lua run triune` commands during this test.

## Auto-Accept tell and guild commands — published after in-game testing

- Auto-Accept adds separate default-off group invite and DZ add tell controls in the Auto-Accept window and Plugins -> Configure. `invite` / `dzadd` and `invite me` / `dzadd me` use the sender; a single named character can be used instead. Guild commands must begin with this bot's exact name (case-insensitive), for example `Mortefreddo dzadd me`. The same checkboxes, permissions, and cooldown apply to both channels. Commands operate through incoming chat events, without chat polling.
- Tell permission is separate from invite-accept permission: whitelisted names (default), same-guild players (tells require a verified spawn in this zone; genuine guild messages also work across zones), or anyone. The existing whitelist editor supplies names; saved spawn IDs do not authorize tells. An authorized sender may request an invite for another character. A shared two-second cooldown limits command dispatch. Known leadership, full-group, and duplicate-group-member conditions are checked; unavailable client fields leave final permission enforcement to the game. DZ commands require a confirmed current expedition; when none exists, the bot privately tells the authorized sender "I'm not in a DZ to invite you." Unreadable DZ state prevents dispatch without asserting that no DZ exists. These checks do not confirm that an invitation succeeded.
- Settings save with the character's existing Triune loadout. Original Auto-Accept behavior and author credits remain intact; modified blocks are marked `Edited By: NeroMorte`.
- Validation: `texlua tests/test_auto_accept_tells.lua` checks parsing, command-injection rejection, disabled toggles, independent sender permissions, guild verification, cooldown, known leadership restrictions, configuration saves, and event cleanup. The user reported the first tell-command version working in game. The extended isolated checks also cover no-argument defaults, addressed guild messages, private no-DZ replies, and cross-channel cooldown. The user reported the updated tell/guild version working in game and approved merging to main. Settings persistence across a full restart has not been separately confirmed.

## Range controls and AA bank — published after slider testing

- Camp Radius, Pull Radius, Search Radius, and Engagement Distance retain their existing positive minimums and Ctrl+click input. Their drag scales start at 10,000 and expand to higher saved or typed values, removing the old gameplay upper caps. Actual spell and weapon reach still governs ranged pulling.
- Auto AA Bank accepts 1 in the slider, saved-settings cleanup, and purchase threshold helper. Existing defaults remain unchanged. Each modified code block is marked `Edited By: NeroMorte`.
- Validation: Lua syntax and isolated checks passed for large typed/saved ranges, native slider drag bounds, existing positive minimums, and bank 1 through load, UI, purchase helper, and command. The user confirmed Ctrl+click accepts higher values and the expanded slider drag ranges work in game. AA Bank persistence across a full restart has not been separately confirmed.

## True Self spell targeting — published after in-game testing

- Restores the old NeroMorte gem-casting fix using both actual spell Beneficial and TargetType metadata. Beneficial Self spells preserve the current selected target even when the configured recipient is self or pet. They do not lock the cast tracker onto that recipient or queue target restoration. Gennro's existing self-heal exception and targeting for other spells remain intact. Changed blocks are marked `Edited By: NeroMorte`.
- Validation: Lua syntax and isolated execution of the actual castGem function passed for hostile/friendly/no current target, self/pet recipients, bard songs, aborted movement casts, targeted buffs, missing metadata, and existing self-heals. The user confirmed this fix worked in game and approved merging to main. AA and clickie dispatch are unchanged.

## Native EverQuest camp map — test branch

- Adds default-on Show Camp on EQ Map in Control. MQ2Map draws a green X and radius outline at the saved camp, refreshing when camp/radius changes. Triune's own map remains independent. No shaded fill is attempted because maploc exposes an outline only.
- Every Clear Camp control removes the map marker and suppresses automatic redraw until Set Here or START, even if Gennro's puller loop recreates the gameplay camp. Gameplay camp initialization is unchanged. Removes only the marker location rather than clearing all maplocs; does not change MQ2Map filters. Zone/character changes and normal window closure clear the marker. Forced Lua termination may bypass normal cleanup.
- Validation: Lua syntax and isolated marker/radius, suppression/re-enable, MQ2Map reload, missing/invalid camp, and scoped-removal checks passed. Existing Self spell and range/AA-bank checks still pass. In-game testing is pending. Edited blocks are marked Edited By: NeroMorte.
