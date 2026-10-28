# Riverside L4D1 plugins

SourceMod plugins from the Riverside PUG servers (Left 4 Dead 1 versus, Rotoblin-AZMod,
100 tick, Linux). Everything here runs live on our servers, except where the table says
"not live yet".

The folders mirror a server install: copy `addons/` and `cfg/` into `left4dead/`.
Each plugin ships as source (`addons/sourcemod/scripting`) and compiled
(`addons/sourcemod/plugins`, SourceMod 1.11+).

## Our plugins

| Plugin | Version | Needs | What it does |
|---|---|---|---|
| `l4d_witch_fixes` | 1.3.0 | DHooks, gamedata `l4d_witch_fixes.txt` (Linux + Windows) | The witch's movement fixes in one plugin: she no longer freezes on corners at a low `nb_update_frequency`, no longer cuts straight at a survivor over a pit or open air, no longer climbs and slides off the same prop or rounded ledge forever, map fire no longer steals her target, a special infected bumping her no longer becomes her victim, and a dying common under her feet no longer flings her into the air. Replaces `l4d_witch_corner_fix`, `l4d_witch_direct_fix` and `l4d_witch_fire_fix`. See below. |
| `l4d_witch_unstuck` | 2.5.0 | left4dhooks, gamedata `l4d_witch_unstuck.txt` (Linux) | Fallback for a witch that makes no progress toward her target for 3 s: nudges her 8/16/24 units off the snag, then allows a short hop to a nearby nav spot (at most 120 units sideways, never when she is already within 120 units of her target). `!stuckwitch` logs a snapshot for admins. 2.5.0: never moves her off someone she is killing (a survivor who body-blocks her twice silently becomes her victim), and a witch set off by a smoker, lunging hunter or tank is tracked toward the survivor that player is moving, as the game does. |
| `l4d_saferoom_lock` | 1.2 | left4dhooks | Holds the end saferoom door open and unusable while a tank or witch is still alive. |
| `l4d_skypounce` | 0.4.0 | | Stops hunters chaining pounces off the sky brush ("ceiling pouncing"). Mode 1 is Zen's rule, mode 2 a last-surface-touched rule. |
| `l4d_tank_burn_cap` | 1.0 | | Caps total fire damage on the tank so a molotov chips it instead of killing it. |
| `l4d_vote_lock` | 1.0 | | Makes `!load`, `!match`, `!mode`, `!changemap`, `!cm` and `!setscores` admin only. An admin override does nothing on commands registered with `RegConsoleCmd`, so this uses a command listener instead. |
| `l4d_hunter_phantom_fix` | 0.2 | | Stops a hunter killed mid-pounce from carrying on shredding (sound and claw blood at the pin spot) on clients after it dies. See below. |
| `l4d_tank_rules` | 1.3.1 | gamedata `l4d_tank_rules.txt` (Linux + Windows) | While a tank is alive: survivor distance points are frozen, and primary weapon swaps can be locked, limited to one per tank, or made to cost a full reload. See below. |
| `l4d_ledge_fix` | 1.1 | left4dhooks, gamedata `l4d_ledge_fix.txt` | Blocks ledge hangs over drops that could not hurt (a survivor hanging off a rock a few units above the floor). See below. |
| `l4d_fling_fall_fix` | 1.3 | | Stops survivors dying to "fell too far" from short drops after a tank punch: fall damage is taken from the speed gravity could give. See below. |
| `l4d_ping` | 3.7 | | Overwatch-style team pings: one bound key marks whatever you aim at (infected, item, weapon or spot) for your own team only. See below. |
| `l4d_tank_punch_lagcomp` | 1.1 | DHooks, gamedata `l4d_tank_punch_lagcomp.txt` | A human tank's punch is lag compensated whether M1 is tapped or held. Stock only rewinds survivors while attack is held, and the fist is tested 0.5 to 0.7 s after the click. See below. |
| `l4d_tank_punch_wall_fix` | 1.1 | DHooks, gamedata `l4d_tank_punch_wall_fix.txt` | A tank punch can no longer hit a survivor through a wall when something (a ladder, door, prop, common) stands in front of the wall. See below. |
| `l4d_pounce_land_fix` | 1.0 | gamedata `l4d_pounce_land_fix.txt` (Linux) | A hunter whose pounce lands on a survivor's head can no longer start a second pounce before the pin goes through, which lost the pin or reset its damage to 1. See below. |
| `l4d_physenv_teardown_fix` | 1.0 | gamedata `l4d_physenv_teardown_fix.txt` (Linux + Windows) | Closes a rare crash in vphysics at a level change (a use-after-free while the physics world is torn down). Any map can in theory hit it; we have not seen it on our live servers. See below. |
| `l4d_tank_fair_punch` | 0.4.0 | DHooks, gamedata `l4d_tank_fair_punch.txt` | The windup-end target scan follows the fist: no free hit on a survivor the fist never came near, and a hit for one the fist visibly went through at the end of the windup. See below. |
| `l4d_rock_double_fix` | 1.0 | DHooks, gamedata `l4d_rock_double_fix.txt` | One tank rock can no longer hurt a survivor twice in the same tick. See below. |
| `l4d_tongue_target` | 0.3 | DHooks, gamedata `l4d_tongue_target.txt` | When the smoker's crosshair is on several survivors, the nearest one gets the tongue (stock picks by client order), and survivors are judged where the smoker saw them. See below. |
| `l4d_tank_pass_fix` | 0.1 | left4dhooks | A passed tank no longer bounces to a third player 3 s later. About one human pass in ten, the old tank's offer fires a second lottery at the handoff; an offer for a human tank within one lottery of the last is that duplicate and is blocked. Every offer is logged to `logs/tank_pass_fix.log` (`l4d_tank_pass_fix 0` logs only). |
| `l4d_hittable_desync_fix` | 1.1 | DHooks, gamedata `l4d_hittable_desync_fix.txt` (Linux) | Cars and other hittables stay where the server has them on every client, not only on clients running low violence. See below. |
| `l4d_tank_reconnect` | 0.2 | left4dhooks (its `left4dhooks.l4d1.txt` gamedata) | A tank whose player drops gets the tank back on rejoin, with the same health, rage, rage grace timer, burning state and pass count, through the game's own bot handoff (`CTerrorPlayer::TakeOverZombieBot`). Works during a pause. |
| `l4d_dead_bot_sweep` | 0.1-riverside1 | | Kicks dead infected bots that a pause kept alive, so they can't fill the infected team when the tank spawns (the tank bot was kicked for "infected team is full"). |
| `l4d_nightmode` | 0.9-riverside2 | DHooks, gamedata `l4d_nightmode.txt`, `configs/l4d_nightmode.cfg` | Turns daytime maps into night at runtime, no BSP changes: lighting, exposure, fog, lamps and per-map looks from the config. See below. |
| `l4d_hide_viewmodel` | 1.3 | clientprefs, sdkhooks | `!noviewmodel` hides your own first-person gun and arms while the HUD (ammo, items) stays. `!noviewmodel 2` hides only your main weapon. Survivors only; infected keep their claws. Pills still show while you hold them. The choice is saved per player. See below. |
| `l4d_rcon_abort_fix` | 1.0 | DHooks, gamedata `l4d_rcon_abort_fix.games.txt` (Linux) | An RCON connection closing no longer strands another connection's command: no more "rcon exec timeout" when two rcon tools share a server, and no command running twice. Engine bug, see below. |
| `l4d_rcon_password_fix` | 1.0 | DHooks, gamedata `l4d_rcon_password_fix.games.txt` (Linux) | Setting `rcon_password` to the value it already has (every map change, if a cfg sets it) no longer closes every RCON connection. A real change still does. See below. |
| `l4d_onslaught_tank_pause` | 1.0 | | For converted L4D2 maps whose onslaughts (a horde that keeps coming until a button is pressed) are rebuilt with `director_panic_forever` by relays named `l4d1_onslaught_on` / `l4d1_onslaught_off`: while any tank is alive the endless horde is held off, and when the last tank dies it comes back with a fresh panic, unless the button was pressed meanwhile. See below. |

