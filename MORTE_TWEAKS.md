# Morte changes after the Triune 3.1 baseline

The published [v3.1-Morte.1](https://github.com/XxNeroMortexX/TriuneAutocombat/releases/tag/v3.1-Morte.1) tag points to commit `3b2ce131a5496eac319a698471f317e1b4ec9265`.
That release uses Gennro's Triune 3.1 Lua code with the separate MQ2WebUpdate integration. The tag is the baseline for subsequent Morte gameplay tweaks; it will not be moved.

Changes after that tag are listed here. Test status is recorded separately from publication so shared testing on main is not mistaken for completed validation.

## Auto AA controls — published for shared testing

- Auto AA: per-ability ignore, target rank, and purchase order; optional all-standard-AA mode. Fireworks and Consume Experience have independent purchase-table rows as well as cap spender choices above the scrolling list. For repeatable AAs, Stop at limits verified purchases during one Triune run (0 means unlimited); ordinary AAs still stop at the selected rank. Fireworks activation can inventory, leave, or delete only the verified item ID 22309 on the cursor. Consume Experience can activate AA 17789 after a verified purchase, with an equipped Power Source and ready AA.
- Validation: the controls and Consume Experience row were checked in game. Lua syntax and isolated purchase-count/limit checks passed. Actual purchases, Fireworks cursor handling, and Consume Experience activation/item XP still need shared in-game testing.
- Restart observation: a native MQ2Lua crash occurred during `/ac restart` while testing. Restoring the original files loaded successfully; stopping Triune, installing the test files, and starting it separately also succeeded. The crash cause is unconfirmed. Use separate `/lua stop triune` and `/lua run triune` commands during this test.
