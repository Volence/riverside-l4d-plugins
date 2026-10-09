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
| `l4d_hunter_phantom_fix` | 0.1 | | Stops a hunter killed mid-pounce from carrying on shredding (sound and claw blood at the pin spot) on clients after it dies. See below. |
| `l4d_tank_rules` | 1.2 | gamedata `l4d_tank_rules.txt` (Linux only) | While a tank is alive: survivor distance points are frozen, and primary weapon swaps can be locked, limited to one per tank, or made to cost a full reload. See below. |
| `l4d_ledge_fix` | 1.0 | left4dhooks | Blocks ledge hangs over drops that could not hurt (a survivor hanging off a rock a few units above the floor). See below. |
| `l4d_ping` | 3.7 | | Overwatch-style team pings: one bound key marks whatever you aim at (infected, item, weapon or spot) for your own team only. See below. |

## Fixed forks of existing plugins

Drop-in replacements for the Rotoblin-AZMod versions. They use the phrase file
Rotoblin already ships (`Roto2-AZ_mod.phrases`), and build against the Rotoblin-AZMod
`scripting-az/include` folder (`l4d_lib`, `multicolors`, `collisionhook`).

| Plugin | Version | Fix |
|---|---|---|
| `l4d_bossvote` | 1.5-survivorflow-riverside1 | A voted boss % means true survivor flow. The engine spawns at flow minus `versus_boss_buffer`, so `!voteboss 40` used to put the tank several % early. All 6 parse sites are patched (upstream's 2022 fix covered 2), and 0 still means "no boss". |
| `l4d_boss_percent` | 1.6.3-riverside1 | Shows the same true-flow numbers as the patched boss vote. |
| `l4d_current_survivor_progress` | 2.3-riverside2 | `!cur` uses the same true-flow numbers. |
| `l4d_collision_adjustments` | 1.2h-riverside2 | A hunter aimed at a downed survivor now lands on him. Needs the CollisionHook extension. See below. |
| `l4d_tankpunchstuckfix` | 0.6-riverside2 | A survivor a tank punch leaves inside the ceiling or a wall is put back where he really was. Needs left4dhooks. See below. |

Our `l4d2_skill_detect` (skeet assists with reports off) and `l4d_rock_lagcomp` (`OnTankRockSkeeted` forward) fixes were merged upstream in 2026-09: use Harry's `l4d2_skill_detect` 2.4h ([L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins/tree/master/l4d2_skill_detect)) and `l4d_rock_lagcomp` 1.14 ([Rotoblin-AZMod](https://github.com/fbef0102/Rotoblin-AZMod)).

## The hunter pounce on a downed survivor

`l4d_collision_adjustments_hunter_incap 1` turns off hunter collision with downed
survivors for the first 0.09 s of every pounce, so a hunter pouncing someone else isn't
grabbed by a downed survivor on the way. From about 40 units that window covers the whole
flight, so a hunter standing next to a downed survivor could never pounce him.

The fork adds `l4d_collision_adjustments_hunter_incap_aim` (default 60). When the pounce
starts, the survivor closest to the hunter's crosshair (within that many degrees) keeps
his collision if he is downed, so an aimed pounce lands. Downed survivors he isn't aimed
at are still passed through. 0 brings back the old behaviour.

## The tank punch ceiling stuck

A tank punch is checked against where the survivor was a moment ago on the tank
player's screen (lag compensation). In L4D1, a jumping survivor uses the crouched hull
in the air. If the punch rewinds a survivor who has just landed to a point mid-jump, the
punch lifts him 18 units there (crouched, so it fits). The engine then gives him back his
standing hull and tries to move him to his real spot plus that lift. Under a low ceiling
both of its restore traces start inside the world, so it gives up and leaves him standing
inside the ceiling. Seen on Dead Air 4 (the counter under the low ceiling near the
terminal windows), and reproduced on a test server: 4 stuck in 29 punches before the fix,
0 in 38 after.

Upstream's version of this plugin has its unstick code commented out and only toggles
`sv_lagcompensationforcerestore`, which doesn't cover this case. The fork records every
survivor's real position before each swing, and after the swing (once lag compensation
has restored everyone) hull-checks each survivor it hit. Anyone inside the world goes back
to his real position with his knockback kept, and is re-checked for 1 s, with
`L4D_WarpToValidPositionIfStuck` as the last resort. `sm_punchstuckfix_solid 0` turns it
off. Every rescue is logged to `logs/tank_punch_stuck.log`.

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

## The hunter phantom shred fix

Sometimes a hunter killed while it shreds a pinned survivor keeps shredding on clients:
the pounce hit sounds and claw blood carry on at the pin spot for up to 8 s after it dies,
and survivors think their teammate is still capped.

Both effects are client-side animation events in the hunter's `Melee_Pounce` sequence (a
10 s clip). Players are animated client-side, and a client stops updating a dead player's
animation state, so under packet loss or reordering the client can freeze the dead
hunter in `Melee_Pounce` and play out the rest of the clip on its (invisible) player
entity. The ragdoll is not involved.

The plugin swaps the dead hunter's model for a moment and then puts it back. A model
change makes every client rebuild the entity's animation, which drops the frozen
sequence. The swap waits 0.2 s after death so clients have already built the ragdoll
from the hunter model, and it only touches hunters that pounced within the last 11 s.

