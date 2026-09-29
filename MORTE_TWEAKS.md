# Morte changes after the Triune 3.1 baseline

The published [v3.1-Morte.1](https://github.com/XxNeroMortexX/TriuneAutocombat/releases/tag/v3.1-Morte.1) tag points to commit `3b2ce131a5496eac319a698471f317e1b4ec9265`.
That release uses Gennro's Triune 3.1 Lua code with the separate MQ2WebUpdate integration. The tag is the baseline for subsequent Morte gameplay tweaks; it will not be moved.

Changes after that tag should be listed here with the commit that introduced them. Work in progress stays on a separate branch until reviewed and tested in game.

## In progress

- Auto AA: per-ability ignore, target rank, and purchase order; optional all-standard-AA mode. The repeatable cap spender has visible Fireworks and Consume Experience choices above the scrolling AA list. Fireworks activation can inventory, leave, or delete only the verified item ID 22309 on the cursor. Consume Experience can activate AA 17789 after a verified purchase, with an equipped Power Source and ready AA. These new controls need an in-game test before merging into main.