## Fixed forks of existing plugins

Drop-in replacements for the Rotoblin-AZMod versions. They use the phrase file
Rotoblin already ships (`Roto2-AZ_mod.phrases`), and build against the Rotoblin-AZMod
`scripting-az/include` folder (`l4d_lib`, `multicolors`, `collisionhook`).

| Plugin | Version | Fix |
|---|---|---|
| `l4d_bossvote` | 1.5-survivorflow-riverside1 | A voted boss % means true survivor flow. The engine spawns at flow minus `versus_boss_buffer`, so `!voteboss 40` used to put the tank several % early. All 6 parse sites are patched (upstream's 2022 fix covered 2), and 0 still means "no boss". |
| `l4d_boss_percent` | 1.6.3-riverside1 | Shows the same true-flow numbers as the patched boss vote. |
| `l4d_current_survivor_progress` | 2.3-riverside2 | `!cur` uses the same true-flow numbers. |
| `l4d_collision_adjustments` | 1.3h-riverside1 | Upstream 1.3h (commons walk through weapons and items, survivors don't snag on infected ladders, and a hunter only passes through a downed survivor his hull already overlaps when the pounce starts, so an aimed pounce lands). riverside1: the hunter pass-through only applies to the hunter's own movement, so a downed survivor's shots still hit a pouncing hunter. Needs the CollisionHook extension, DHooks and the `l4d_no_m2_movement_block.txt` gamedata. See below. |
| `l4d_tankpunchstuckfix` | 0.6-riverside6 | A survivor a tank punch leaves inside the ceiling or a wall is put back where he really was. Needs left4dhooks. See below. |
| `l4d_infected_collisions` | riverside2 | Forgetest's plugin with one cvar per mover (riverside2: the witch setting now really applies to her, by detouring `ZombieBotLocomotion::DetectCollision`; `sm_infcoll_stats`): `l4d_infected_collisions_common` (1) lets commons walk through a pulled, choked or pounced survivor, `l4d_infected_collisions_witch` (0) keeps the witch colliding with him. Needs DHooks, gamedata `l4d_infected_collisions.txt`, and Forgetest's `gamedatawrapper` include. |
| `l4d_lagcomp_skeet` | 1.4-riverside4 | Actually runs on L4D1 (the attacker offset was the L4D2 one), no longer crashes the server when a skeet ends a pounce, and tells stat plugins about the skeets it rescues. riverside4: a lunging hunter shot where the shooter saw him before the lunge takes stock skeet damage (it used to be stunned for 0.5 s instead). Needs DHooks. See below. |
| `l4dcompstats` | 1.0h-riverside4 | The `[TS]` skeet chat line only counts a hunter that was really in the air: one hit on the ground or a ladder is no longer a skeet (riverside3, the check runs before the damage, since by `player_death` the ground flag is already gone). riverside4: when `l4d_lagcomp_skeet` ruled on the killing shot, its answer wins, so a skeet it rescues prints in chat as well as counting in skill_detect. See below. |
| `l4d_rock_lagcomp` | 1.14-riverside4 | Rock godframes count from the release, not the rock's creation (the tank holds it 1.2 to 1.7 s depending on the throw, so the old 1.7 s gave 0 to 0.5 s of real protection); default 0.2 s on every throw. A killing shot detonates inside that shot's usercmd, so the rock cannot still hit someone that tick; finale miniguns and .50 cals can destroy rocks again. |
| `l4d_no_m2_movement_block` | 2.0-riverside2 | Forgetest's free movement while scratching. riverside2: plays the infected scratch growl (`*Zombie.Attack`) that the game no longer sees because of the zeroed claw timer, at the game's 0.2 s rate (`l4d_no_m2_movement_block_growl`, 1 on). Needs DHooks, gamedata `l4d_no_m2_movement_block.txt` and `l4d_no_m2_sounds.txt`. |
| `l4d_fix_common_shove` | 1.4.1-riverside2 | Forgetest's common shove fix, with the L4D1 falling activity, and a common is only skipped while it is falling AND off the ground (a grounded common stuck in the fall activity no longer stays frozen). |
| `l4d_versus_rescue_door_fix` | 1.0-riverside2 | The rescue door unlock is written to the networked `m_bLocked`, so clients see it. |
| `checkpoint-rage-control` | riverside2 | The "tank still loses rage" notice hooks the event the game really fires (`player_entered_checkpoint`) and checks the tank class (5 on L4D1). |
| `l4d_QuadCaps` | 1.5-riverside7 | Boomer dies last: the next wave is a quad (90% 3 hunters + smoker, 10% 4 hunters). Smoker dies last: hunters + exactly one boomer, played by the smoker's player, never a quad (`sm_dirty_after_smoker`). Hunter dies last: stock classes, but never a quad: if the wave's last ghost finds no boomer on the team, it becomes the boomer (`sm_noquad_after_hunter`). Any next SI death ends the rule. Also fixes upstream's `z_versus_boomer_limit 0` left behind by a boomer killed between halves. |
| `l4d2_witch_crown_fix` | 1.2-riverside1 | A pump blast the fix counts as a crown now always kills. The old top-up to exactly `z_witch_health` could leave her on 1 HP. See below. |

Our `l4d2_skill_detect` (skeet assists with reports off) and `l4d_rock_lagcomp` (`OnTankRockSkeeted` forward) fixes were merged upstream in 2026-09: use Harry's `l4d2_skill_detect` 2.4h ([L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins/tree/master/l4d2_skill_detect)). `l4d_rock_lagcomp` is back above with newer fixes (riverside4).

## The hunter pounce on a downed survivor

Up to 1.2h, `l4d_collision_adjustments_hunter_incap 1` turned off hunter collision with
downed survivors for the first 0.09 s of every pounce. From about 40 units that window
covers the whole flight, so a hunter standing next to a downed survivor could never pounce
him. Our 1.2h forks added an aim rule for it.

Upstream 1.3h fixes it differently: when the pounce starts, only a downed survivor whose
hull already overlaps the hunter's is passed through (for 0.5 s, so he can get out of him).
Everyone else keeps normal collision, so an aimed pounce lands, and the aim rule (and its
`_aim` cvar) is gone. On our test rig 1.3h landed 6 of 6 in every aimed case, including
a hunter standing on a downed survivor and aimed at the reviver.

The 1.3h rule lives in the collision callback, which also sees bullet traces. Our gate
(riverside1 of this version) limits it to the hunter's own movement, so a downed survivor
can still shoot a hunter that overlaps him.

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

Later fixes: the watch on a survivor ends when he disconnects, is pinned or the map
changes (riverside3); debris such as hanging plants no longer counts as stuck, and each
punch moves a survivor at most once of each kind, because looping the move every tick
froze one survivor in the air until he took fall damage (riverside4); commons and the
witch no longer count as stuck geometry (riverside5); the stuck check uses the mask a
survivor really moves with (0x14a0b), so survivor-only invisible walls count too (riverside6).

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

`l4dcompstats` (the `[TS] You skeeted ...` chat line) had the same gap. Its ground check
runs in `OnTakeDamage` pre, before lagcomp's detour, so a hunter the server had landed
between pellets printed nothing while skill_detect counted the skeet. riverside4
implements the same forward and, when lagcomp ruled on the killing damage that tick,
uses its answer at `player_death`. Without lagcomp it behaves as before.

## The witch fixes

`l4d_witch_fixes` holds six fixes for how a startled witch moves. Each has its own on/off cvar
that works live (`l4d_witch_fixes_corner`, `_direct`, `_climb`, `_fire`, `_victim`, `_launch`, all 1 by default), and each
checks its own hooks when the plugin loads: on Linux every vtable slot it hooks is compared with
the function the server's symbols say should be there, and on Windows the patched bytes are
checked. A fix that finds a mismatch (a game update moved something) turns only itself off and
logs which one, so the others keep working. `l4d_witch_fixes_log 1` logs every change a fix makes.

It replaces three separate plugins: remove `l4d_witch_corner_fix`, `l4d_witch_direct_fix` and
`l4d_witch_fire_fix` (and their gamedata) when you install it, or the witch is hooked twice.

Recommended setup: `l4d_witch_fixes` plus `l4d_witch_unstuck` in mode 2. These fixes remove the
causes we have found, and unstuck catches whatever is left (and its log is how we find the next one).

### Corners

With `nb_update_frequency 0.014` (the default is 0.1), a startled witch can freeze
against a corner at full speed with her run animation still playing. Blood Harvest 3
(the fallen bridge railing) repeats it every time. The cause is in
`ZombieBotLocomotion::ResolveCollision` in server.so. Two "moved less than 1 unit,
give up" checks don't scale with the update interval: at 0.014 her slide along a wall is
about 0.05 units per step, so every step is thrown away.

The plugin changes those two constants from 1 to 0 (`fld1` to `fldz`) only while
`WitchLocomotion::Update` runs, and puts them back right after, so common infected
never see the change. On Windows the two checks compare against a shared 1.0 constant
(`fcomp [1.0f]; fnstsw; test ah,5; jnp`), so instead of the constant the plugin flips each
`jnp` to `jo`, which is never taken after a `test`.

Thanks to Harry for the `nb_update_frequency` tip that led to the root cause.

### Straight-line cuts over gaps

While she chases, the witch drops her nav path and runs straight at her victim whenever
no climb or gap jump is coming up on the path and `ILocomotion::IsPotentiallyTraversable`
says the straight line from her feet to the victim is clear. That check is a hull trace
plus the 180 unit jump height limit. It never asks whether there is any floor under the
line. So with a survivor up on a ledge and the witch walking up a ramp below them, the
line goes through open air over the pit and passes. She turns off her path toward them,
drops back below the ledge, loses the line, picks the path up again, climbs the ramp and
does it again. In our replays that pacing made chases 3 to 6 times longer than the walk.

The fix hooks that check on each witch's own locomotion object. When the game says yes to a
line at least `l4d_witch_fixes_direct_minlen` (96) units long, it traces down every
`l4d_witch_fixes_direct_step` (24) units along it. If the floor anywhere drops more than
`l4d_witch_fixes_direct_drop` (48) units below both the line and the victim's height, the
answer becomes no and she keeps following her path. A clean drop down to a victim below
her still passes. Shorter lines are left alone: those are the path follower's own
look-ahead probes at ledge edges. On a test server, Death Toll 4 (survivor on the ledge
above the crater) went from 18 s to 6 s, and Blood Harvest 2 (the tilted train car) from
17 s to 6 s.

### Failed climbs

The path follower climbs whatever its path runs into. That includes physics props the nav
mesh knows nothing about (`Infected::IsAbleToClimbOnto` says yes to any walkable entity that
is not a player or a door), and climb animations always end on a ledge's front lip, which on
a rounded top is too steep to stand on. Either way she slides back off and starts the same
climb again, for as long as nobody shoots her: on Dead Air 3 by the garage she did it 48
times in 30 s. A new climb to the same landing spot from the same place within 3 s means the
last one failed, and then:

- onto a prop or other entity: that climb is refused before it starts, and the object is off
  limits to her for `l4d_witch_fixes_climb_ban` (15) seconds, so she goes round it;
- onto the map itself: the next climb there is watched, and when she reaches the lip she is
  slid over 4 frames onto the first spot she can stand on, up to `l4d_witch_fixes_climb_assist`
  (48) units ahead (floor no steeper than about 45 degrees, room for her hull). If there is no
  such spot nothing moves.

Climbs that work are never touched. On the Dead Air 3 garage spot she now reaches the survivor
in about 8 s; without the fix she never does.

### Map fire

A burning witch chases whoever set her on fire. Fire barrels and burning cars carry a
burn `trigger_hurt` that hurts NPCs too (spawnflags 67), so a startled witch that walks
or stalls on one catches fire, every burn tick is credited to the trigger instead of a
survivor, and she drops the survivor she was chasing and wanders. The fix drops burn damage
to a witch unless a survivor dealt it or it comes from her own flame (lit by a survivor who
has since left), which also keeps map fire from igniting her. Molotovs and gas cans are
unchanged.

### Infected victims

A startled witch takes a new victim from whoever bumps into her twice
(`WitchAttack::OnContact` calls `WitchAttack::SetVictim`, `z_witch_allow_change_victim`), and
that includes special infected: a hunter landing on her makes the hunter her victim and she
drops the survivor she was after. Once she has a victim, a switch to an infected player is
refused. A survivor who gets in her way can still become her victim, and her first victim is
never touched.

### Launches

`ZombieBotLocomotion::Update` sets the witch's velocity to how far she really moved over the
update. The sideways part is capped at run speed, the upward part is not. So when collision
handling lifts her a few units (onto a common that has just died: its body stays solid for 2
to 3 s), the lift becomes an upward speed of lift / update interval. At `nb_update_frequency
0.014` that is about 700 units/s, and she flies up to 300 units into the air and lands on her
victim. At the default 0.1 the same lift is a small hop. After each of her updates the fix
zeroes an upward speed above `l4d_witch_fixes_launch_max` (150) unless she is climbing. Her
position is never touched, so stairs and climbs move as before. On a test server with a common
killed in her path, she launched in 5 of 80 runs without the fix (also with no plugins at all)
and 0 of 60 with it.

### Windows

All six fixes run on Windows. The first four have since 1.1.0; victim and launch need the
gamedata from 2026-10-26 or later (the 1.3.0 plugin itself is unchanged, so updating
`l4d_witch_fixes.txt` is enough). Every hooked vtable slot is checked at load against
the function it must hold, found by a unique signature in server.dll (on Linux, by symbol), and
the climb fix also checks each witch's INextBot table. Windows layout: WitchLocomotion slots
Update 36, IsPotentiallyTraversable 82, ClimbUpToLedge 41; INextBot IsAbleToClimbOnto 51; the
witch's INextBot at +2204 and her locomotion at +0xD78. Victim: `WitchAttack::SetVictim`
(thiscall, one argument) by signature, the victim handle at +0x34 as on Linux. Launch:
WitchLocomotion slot 44 `IsClimbingOrJumping` (checked against its signature), the velocity at
+0x60 and the ground handle at +0xB8 as on Linux. All of that was verified against the
current server.dll, but none of it has been run on a Windows server yet: if a check fails, that
fix stays off and the log says which one, so please send us the log line.

1.1.1: with two or more witches alive, 1.1.0 logged "INextBot slot 51 is not
Infected::IsAbleToClimbOnto" for every witch after the first and left her without the climb fix
(the first witch's hook puts a DHooks trampoline in the shared slot). Thanks to Harry for the
report; it happened on Linux too (slot 52). 1.1.1 checks the table once and hooks every witch.

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

1.2: only real landings are judged (the game credits them to the world), so map death
pits, which are `trigger_hurt` volumes doing fall damage, still kill. Falls are judged by
their peak gravity-limited speed, which can only make the plugin step in less often.

1.3: on long falls the tick-by-tick tracker read only 0.6 to 0.85 of the real landing speed,
so 1.2 softened ordinary falls, real deaths included. The gravity-only speed now also has a
floor from energy, v^2 = vz0^2 + 2g(z0 - z) from where the airborne stretch began, so a fall
gravity alone explains is never changed. Replayed over four days of logged falls: every
phantom short fall (20 units at 600+ u/s) is still fixed and every real fall is left alone.

Cvars: `l4d_fling_fall_fix_enable` (0 off, 1 fix, 2 log only), `l4d_fling_fall_fix_log`
(1 writes every corrected fall to `logs/fling_fall_fix.log`), `l4d_fling_fall_fix_margin`.

## The hittable desync fix

The client keeps its own physics copy of every networked `prop_physics` and draws the prop
where that copy is: physics runs after interpolation each frame and moves the prop onto it.
Dead commons become client-only ragdolls in `COLLISION_GROUP_DEBRIS`, which collide with a
prop in `COLLISION_GROUP_NONE`. Bodies pinned under or against a punched car hold the drawn
car back while the real one keeps going, so it shows short of, or floating above, where it
really is. Low violence (`-lv`) hides this because corpses are removed straight away.

The plugin puts every hittable (the props with `m_hasTankGlow`) in collision group 19
(`NPC_SCRIPTED`) when it spawns. In the game's collision rules 19 behaves like NONE against
everything except groups 1, 2, 14 and 16, so survivors, infected, the tank, rocks and other
props hit it as before. The tank's punch search (`IsPushableEntity`) wants NONE, so a detour
answers it as if the prop were still NONE. The group is only set at spawn, never changed
mid-game: clients do not recheck their physics contacts when a group changes. The cvar
`l4d_hittable_desync_fix` (1) and a late load therefore only affect props spawned afterwards.
`sm_hittable_fix_status` lists what was moved.

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

## Tank punch lag compensation

Each sweep of a tank's fist (once per usercmd for `tank_swing_duration`, 0.2 s, after
the 0.5 s windup) starts lag compensation. Before rewinding a survivor, the game asks
`CTerrorPlayer::WantsLagCompensationOnEntity`, which says yes only if the usercmd holds
attack, or its command number is within 5 of the player's `m_iLastWeaponFireUsercmd`.
Guns and melee weapons write that field; the tank's claw never does. So a tank who taps
M1 has already let go when the fist is tested, and the punch is checked against where
survivors are on the server now, not where the tank player saw them. Holding M1 through
the swing got normal lag compensation.

From the end of the windup to the end of the swing, the plugin keeps the tank's
`m_iLastWeaponFireUsercmd` at his current command number, which opens the game's own
check. The game's other checks and the rewind itself run as usual. Only lag
compensation reads that field, and its old value is put back when the swing ends, so
rock throws and everything else are untouched. Bot tanks are never lag compensated by
the game and are left alone. Measured on a test server with a real client as the tank
and four survivors in front, survivor checks rewound per 10 punches:

| | Tapped M1 | Held M1 |
|---|---|---|
| Without the plugin | 0 of 360 | 299 of 324 (9 punches) |
| With the plugin | 347 of 360 | 343 of 360 |

The checks that still say no (with or without the plugin) come from the game's own
checks, not from attack being held.

Cvars: `l4d_tank_punch_lagcomp_enable`, `l4d_tank_punch_lagcomp_debug` (1 writes a line
per punch to `logs/tank_punch_lagcomp.log`). `sm_punchlagcomp_stats` prints totals. The
field's offset (Linux 6124) is in the gamedata.

## Tank punch wall fix

In versus, `CTankClaw::SweepFist` only lets a punch hit a survivor if a line from the
tank's eye to the fist at contact does not hit the world. The test is
`CGameTrace::DidHitWorld()`, which only asks whether the FIRST thing on that line is the
world. When any other entity sits between the eye and the wall, the line stops on it,
the test passes, and the punch lands through the wall behind it. The fist itself is
often already past a thin wall (the windup seed is eye + forward * 56, and the arm
reaches through), so the sweep never touches the wall either.

Found in a live match on `l4d_vs_farm01_hilltop`: a tank climbing the infected ladder on
the outside of the farmhouse's west wall punched a survivor standing inside. The ladder
(`func_simpleladder`, brush contents `0x30000008`) is hit because `CONTENTS_GRATE` is in
the punch trace mask. On a test server, calling the game's own `SweepFist` with the tank
behind that ladder: the stock line stopped on the ladder and the survivor took 24; the
same spacing beside the ladder stopped on the wall and nothing was hit.

The plugin hooks `CTankClaw::OnHit` during a fist sweep and redoes the game's line (eye to
the trace's end position) against the world only, ignoring every entity. If the world
is in the way, the hit is dropped. Punches with a clear line are untouched, and so are
ground pounds, which call `OnHit` themselves.

1.1: only a punch's first hit on a survivor is judged (repeat touches in the same swing do
no damage), and a hit is left alone when the game's line, entities included, reaches the
survivor before anything else. In 1.0 the line ran on to the fist's centre past the
survivor and found walls behind them.

Cvars: `l4d_tank_punch_wall_fix_enable` (0 off, 1 fix, 2 log only),
`l4d_tank_punch_wall_fix_log` (1 writes every dropped hit to
`logs/tank_punch_wall_fix.log`, with the entity that fooled the stock check).

## Pounce land fix

A pounce never pins on contact. When a lunging hunter touches a survivor
(`CLunge::HandleCustomCollision`) or lands on top of one
(`CTerrorGameMovement::SetGroundEntity`), the game calls `CTerrorPlayer::OnLungedInto`,
which only queues the pin on the survivor: a pending attacker and a due time of now +
`z_pounce_delay`. `CTerrorPlayer::UpdatePounce`, in the survivor's own think, pins once
that time has passed, and `OnPouncedOnSurvivor` works out the pounce damage from the
hunter's `m_pounceStartPosition` at that moment.

A touch in mid air keeps the hunter lunging until the pin lands. Standing on a head
does not: it counts as ground, so `CLunge::UpdateAbility` ends the lunge on the same
tick, and `z_lunge_interval` (0.1 s) later the hunter may pounce again. The pin comes
due on the survivor's clock, and with real clients that can be later than 0.1 s. A
hunter still pressing attack then starts a new pounce from the head. That new pounce
resets the start position, so the queued pin lands with almost no distance (1 damage
for a long dive), or, if the new pounce carries the hunter off the survivor, the pin
is lost. To the hunter it feels like bouncing off the survivor's head.

Found in a live match on Death Toll: a hunter dove roughly 1500 units onto a
survivor's head, the log showed "ending a pounce", then "starting a pounce", then the
pin, and the pin did 1 damage instead of the full bonus. On a test server (bot hunter
dropped onto a standing survivor's head, `z_pounce_delay 0.15` to stand in for the
live delay), pressing attack again during the wait lost the pin 12 times out of 12;
with the plugin all 12 pinned with the original pounce distance. Without the extra
press, head landings pin every time with or without the plugin.

The plugin drops a hunter's attack button while a survivor has a pin queued from him,
so the queued pin lands as the game meant it. The pin itself, and its timing, are
still the game's. A queue older than 0.5 s is ignored so a pin the game never resolves
cannot lock a hunter. The two offsets in the gamedata are for the Linux server.

Cvars: `l4d_pounce_land_fix_enable` (0 off, 1 on), `l4d_pounce_land_fix_log` (1 writes
each window in which presses were dropped to `logs/pounce_land_fix.log`).

## Tank fair punch

When the 0.5 s windup ends, `CTankClaw::OnWindupFinished` scans for a survivor within
`tank_swing_range` (56) and inside a cone in front of the tank. If it finds one, the
first fist sweep starts at that survivor's centre, a near-certain hit wherever the fist
is. An audit of 2,988 punches from our matches found that moment wrong both ways: hits
where the fist never came within 30 units of the victim, and survivors the fist visibly
went through at the end of the windup but the scan skipped.

The plugin changes only where that first sweep starts. If the scan picked a standing
survivor the fist never came within `l4d_tank_fair_punch_veto_dist` (30) of during the
windup, the sweep starts at the fist instead (he can still be hit the normal way). A
survivor within `l4d_tank_fair_punch_veto_min_gap` (20) of the tank is never dropped, so
hugging the tank is not a way to avoid punches. If the scan picked nobody, and the fist
came within the fist radius of a standing survivor in the last
`l4d_tank_fair_punch_add_time` (0.25 s) of the windup, in front of the tank and in its
line of sight, the sweep starts at him, as the scan would have done. Distances use
survivor positions rewound by the tank's latency and lerp.

`l4d_tank_fair_punch_mode`: 0 off, 1 log only, 2 on (we run 2). `l4d_tank_fair_punch_log`
and `_log_all` write `logs/tank_fair_punch.log`, with a line per punch and nearby
survivor so any punch can be judged afterwards.

## The rock double hit fix

In one tick, a survivor's own movement can touch a point-blank tank rock:
`BounceTouch` hurts him, the rock detonates, and `UTIL_Remove` only marks it for removal.
Later in the same tick the rock's `ProximityThink` still runs and calls `BounceTouch`
again, past the engine's touch checks, so he takes the hit twice (2 x 24 in versus).
Only human victims are affected, because bot usercmds run after the rock's think. With
`l4d_rock_double_fix 1`, a `BounceTouch` on a rock already marked for removal is
skipped. Every rock hit is logged to `logs/rock_double_fix.log`, and
`sm_rockfix_stats` prints the map's counts.

## Tongue target

While the ability is ready, the game keeps picking the smoker's target: each survivor in
range and in sight is scored by the angle between the smoker's aim and the nearest point
of his box, and the best score wins. When the crosshair passes through two or three
survivors' boxes they all score perfectly, and the first in client order wins, so the
tongue can fly past the survivor in front to one behind him. Survivors are also scored
where the server has them, not where the smoker saw them.

When the tongue starts extending, the plugin scores again, using survivor positions
rewound by the smoker's latency and lerp. Every survivor within
`l4d_tongue_target_tie_deg` (1.0) of the best angle counts as on the crosshair, and the
nearest of them gets the tongue. It only changes a tongue the game already aimed at
someone (a miss stays a miss), and its pick must pass the game's own target checks
(alive and free, in `tongue_range`, inside the smoker's view cone, and an unblocked eye
line). 0.3 matches the game's view cone exactly: it is flat, about 40 degrees to either
side of the smoker's facing at any height (0.2 also refused survivors far above or below).
`l4d_tongue_target_mode`: 0 off, 1 log only, 2 on. `l4d_tongue_target_log` writes
`logs/tongue_target.log`; `l4d_tongue_target_bots` also judges AI smokers (for testing).

## Night mode

Turns daytime maps into night at runtime, without changing the maps. Every setting is
per map, read from `configs/l4d_nightmode.cfg`; a map with no section there is left
alone. The plugin darkens baked world lighting through lightstyle 0, clamps HDR auto
exposure (indoors and outdoors separately, so the tonemapper doesn't brighten the scene
straight back), sets fog and colour correction, and places lamps at points listed per
map. Maps can have several looks ("variants"), picked per map or carried through a
campaign. The config we ship covers the maps we run and was generated by our own tools,
so a map not listed there stays as it is.

Main cvars: `l4d_nightmode_enable`, `l4d_nightmode_variant` (force a look),
`l4d_nightmode_arcs`, `l4d_nightmode_sight_fog`, `l4d_nightmode_lamps` and the
`l4d_nightmode_lamp_*` limits, `l4d_nightmode_live_lock`. The source header lists every
config key.

## The witch crown fix

Visor's crown fix (L4D1 port by Harry) tops up a pump blast that reaches 799 damage, so
pellet spread cannot spoil a crown. It set the top-up pellet to
`z_witch_health - inflictedDamage + damage`, so the blast added up to exactly 1000.0 in float.

The game does not take float damage off her. `CBaseCombatCharacter::OnTakeDamage_Alive` takes
`floorf(damage)` per hit and puts the fraction in `m_flDamageAccumulator`, which pays out one
whole point at a time once it reaches 1.0. The fractions of an exact 1000.0 should add up to a
whole number, but float rounding often leaves the accumulator a hair under 1.0. When the top-up
pellet is the last pellet to hit her (a weaker blast that only just reaches 799), nothing follows
it, the last point never comes off, and she lives on exactly 1 HP and incaps the shooter.

We saw it 6 times on our servers in two weeks, always at 1 HP. Replaying blasts on real witches
where the 799 pellet is the last hit: the old math left her alive on 1 HP in 912 of 2000, the
new one in 0 of 2000.

riverside1 deals her current `m_iHealth` plus 10 on the top-up pellet. Overkill is harmless, and
it no longer assumes she was at full health.

## Physics teardown crash fix

A level change can crash the server with SIGSEGV in
`vphysics.so!CPhysicsEnvironment::NotifyConstraintDisabled`, under
`CPhysicsHook::LevelShutdownPostEntity` -> `~CPhysicsEnvironment` -> `~CPhysicsObject` ->
`CPhysicsConstraint::event_object_deleted`. It is a use-after-free in vphysics itself.

`~CPhysicsEnvironment` deletes its constraint listener first (`this+0x6c`), and only then
deletes the physics objects still in the world. Deleting an object that a live constraint
holds fires `NotifyConstraintDisabled`, which checks only the constraint notify switch
(`this+0x7c`, set by `EnableConstraintNotify`) and then calls through the listener it has
just freed. Normally every constraint is gone with its entity before that point (each
static weapon and item spawn is pinned to the world by a fixed constraint, about 100 a map,
and they notify while the listener is still alive), so nothing happens. When a constraint
does survive to the teardown and the freed memory has been reused, the call jumps through
garbage. It is rare: we have not seen it on our live servers, only on test servers that
changed level over and over right after loading, on stock and custom maps alike. We traced
it under gdb, logging every constraint created and every notify call.

The game turns constraint notify on for each new physics environment
(`CPhysicsHook::LevelInitPreEntity`), and nothing needs it while a level shuts down. The
plugin calls the engine's own `IPhysicsEnvironment::EnableConstraintNotify(false)` in
`OnMapEnd`, which runs before the entities are removed, so every notify during the teardown
returns at that check and never touches the listener. The gamedata finds the `physenv`
global by its symbol in `server.so` and uses vtable index 66 on Linux. On Windows it finds
`physenv` through a signature in `server.dll` (the start of `CPhysicsHook::LevelInitPreEntity`'s
physenv calls) and uses index 65, the same slot without the second destructor. The Windows
gamedata was worked out from the 1.0.4.5 `server.dll` and `vphysics.dll` (the setter it calls
writes the same `this+0x7c` flag); we run Linux servers, so it has not been run on a Windows
server yet.

## Hide view model

Some players hid their gun by pushing the view model FOV to 180 or more with a client DLL.
That breaks the math the client uses to draw the view model, and the weapon half of the HUD
(ammo, the item slots) disappears with it. Hiding it properly with `r_drawviewmodel 0` is a
cheat cvar on L4D1.

The server has its own switch: `m_Local.m_bDrawViewmodel`, which the client checks before it
draws view models and for nothing else, so the HUD is untouched. `!noviewmodel` (or
`!viewmodel`) sets it for the player who types it: `1` hides, `0` shows, and `2` hides only
the main (primary slot) weapon so pistols, pills, throwables and kits still draw. With no
argument it toggles, back to whichever of 1 or 2 the player used last. The choice is kept
in a client cookie. Players who bind it should bind the console command
(`bind v "sm_noviewmodel 2"`); chat triggers in a bind run into SourceMod's chat flood limit. The game sets the flag back on by itself (entering ghost state, survivor cameras,
bot replacement), so a 0.2 s timer re-hides it, and a weapon switch hook updates at once.
The plugin only turns the flag back on when it was the one that turned it off, so the
game's own hides (the death fall camera) are left alone.