How we measured it: a client on a server with 50 ms (+-10) lag and 2% loss, logging
`snd_dumpclientsounds` (no cheats needed) and counting a phantom whenever the dead
hunter's own entity started new `zombie_slice` sounds at its death spot 0.8 s or more
after its death cry. Fix on vs off on alternating deaths: 0 phantoms in 195 mid-shred
deaths with the swap, 12 in 187 without. A SourceTV demo (no loss) showed none.

Cvars: `l4d_hunter_phantom_fix_enable` (1), `l4d_hunter_phantom_fix_delay` (0.2),
`l4d_hunter_phantom_fix_hold` (1.0). `sm_phantomfix_stats` prints the swap count.

## Tank rules

**No rush** (`l4d_tank_rules_rush`, default 1). Survivors can't earn distance points
while a tank is alive, so a team can't run ahead to bank distance and then die. Their
score after the tank dies is the frozen mark or wherever they are when it dies,
whichever is further. Movement itself is never blocked.

In server.so, `CTerrorGameRules::RecomputeTeamScores` calls
`ForEachTerrorPlayer<CalcAndSetVersusMaxFlowDistance>`. For each survivor it compares
their current flow with their stored furthest flow (a float at `CTerrorPlayer+0x2b74`)
and raises the stored value if the current one is higher. The team's
`m_iVersusDistance` is computed from the stored values. At offset 0xD0 in that
function, `76 20` (`jbe`) is "not past it, keep the stored value". While a tank lives
the plugin changes that byte to `EB` (`jmp`), so the stored flow never goes up. When
the tank dies it writes `76` back. Clamping the float from SourcePawn instead doesn't
work: the engine raises it and computes the team score in the same call, so a clamp is
always one recompute late, and the late one can be the round-ending one.

Details:
- The byte is always restored on round start, map end, plugin unload, and when the
  cvar is turned off.
- From round_end to the next round_start the freeze is left alone. Incapped survivors
  still count as alive to the engine, so one lying past the mark would be paid for it.
- If the tank dies while nobody is standing (a wipe in progress), the freeze holds until
  someone gets up or the next round starts.
- On load the plugin checks the jump's operand and the store it skips. If the bytes
  don't match (a different engine build), no-rush stays off and the weapon rules still
  work.

The gamedata is for the **Linux L4D1** server binary (symbol plus offset 208). A
Windows server needs its own signature for the same `jbe` in server.dll.

**Weapon swaps** (`l4d_tank_rules_weapons`, default 0). While a tank is alive:
1 = nobody may pick up a different primary, 2 = only one survivor may, once per tank,
3 = swaps are allowed but the new gun starts with an empty clip (rounds go to the
reserve), so a swap costs a full reload. We run mode 3.

`sm_tankrules_status` (admin) prints the patch state.

## The ledge fix

The game only lets a survivor grab a ledge when it predicts the fall would do at least
1 damage. That estimate (`CTerrorPlayer::EstimateFallingDamage`) simulates the fall in
0.1 s steps, at most 30, and only counts a step as landing on a plane with
normal.z > 0.7. On a steep rock face or rough terrain it slides along the surface, can
run out of steps while still "falling", and reports a painful fall for a drop of a few
units. The survivor then hangs off a rock that is barely above the floor.

The plugin re-checks every grab (`L4D_OnLedgeGrabbed`) with a plain hull trace down.
If the landing speed, sqrt(vz^2 + 2 * g * drop), is at or below the game's `fall_speed_safe`, the
fall is harmless and the grab is blocked, so the survivor just drops. A floor too steep
to stand on is followed downhill to where the survivor would come to rest, so a slope
into a real pit still counts as the full drop. A grab over a real drop passes.

Cvars: `l4d_ledge_fix_enable` (0 off, 1 block, 2 log only), `l4d_ledge_fix_log`
(1 writes every judged grab to `logs/ledge_fix.log`).

## Ping

Each player binds a key (`bind mouse3 sm_ping`, or type `!ping`). The server can't push
binds, so the plugin tells each player once per connect how to bind it
(`l4d_ping_hint`). The ping is classified automatically: special infected or witch
(red), weapon, item, or location. Only your own team sees your pings and hears the
cue. Each player has one ping at a time, and it lasts `l4d_ping_lifetime` (6 s).

The marker is an `env_sprite` with an `$ignorez` material, one per teammate, each
scaled to that viewer's distance so it stays about the same size on screen. L4D1 has no
glow or instructor hint that works for this, so markers show through most walls but
can be culled across some map areas.

Main cvars: `l4d_ping_enable`, `l4d_ping_lifetime`, `l4d_ping_cooldown`,
`l4d_ping_teams` (0 both teams, 1 survivors only), `l4d_ping_aim_assist` (cone in
degrees), `l4d_ping_assist_infected` (0 = survivor aim-assist doesn't snap onto
infected), `l4d_ping_follow` (0 = an enemy ping stays where the infected was),
`l4d_ping_size`, `l4d_ping_sound`, `l4d_ping_chat`. The plugin writes the full list
to `cfg/sourcemod/l4d_ping.cfg`.

Other plugins can use `scripting/include/l4d_ping.inc`: `L4DPing_Create` drops a ping
for a player, and `L4DPing_OnPing` fires after every ping.

## Credits and license

The forks keep their original authors in the plugin info (Visor, ProdigySim, CanadaRox,
Tabun, zonde306, Luckylockm, Silvers, Harry and others). Everything is GPLv3, like
SourceMod.
