# Riverside L4D1 plugins

SourceMod plugins from the Riverside PUG servers (Left 4 Dead 1 versus, Rotoblin-AZMod,
100 tick, Linux). Everything here runs live on our servers.

The folders mirror a server install: copy `addons/` and `cfg/` into `left4dead/`.
Each plugin ships as source (`addons/sourcemod/scripting`) and compiled
(`addons/sourcemod/plugins`, SourceMod 1.11+).

## Our plugins

| Plugin | Version | Needs | What it does |
|---|---|---|---|
| `l4d_witch_corner_fix` | 1.0.0 | DHooks, gamedata `l4d_witch_corner_fix.txt` | Stops a startled witch freezing on corners when `nb_update_frequency` is low (we run 0.014). See below. |
| `l4d_witch_unstuck` | 2.4.0 | left4dhooks | Fallback for a witch that makes no progress toward her target for 3 s: nudges her 8/16/24 units off the snag, then allows a short hop to a nearby nav spot (at most 120 units sideways, never when she is already within 120 units of her target). `!stuckwitch` logs a snapshot for admins. |
| `l4d_saferoom_lock` | 1.2 | left4dhooks | Holds the end saferoom door open and unusable while a tank or witch is still alive. |
| `l4d_skypounce` | 0.4.0 | | Stops hunters chaining pounces off the sky brush ("ceiling pouncing"). Mode 1 is Zen's rule, mode 2 a last-surface-touched rule. |
| `l4d_tank_burn_cap` | 1.0 | | Caps total fire damage on the tank so a molotov chips it instead of killing it. |
| `l4d_vote_lock` | 1.0 | | Makes `!load`, `!match`, `!mode`, `!changemap`, `!cm` and `!setscores` admin only. An admin override does nothing on commands registered with `RegConsoleCmd`, so this uses a command listener instead. |

## Fixed forks of existing plugins

Drop-in replacements for the Rotoblin-AZMod versions. They use the phrase file
Rotoblin already ships (`Roto2-AZ_mod.phrases`).

| Plugin | Version | Fix |
|---|---|---|
| `l4d_bossvote` | 1.5-survivorflow | A voted boss % means true survivor flow. The engine spawns at flow minus `versus_boss_buffer`, so `!voteboss 40` used to put the tank several % early. All 6 parse sites are patched (upstream's 2022 fix covered 2), and 0 still means "no boss". |
| `l4d_boss_percent` | 1.6.3 | Shows the same true-flow numbers as the patched boss vote. |
| `l4d_current_survivor_progress` | 2.3 | `!cur` uses the same true-flow numbers. |

Our `l4d2_skill_detect` (skeet assists with reports off) and `l4d_rock_lagcomp` (`OnTankRockSkeeted` forward) fixes were merged upstream in 2026-09: use Harry's `l4d2_skill_detect` 2.4h ([L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins/tree/master/l4d2_skill_detect)) and `l4d_rock_lagcomp` 1.14 ([Rotoblin-AZMod](https://github.com/fbef0102/Rotoblin-AZMod)).

## The witch corner fix

With `nb_update_frequency 0.014` (the default is 0.1), a startled witch can freeze
against a corner at full speed with her run animation still playing. Blood Harvest 3
(the fallen bridge railing) repeats it every time. The cause is in
`ZombieBotLocomotion::ResolveCollision` in server.so. Two "moved less than 1 unit,
give up" checks don't scale with the update interval, so at 0.014 each step is short
enough to trip them.

The plugin changes those two constants from 1 to 0 (`fld1` to `fldz`) only while
`WitchLocomotion::Update` runs, and puts them back right after, so common infected
never see the change. It checks the original bytes first and refuses to load if they
don't match. The offsets in the gamedata are for the **Linux L4D1** server binary only.

Recommended setup: corner fix plus `l4d_witch_unstuck` in mode 2. The corner fix
handles the engine bug, and unstuck covers geometry the fix can't (props wedged
against walls and the like).

Thanks to Harry for the `nb_update_frequency` tip that led to the root cause.

## Credits and license

The forks keep their original authors in the plugin info (Visor, ProdigySim, CanadaRox,
Tabun, zonde306, Luckylockm, Silvers, Harry and others). Everything is GPLv3, like
SourceMod.
