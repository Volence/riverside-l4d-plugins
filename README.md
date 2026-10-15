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
| `l4d_witch_unstuck` | 2.4.1 | left4dhooks | Fallback for a witch that makes no progress toward her target for 3 s: nudges her 8/16/24 units off the snag, then allows a short hop to a nearby nav spot (at most 120 units sideways, never when she is already within 120 units of her target). `!stuckwitch` logs a snapshot for admins. |
| `l4d_witch_fire_fix` | 1.0.0 | none | Map fire (fire barrels, burning cars) no longer sets the witch alight, so a startled witch keeps her target. Survivor molotovs and gas cans still burn her. See below. |
| `l4d_saferoom_lock` | 1.2 | left4dhooks | Holds the end saferoom door open and unusable while a tank or witch is still alive. |
| `l4d_skypounce` | 0.4.0 | | Stops hunters chaining pounces off the sky brush ("ceiling pouncing"). Mode 1 is Zen's rule, mode 2 a last-surface-touched rule. |
| `l4d_tank_burn_cap` | 1.0 | | Caps total fire damage on the tank so a molotov chips it instead of killing it. |
| `l4d_vote_lock` | 1.0 | | Makes `!load`, `!match`, `!mode`, `!changemap`, `!cm` and `!setscores` admin only. An admin override does nothing on commands registered with `RegConsoleCmd`, so this uses a command listener instead. |
| `l4d_hunter_phantom_fix` | 0.1 | | Stops a hunter killed mid-pounce from carrying on shredding (sound and claw blood at the pin spot) on clients after it dies. See below. |
| `l4d_tank_rules` | 1.3 | gamedata `l4d_tank_rules.txt` (Linux + Windows) | While a tank is alive: survivor distance points are frozen, and primary weapon swaps can be locked, limited to one per tank, or made to cost a full reload. See below. |
| `l4d_ledge_fix` | 1.0 | left4dhooks | Blocks ledge hangs over drops that could not hurt (a survivor hanging off a rock a few units above the floor). See below. |
| `l4d_fling_fall_fix` | 1.1 | | Stops survivors dying to "fell too far" from short drops after a tank punch: fall damage is taken from the speed gravity could give. See below. |
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
| `l4d_lagcomp_skeet` | 1.4-riverside3 | Actually runs on L4D1 (the attacker offset was the L4D2 one), no longer crashes the server when a skeet ends a pounce, and tells stat plugins about the skeets it rescues. Needs DHooks. See below. |

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

## Lag-compensated skeet on L4D1

Forgetest's `l4d_lagcomp_skeet` judges "was this hunter mid-pounce?" at the time the
shooter saw, so skeets count the same at any ping. Two problems on L4D1:

1. **It never ran.** The plugin hardcoded the damage info's attacker at offset 52, the
   L4D2 layout. On L4D1 offset 52 is `m_flBaseDamage` and the attacker is at 40, so the
   attacker check failed on every hit and the plugin did nothing. The offset now comes
   from gamedata (`CTakeDamageInfo::m_hAttacker`: 40 on L4D1, 52 on L4D2).
2. **With the offset fixed, it can crash srcds.** When the pounce interrupt damage runs
   out, the engine calls `OnPounceEnded()` (clears `m_isAttemptingToPounce`) and then
   damages the hunter again from inside the same `OnTakeDamageInternal`. The plugin's
   pre-hook ran on that nested call and set the flag back, so the engine went back into
   the pounce branch forever: about 7700 nested calls and a stack overflow (our match
   628, 2026-10-10). Fixes: a depth counter so only the outermost call is touched, the
   post hook restores the old value only if the engine left ours alone, a null usercmd
   skip (upstream issue #75), and the depth resets on map start.
3. **Stat plugins miss the skeets it rescues.** It sets the flag inside
   `OnTakeDamageInternal`, which runs after `TraceAttack`. `l4d2_skill_detect` reads the flag
   in `TraceAttack`, so a hunter the server had already landed but the shooter hit in the
   air read as "not pouncing". The engine interrupted the pounce (a real skeet) and
   skill_detect never counted it: 51 of 54 such skeets went uncounted on our servers
   over two days. The plugin now fires
   `forward void L4D_OnLagCompPounce(int hunter, int attacker, int pouncing)` with its
   decision. To fix skill_detect, implement that forward and set
   `g_fHunterTracePouncing[hunter] = pouncing ? GetEngineTime() : 0.0;`.

Reproduced with a human hunter on a test server: the old code crashed with the same log
flood, the fixed one logs one damage line and a normal kill. Both fixes must go together.

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

## The witch fire fix

A burning witch chases whoever set her on fire. Fire barrels and burning cars carry a
burn `trigger_hurt` that hurts NPCs too (spawnflags 67), so a startled witch that walks
or stalls on one catches fire, every burn tick is credited to the trigger instead of a
survivor, and she drops the survivor she was chasing and wanders. The Dead Air 3 barrel
by the garage (-4581 -903) is a spot she climbs.

The plugin drops burn damage to a witch unless a survivor dealt it, which also keeps her
from igniting. Molotovs and gas cans are unchanged: every tick of those is credited to
the survivor who lit her. On a test server with the Dead Air 3 barrel: stock, she burned,
wandered and died about 20 s later without reaching her target; with the fix she never
ignited and incapped her target in 7.6 s; lit by a survivor, she still burned and incapped
that survivor in 4.1 s. No gamedata, works on any OS.

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

The gamedata covers both L4D1 server binaries. On Linux it's the `jbe` at symbol plus
offset 208. On Windows the same check sits in a small store helper, found by signature,
where the `jne` at offset 19 gets the same `jmp`. The Windows site was read from the
`server.dll` in the Steam client (md5 8f67a2ce); a dedicated server on another build
just logs an error and runs with no-rush off.

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

## The fling fall fix

Fall damage only looks at how fast a survivor is moving down when they land:
((speed - `fall_speed_safe`) / (`fall_speed_fatal` - `fall_speed_safe`))^2 * 100, and
above `survivor_incap_max_fall_damage` (200) the survivor dies instead of being
incapped ("is dying instead of incapping because they fell too far"). A tank punch
throws a survivor sideways at about 1200 u/s. When that fling clips an overhang or a
sloped edge, the movement code redirects the speed along the surface and part of it
becomes downward speed in a single tick (we measured -510 to -727 u/s under the farm03
bridge and -88 to -856 u/s on the smalltown02 ditch edge). The landing then counts as
a 400+ unit fall and kills a survivor who dropped 100 to 250 units.

The plugin follows each airborne survivor's vertical speed every tick but never lets
it grow faster than gravity allows. On a fall damage hit it turns the game's damage
back into a landing speed; if that beats the gravity-only speed by more than
`l4d_fling_fall_fix_margin` (50 u/s), the damage is recomputed from the gravity-only
speed. Ordinary falls, where gravity is the only thing speeding you up, are never
changed. Tracking restarts while a smoker or hunter holds the survivor, so a tongue
pulling someone down keeps its real speed.

Cvars: `l4d_fling_fall_fix_enable` (0 off, 1 fix, 2 log only), `l4d_fling_fall_fix_log`
(1 writes every corrected fall to `logs/fling_fall_fix.log`), `l4d_fling_fall_fix_margin`.

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