Cvars: `l4d_hide_viewmodel_enable` (0 turns the command off and shows everyone's view model
again), `l4d_hide_viewmodel_infected` (default 0: infected keep their claws; 1 hides them too), `l4d_hide_viewmodel_show` (comma-separated weapon classnames that stay visible,
default `weapon_pain_pills`; for example `weapon_pain_pills,weapon_first_aid_kit,weapon_molotov,weapon_pipe_bomb`).

## RCON fixes

Two bugs in the L4D1 Linux engine's RCON server (`engine.so`), found while chasing a
recurring "rcon exec timeout" between two tools that talk to the same server.

**`l4d_rcon_abort_fix`.** `CRConServer::RunFrame` services the sockets newest first and
clears a "socket closed" byte (`CRConServer+0x5c`) once per frame. Any close sets it.
After running each request, RunFrame leaves the whole frame if the byte is set, before it
consumes the request. So when a newer connection closes, an older connection with a request
waiting in the same frame gets the command's output but its buffer still starts with that
request. Nothing more is parsed on that connection until it sends at least 5 new bytes;
then the stale request runs a second time. A client that sends a command plus an empty
marker packet (the usual way to find the end of a multi-packet reply) never gets the
marker's answer and times out. With closes in almost every frame it becomes a livelock: the
same command runs over and over and nothing behind it ever runs.

The byte exists so RunFrame never touches a socket the request itself closed. During a
request only the requester's socket, or all of them, can close, so the plugin clears the
byte right before each request (a detour on `SV_RedirectStart`, whose only caller is
RunFrame, right before `CServerRemoteAccess::WriteDataRequest`). It hooks there rather than
`WriteDataRequest` itself because every rcon command runs inside `WriteDataRequest`:
unloading a plugin that detours it, from an rcon command, frees code the engine is about to
return through. With this hook, loading, unloading and reloading over rcon are safe.

**`l4d_rcon_password_fix`.** `ConVar::ChangeStringValue` calls the change callback without
comparing old and new, and `RconPasswordChanged_f` closes every accepted RCON socket. A
`server.cfg` (or a cfg it execs) that sets `rcon_password` therefore drops every open RCON
connection on every map change, even though the password did not change. The plugin skips
the callback when the new value equals the old one. The callback does only two things (close
every socket, copy the value into the RCON server's password), and with the value unchanged
the copy is a no-op. The plugin never sets the password itself.

Both plugins check the engine code they rely on (the instructions that use the byte, the call
targets, the callback's prologue) and attach nothing if any differ, so on another build the
server simply runs stock RCON.

Measured on a local server at 128 tick with SourceTV, with a long-lived client running
commands while short-lived clients connect, run one command and close:

| | Stock | With the plugins |
|---|---|---|
| Long batch, newer clients closing | 51 of 300 commands timed out, 48 ran twice | 0 of 2,000 timed out, 0 ran twice |
| Four loops of closing clients | (earlier run) 397 of 400 timed out, one command ran 397 times | 0 of 2,000 |
| `rcon_password <same value>` with 2 others connected | all 3 closed | none closed |
| `changelevel` with a connection held open | closed 0.4 s later | stays open and answers |

Not fixed: when a client resets (RST) while the server still has an answer queued for it,
RunFrame closes it and then closes the same index again, which by then is the next newer
connection. Clients avoid that by reading until the last reply before closing.

## Onslaught tank pause

L4D1 has no VScript, so the continuous L4D2 onslaughts in converted maps (Dead Air 2's
trap, Carried Off 3's sparks, Diescraper 3's gauntlet and so on) are rebuilt in stripper:
the start trigger fires a `logic_relay` named `l4d1_onslaught_on` that sets
`director_panic_forever 1` (through `sm_cvar`, it is a cheat cvar) and sends a `PanicEvent`,
and the button that ends it fires `l4d1_onslaught_off`, which sets it back to 0. The
generator is `onslaught.py` in [l4d2-to-l4d1](https://github.com/Volence/l4d2-to-l4d1).

With a tank up that horde never lets up. This plugin hooks those two relays. On
`tank_spawn` during an onslaught it holds `director_panic_forever` at 0 (a change hook
bounces anything that sets it back to 1), so the running panic winds down. When no live,
standing tank is left (checked 0.5 s after a death or disconnect) it sets 1 again and fires
a `PanicEvent`, unless `l4d1_onslaught_off` fired in the meantime. An onslaught that starts
with a tank already up waits for the tank the same way. It does nothing on maps without
those relays, and it does not touch finale gauntlets.

## Tools

`tools/stripper_close_brush_window.py` closes the L4D1 map-load crash from model-less
`func_brush` blockers (the `losfix_*` LOS blockers ported from L4D2). Such a brush spawns
`SOLID_VPHYSICS` with a NULL model until its `logic_auto` `AddOutput,solid 2` fires on the first
tick, and L4D1's `CM_VCollideForModel` has no NULL check, so a trace that touches it first
(the director's `IsSpaceForZombieHere` at map load) segfaults the server. For every such
brush with a matching solid output it adds `"StartDisabled" "1"` and an `Enable` 0.1 s after
the solid output. It only inserts lines and keeps line endings.

    python3 tools/stripper_close_brush_window.py [--check] file.cfg [file.cfg ...]

`--check` reports without writing; without it the files are edited in place.

## Credits and license

The forks keep their original authors in the plugin info (Visor, ProdigySim, CanadaRox,
Tabun, zonde306, Luckylockm, Silvers, Harry and others). Everything is GPLv3, like
SourceMod.
