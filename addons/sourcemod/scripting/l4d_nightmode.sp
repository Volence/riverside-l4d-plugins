// Night mode: turns daytime maps into night at runtime, no BSP changes.
//
// Every setting is per map, read from configs/l4d_nightmode.cfg. A map with no
// section there is left completely alone.
//
// Levers:
//   style        lightstyle 0, scales all baked world lighting (m = stock, a = black)
//   exposure     clamps HDR auto exposure (min = max) outdoors. Without it the
//                HDR tonemapper brightens a darkened scene straight back up.
//   indoor_auto  "lo hi": indoors becomes an auto-exposure range instead of a
//                fixed value (L4D1 daylight: lamp-lit rooms meter themselves)
//   indoor_stock 1 leaves players under a roof on the map's own tonemapping
//                (L4D1 daylight variants: Valve's auto exposure handles interiors)
//   exposure_indoor  the same for a player with no sky above them, through a
//                second tonemap controller (what Valve's trigger_tonemap does).
//                Auto exposure cannot do this itself: L4D meters off the
//                brightest pixels, which indoors is the flashlight pool.
//   sky          sv_skyname, applied at map start (clients load it on connect)
//   fog_*        every env_fog_controller and the 3D skybox fog. The server's
//                sight checks (tank rage, bot vision) read the same fog: anything
//                past fog_end counts as unseen whatever the density. With
//                l4d_nightmode_sight_fog 1 sight keeps the map's own Valve fog
//                except on storm and fog looks (GetFogObscuredRatio detour)
//   cc           optional global color_correction lookup file; the client must
//                have it (L4D1 has no server downloads)
//   enabled      0 turns a configured map off without losing its tuning
//   chance       percent chance (default 100) the map is night this load; rolled
//                once per map load, so both versus halves match
//   lightning    "min max" seconds between strikes (No Mercy's recipe: a
//                lightningstrike25/50/100 color grade for a split second, then
//                Weather.* thunder); empty or absent means no storm
//   bloodmoon    percent chance the map loads with a red grade and red haze
//                instead (bloodmoon_cc, bloodmoon_fog override cc, fog_color)
//   soundscapes  old -> new env_soundscape names, swapped before the entity
//                spawns (L4D1's soundscape scripts are loaded on these maps too)
//   stingers     "a.wav;b.wav@0.5;..." distant one-shot sounds (owls, dogs,
//                planes, far explosions) played somewhere around the survivors;
//                "@vol" sets one file's volume (else stinger_volume, 0..1);
//                stinger_interval "min max" seconds
//   moon         "pitch yaw size [r g b]" a glow sprite in the sky (env_sun)
//   lamp_spots   section of "n" "x y z k", the map's light fixtures (lamps.py), k = p
//                (street lamp: downward sodium cone), l (parking-lot light: a
//                white downward cone), w (wall/porch), f (flood)
//   lamps        1 lights them (light_dynamic + a glow sprite each); the cvar
//                l4d_nightmode_lamps and sm_nightmode_lamps switch them live;
//                2 = fills only (the room fills 902/903/905/906 stay, every
//                fixture is dark: a blackout)
//   lamp_max     per-variant cap on lit lamps (0 or absent = the cvar
//                l4d_nightmode_lamp_max); a midnight lights fewer
//   power_out    1 switches off the map's own lights each round: env_sprite
//                glows hidden, point_spotlight/beam_spotlight and light_dynamic
//                off, named light/light_spot off, env_lightglow and
//                prop_glowing_object removed (a blackout)
//   cc_solo      1 disables the map's own color_correction entities each round,
//                so only our grade applies (Dark Carnival's teal won otherwise)
//   sun_off      1 turns the map's own env_sun off each round (its glow showed
//                as a small sun through an overcast or a storm)
//   rain_off     1 removes the map's func_precipitation each round (No Mercy's
//                own rain on a clear day)
//   title        a short name for the variant, shown in chat when
//                l4d_nightmode_announce is 1
//   postfx       "localcontrast edge vignette_start vignette_end vignette_blur
//                [fadetoblack]": a postprocess_controller (experiment, see
//                l4d_nightmode_postfx below); used when that cvar is empty
//   arc_campaign, arc_chapter   which campaign this map belongs to and its
//                chapter number, for the campaign arcs (below)
//
// Campaign arcs: a root "arcs" section, one sub-section per campaign name,
// each holding named arcs with a "weight" and "chapters" ("sunset night
// midnight": the variant for chapter 1, 2, 3...; "*" rolls that chapter by
// weight as usual; the arc named "none" rolls every chapter). An arc is rolled
// when a campaign starts (chapter 1, or any chapter that does not follow the
// previous map) and followed map by map while the server plays the campaign in
// order. A forced variant (cvar or menu) still wins. l4d_nightmode_arcs 0 turns
// arcs off.
//
// Variants: a map section may hold a "variants" block of named sub-sections,
// each with a "weight" (and optionally an "october" weight used all October)
// plus any of the keys above. One is rolled per map load
// (both versus halves match) and its keys override the map's own. A variant
// with no lighting keys leaves the map as Valve lit it (a "day" roll on a day
// map). l4d_nightmode_variant forces a variant by name on the next map load.
//
// Layers (0.8): a map section may instead hold "layers" and "presets". "layers"
// has five sub-sections, merged in this order: time, weather, moon, event,
// power; each holds named options ("weight", "october", any of the keys above).
// "presets" holds named presets ("weight", "october", "title", and an option
// name per layer: "time" "night" "weather" "storm" ...); a layer a preset
// leaves out is rolled by weight among that layer's options (weight 0 is never
// rolled). One preset is rolled per map load (forced preset / arcs first), then
// each layer's option is read over the map's own keys, later keys winning.
// Stingers append across layers (the map's own list is dropped first) and
// soundscape swaps merge (later wins per name). Extra option keys:
//   exposure_mult     multiplies the merged exposure and exposure_indoor (the
//                     product over every chosen option)
//   fog_ref           the exposure an option's fog_color was judged at: after
//                     the merge the fog colour is scaled by fog_ref / exposure
//   exposure_default  (weather/moon/event options) the clamp to use when the time
//                     option set none (a stock L4D1 night): the look's own
//                     calibrated exposure; ignored when the time has a clamp
//   fog_mult          (time options) multiplies the fog colour after that scaling:
//                     a day's world is brighter, so its weather fog must be too
//                     (day 4, dawn 2, night 1); keeps a daytime storm grey, not black
//                     (clamped 0.04..2.0); with no exposure clamp the
//                     exposure_nominal is used, else 1.0
//   fog_daylit        1 on a weather/event option: its fog colour was judged under
//                     daylight, so the time's fog_mult does not apply. fog_mult only
//                     ever scales a colour a non-time layer supplied (never the time
//                     option's own colour, judged at its own exposure, nor the
//                     map's own)
//   exposure_nominal  (time options) the exposure stock auto exposure settles
//                     at, for the fog_ref scaling when there is no clamp
//   no_moon           1 on a time option: the moon and event layers use "none"
//   title             the merged title is the option titles joined ("Night,
//                     Storm, Blood moon"), unless the preset has its own
// A map with "presets" ignores its "variants". A force (l4d_nightmode_variant,
// sm_nightmode_variant, !tod) is a preset name and/or a layer spec:
// "hardrain", "time=night,weather=storm", "night weather=fog moon=blood".
// A spec alone (or "custom") rolls every layer it does not name.
//
// Experiments and live safety (2026-10-04), all off or unchanged by default:
//   l4d_nightmode_bolts "0"   1 = a strike of kind 1 or 2 (medium, close) also
//                spawns the L4D2 storm bolt particle (storm_lightning_02, from
//                particles/l4d_dlc_rain_storm_fx.pcf, which the L4D2 map pack's
//                particles_manifest preloads on clients) high in the sky
//                1800-3200 units from a random alive human survivor, for 2 s;
//                2 = also storm_lightning_screenglow at the same spot
//   sm_nightmode_bolt [kind 0|1|2] [mode 1|2]   one strike now (flash, thunder)
//                with a bolt forced on, whatever the cvar (default kind 2,
//                mode = the cvar or 1): for screenshot tours
//   l4d_nightmode_postfx ""   "localcontrast edge vignette_start vignette_end
//                vignette_blur [fadetoblack]" (missing numbers are 0): one
//                postprocess_controller named nightmode_postfx each round;
//                whether the L4D1 client honours it is the experiment. Wins
//                over the config key postfx; empty = the key, else none
//   l4d_nightmode_live_lock "1"   with two or more humans in game, !tod, !todmap
//                and sm_nightmode_variant store the pick instead of reloading
//                (a reload wrecks a live round): !tod and sm_nightmode_variant
//                for the next map load, !todmap for the next load of the map it
//                named; "sm_nightmode_variant <name> now" reloads anyway
//
// Live from 0.6 (2026-10-02) in a night-only test phase: see PHASE in gen_config.py.
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required
#pragma dynamic 65536   // lamp_spots and stinger lists are parsed on the stack

#define PLUGIN_VERSION "0.9-riverside2"
#define GAMEDATA_FILE  "l4d_nightmode"
#define CONFIG_FILE    "configs/l4d_nightmode.cfg"

public Plugin myinfo =
{
	name = "L4D Night Mode",
	author = "Malevolence",
	description = "Per-map runtime night lighting, fog, sky and soundscapes",
	version = PLUGIN_VERSION,
	url = ""
};

ConVar g_cvEnable, g_cvVariant, g_cvAnnounce, g_cvCurrent, g_cvArcs;
char g_sMapCampaign[32], g_sArcCampaign[32], g_sArcName[32], g_sArcChapters[256];
int g_iMapChapter, g_iArcChapter;   // the arc state survives map changes (a plugin reload drops it)
// A variant to use on the next roll only (sm_nightmode_variant, reloads); with
// layers, a preset name and/or a layer spec ("hardrain time=night weather=storm").
char g_sForceOnce[192];

// Layers (0.8): what this map load chose, in merge order
static const char LAYERS[5][] = { "time", "weather", "moon", "event", "power" };
char g_sLayer[5][32];
bool g_bLayered;          // this map uses "presets" + "layers"
bool g_bLayerRead;        // ReadSettings on a layer option: stingers append, soundscapes merge
char g_sCombo[192];       // "<preset> time=.. weather=.. moon=.. event=.. power=.." (reload re-forces it)
// !tod "Custom...": per-admin state while walking the five layer menus
char g_sCustomMap[MAXPLAYERS + 1][64];
char g_sCustomSpec[MAXPLAYERS + 1][192];
char g_sCustomTime[MAXPLAYERS + 1][32];
int g_iCustomStep[MAXPLAYERS + 1];

char g_sLoadedMap[64];
bool g_bActive;
char g_sVariant[32], g_sTitle[128];
char g_sStyle[16], g_sSky[64], g_sCC[PLATFORM_MAX_PATH];
float g_fExposure, g_fExposureIn;
bool g_bIndoorStock;
float g_fHandoff = 1.5;
int g_iHandoff = INVALID_ENT_REFERENCE;
float g_fIndoorSince[MAXPLAYERS + 1];
#define HANDOFF_TIME 2.5
#define FAST_RATE 6.0
float g_fAutoLo, g_fAutoHi;
int g_iTonemapFor[MAXPLAYERS + 1] = {INVALID_ENT_REFERENCE, ...};

// Indoor exposure is a ladder of tonemap controllers from the outdoor value
// (step 0) to the indoor one (last step). Each player walks along it a step
// at a time, so a doorway eases from one to the other instead of snapping,
// and a spot with a little sky (a window, a porch) sits halfway.
#define LADDER 7
int g_iLadder[LADDER] = {INVALID_ENT_REFERENCE, ...};
float g_fStep[MAXPLAYERS + 1];
#define STEP_PER_TICK 0.75
bool g_bFog;
int g_iFogColor;
float g_fFogStart, g_fFogEnd, g_fFogDensity;
// The map's own fog per env_fog_controller, captured before ApplyFog first writes it
// (by entity reference, so a round's fresh controllers are captured again)
int g_iFogOrigRef[2048];
bool g_bFogOrigOn[2048];
float g_fFogOrigStart[2048], g_fFogOrigEnd[2048], g_fFogOrigDensity[2048];
int g_iFogMaster = INVALID_ENT_REFERENCE;   // the controller the game judges sight by (CFogSystem master)
ConVar g_cvSightFog;
StringMap g_hSwap;
int g_iSwapped;

int g_iCC = INVALID_ENT_REFERENCE;

float g_fLightningMin, g_fLightningMax;
Handle g_hLightning;
static const char STRIKE_FILES[][] = {
	"materials/correction/lightningstrike25.raw",
	"materials/correction/lightningstrike50.raw",
	"materials/correction/lightningstrike100.raw",
};
static const char THUNDER_FAR[][] = { "Weather.thunder_far_away_1", "Weather.thunder_far_away_2" };
static const char THUNDER_MED[][] = { "Weather.thunder_1", "Weather.thunder_2", "Weather.thunder_3" };
static const char THUNDER_CLOSE[][] = { "Weather.lightning_strike_1", "Weather.lightning_strike_2", "Weather.lightning_strike_3", "Weather.lightning_strike_4" };
bool g_bBloodMoon;
int g_iMoon = INVALID_ENT_REFERENCE;
char g_sMoon[64];

// Bolt particles (experiment): the L4D2 storm bolts. The L4D2 map pack's
// particles_manifest preloads this pcf on every map, so clients have the systems;
// the server only has to put their names in the ParticleEffectNames table.
ConVar g_cvBolts;
#define BOLT_PCF    "particles/l4d_dlc_rain_storm_fx.pcf"
#define BOLT_EFFECT "storm_lightning_02"
#define BOLT_GLOW   "storm_lightning_screenglow"

// Postprocess experiment: one postprocess_controller, from the cvar or the
// config key postfx (the cvar wins)
ConVar g_cvPostFx;
char g_sPostFx[96];          // the config key, reset with the map's settings
char g_sPostFxSpawned[96];   // the spec the standing controller was made from
int g_iPostFx = INVALID_ENT_REFERENCE;

// Live lock: with two or more humans on, a time-of-day pick waits for the next
// map load instead of reloading mid-round. A !todmap pick for another map is
// tagged with that map and held until it loads (empty = whatever loads next).
ConVar g_cvLiveLock;
char g_sForceMap[64];
bool g_bRollFresh;   // !todr: the next load rolls with the rotation's dice and ignores the campaign arc once
bool g_bRollFlat;    // !todr flat: every option of every layer at equal odds (weight 0 still excluded)
ConVar g_cvBoltNear, g_cvBoltFar, g_cvSkyOverride, g_cvTellJoin, g_cvCampaignLock;
// campaign lock (owner 2026-10-04: a campaign's first map rolls, the following chapters keep that look)
char g_sLockCampaign[32], g_sLockForce[192];
int g_iLockChapter;
bool g_bLockPick;   // this load's force-once came from the campaign lock, not from a pick (for the log)
bool g_bToldLook[MAXPLAYERS + 1];   // the look was whispered to this player this map
float g_fBoltHold = 2.0;   // seconds a bolt entity lives (sm_nightmode_bolt's hold argument stretches it for screenshots)

ArrayList g_hStingers;
ArrayList g_hLamps;          // float[8]: x y z kind (0 post, 1 wall, 2 flood, 3 lot, 4 tower, 5 fire, 6 fire light) wall-yaw brightness-step flicker glow-scale
ArrayList g_hLampProps;      // "model x y z pitch yaw roll": fixtures we add where a map has none
bool g_bLamps;
int g_iLampMode;        // 1 all lamps, 2 fills only (lamps "2")
int g_iLampMaxVariant;  // per-variant cap, 0 = cvar
bool g_bPowerOut;       // power_out: the map's own glows and lights go dark each round
bool g_bCCSolo;         // cc_solo: the map's own colour grades are disabled each round
bool g_bSunOff;         // sun_off: the map's own env_sun is turned off each round
bool g_bRainOff;        // rain_off: the map's func_precipitation is removed each round
ConVar g_cvLampRefExposure;
ConVar g_cvPoolClose, g_cvPoolThin, g_cvSconceFloor;
bool g_bThinLog = false;   // true logs every pool the thin rule shrinks (logs/nightmode_thin.log)
ConVar g_cvTourMaps, g_cvGlowMax, g_cvIndoorReach, g_cvHangRadius, g_cvIndoorPool, g_cvLightModels;
ConVar g_cvPropTint, g_cvPropTintPower, g_cvPropTintMin;
ConVar g_cvLamps, g_cvLampMax, g_cvLampBright, g_cvLampReach, g_cvLotCone, g_cvLampPitch, g_cvLotPitch, g_cvWallCone;
#define LAMP_GLOW "sprites/light_glow03.vmt"
#define GENERATOR_HUM "ambient/ambience/generator_amb01_loop.wav"
// a small smoke-free flame (32x64, 14 frames): sprites/fire1 is 128x256 with a
// smoke column and poured out of the lantern (owner's screenshot)
#define FIRE_SPRITE "sprites/floorflame.vmt"
#define FIRE_CRACKLE "ambient/fire/fire_small_loop2.wav"   // not the molotov loops: players read those as a cue
float g_fStingMin, g_fStingMax, g_fStingVol;
Handle g_hSting;
ArrayList g_hFlames;        // fire lamp sprites, frames stepped in OnGameFrame
// Lamps switch on by distance: the nearest l4d_nightmode_lamp_max to any
// player (owner, 2026-10-02: a map-wide cap made changing one lamp silently
// drop another). Each lamp's entities share the name nightmode_lamp_<index>.
#define MAX_LAMPS 512
bool g_bLampOn[MAX_LAMPS];
bool g_bLightHud[MAXPLAYERS + 1];
bool g_bLampOff[MAX_LAMPS];         // !unlight: removed this session (made permanent in the config)
int g_iLastUnlit = -1;   // !light hud: a lamp counter on that admin's screen
int g_iLampRef[MAX_LAMPS];
char g_sLampName[32] = "nightmode_lamp";
char g_sGlowName[32] = "nightmode_glow";   // bulb sprites, flames and hums: drawn well past the light cap
bool g_bGlowOn[MAX_LAMPS];
// lights fade in and out instead of popping (owner: "like someone's turning on light switches")
float g_fLevel[MAX_LAMPS];       // 0..1 of the lamp's full light
bool g_bFadeOut[MAX_LAMPS];
int g_iFullExp[MAX_LAMPS];
float g_fFullSpot[MAX_LAMPS];
#define GLOW_RANGE 4000.0
#define FADE_IN 1.6
#define FADE_OUT 0.9
#define LAMP_RANGE 2500.0
#define FLAME_FRAMES 14.0   // sprites/floorflame: 14 frames

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d_nightmode_enable", "1", "Apply night mode on maps that have a config section");
	g_cvSightFog = CreateConVar("l4d_nightmode_sight_fog", "1", "1 = the server's sight checks (tank rage, bot vision) use the map's own Valve fog, except on storm and fog looks; 0 = sight uses the look's fog (a dark fog_end hid survivors from the tank's rage check)");
	SetupSightFog();
	g_cvArcs = CreateConVar("l4d_nightmode_arcs", "1", "Follow the campaign arcs in the config (a story across a campaign's maps) instead of rolling every map alone");
	g_cvVariant = CreateConVar("l4d_nightmode_variant", "", "Force this variant or preset (by name) on every map that has it until cleared, e.g. blood for an event night; on layered maps also a layer spec (\"time=night,weather=storm\"); empty = roll by weight");
	// What this map rolled, so a plugin reload mid-map keeps it (convars outlive the plugin).
	g_cvCurrent = CreateConVar("l4d_nightmode_current", "", "Internal: \"<map> <variant>\" (layered maps: \"<map> <preset> time=.. weather=.. moon=.. event=.. power=..\") rolled for the current map", FCVAR_DONTRECORD);
	g_cvAnnounce = CreateConVar("l4d_nightmode_announce", "0", "Print the rolled variant's title in chat at round start");
	g_cvBolts = CreateConVar("l4d_nightmode_bolts", "0", "Experiment: medium and close lightning strikes also spawn the L4D2 storm bolt particle in the sky (1), plus its screen glow (2); 0 = flash and thunder only", _, true, 0.0, true, 2.0);
	g_cvBoltNear = CreateConVar("l4d_nightmode_bolt_near", "1800", "Experiment: nearest distance (units) a bolt spawns from a survivor");
	g_cvBoltFar = CreateConVar("l4d_nightmode_bolt_far", "3200", "Experiment: farthest distance (units) a bolt spawns from a survivor");
	g_cvPostFx = CreateConVar("l4d_nightmode_postfx", "", "Experiment: \"localcontrast edge vignette_start vignette_end vignette_blur [fadetoblack]\" spawns a postprocess_controller each round (wins over the config key postfx); empty = none");
	g_cvPostFx.AddChangeHook(OnPostFxCvar);
	g_cvLiveLock = CreateConVar("l4d_nightmode_live_lock", "1", "With two or more humans in game, !tod, !todmap and sm_nightmode_variant store the pick for the next map instead of reloading (sm_nightmode_variant <name> now still reloads)");
	g_hSwap = new StringMap();
	g_hStingers = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_hLamps = new ArrayList(8);
	g_hLampProps = new ArrayList(ByteCountToCells(160));
	g_cvLamps = CreateConVar("l4d_nightmode_lamps", "1", "Light the map's lamps on variants that ask for it (0 = never)");
	// The client draws about 16 of these lamps at once (owner tested 2026-10-02:
	// at 32 the near ones went dark, at 16 they came back), so 16 nearest to anyone.
	g_cvLampMax = CreateConVar("l4d_nightmode_lamp_max", "16", "At most this many lamps lit at once, the nearest to any player (the client draws about 16)");
	g_cvLampBright = CreateConVar("l4d_nightmode_lamp_brightness", "6", "Street lamp light_dynamic brightness (wall lamps 2 less, floods the same)");
	g_cvLampReach = CreateConVar("l4d_nightmode_lamp_reach", "600", "Street lamp light distance in units (wall lamps half, floods 1.2x)");
	// Parking-lot lights: a wide fan aimed mostly level (owner's pick in game,
	// Parish 2, 2026-10-02: cone 90, pitch 20) rather than a pool straight down.
	g_cvLotCone = CreateConVar("l4d_nightmode_lot_cone", "89", "Parking-lot light cone (half-angle, at most 89; inner is half)", _, true, 1.0, true, 89.0);
	// 20 was picked with r_dynamic off (model light only); with world light on,
	// 20 never reached the ground from 556 up, so 45 (owner, in game)
	g_cvPropTint = CreateConVar("l4d_nightmode_prop_tint", "0", "Tint physics props, dynamic props and weapons so a brighter exposure does not whiten them: 0 off, else the reference exposure (0.33 = The Parish look); tint = (ref / exposure)^power");
	g_cvPropTintPower = CreateConVar("l4d_nightmode_prop_tint_power", "0.5", "Exponent of the prop tint (1 = exact, 0.5 = half way, keeps the flashlight on props readable)");
	g_cvPropTintMin = CreateConVar("l4d_nightmode_prop_tint_min", "0.3", "Darkest prop tint (fraction of full colour)");
	g_cvPropTint.AddChangeHook(OnPropTintCvar);
	g_cvPropTintPower.AddChangeHook(OnPropTintCvar);
	g_cvPropTintMin.AddChangeHook(OnPropTintCvar);
	g_cvLightModels = CreateConVar("l4d_nightmode_light_models", "0", "Lamps light models (guns, players): 0 no, 1 yes, 2 outdoor lamps only");
	g_cvLightModels.AddChangeHook(OnLampsRebuild);
	g_cvIndoorPool = CreateConVar("l4d_nightmode_indoor_pool", "120", "Largest pool for lamps with no sky above them, 0 = no cap (pools light through walls)");
	g_cvIndoorPool.AddChangeHook(OnLampsRebuild);
	g_cvHangRadius = CreateConVar("l4d_nightmode_hang_radius", "260", "Pool size of hanging lamps (pendants, flush mounts, lanterns, vanities shining down)");
	g_cvHangRadius.AddChangeHook(OnLampsRebuild);
	g_cvIndoorReach = CreateConVar("l4d_nightmode_indoor_reach", "0.4", "Reach multiplier for lamps with no sky above them (they light through walls)", _, true, 0.1, true, 1.0);
	g_cvIndoorReach.AddChangeHook(OnLampsRebuild);
	g_cvGlowMax = CreateConVar("l4d_nightmode_glow_max", "48", "Most lamps whose bulb glow (sprite, flame, hum) is drawn at once, nearest first, within 4000 units");
	g_cvTourMaps = CreateConVar("l4d_nightmode_tour_maps", "c1m1_hotel c1m2_streets c1m3_mall c2m1_highway c2m2_fairgrounds c2m3_coaster c2m4_barns c3m1_plankcountry c3m2_swamp c3m3_shantytown c4m1_milltown_a c4m2_sugarmill_a c5m1_waterfront c5m2_park c5m3_cemetery c5m4_quarter c6m1_riverbank c6m2_bedlam l4d_river01_docks l4d_river02_barge", "Maps !next and !prev walk through, in order");
	g_cvLampRefExposure = CreateConVar("l4d_nightmode_lamp_ref_exposure", "0.33", "Exposure the lamp brightness was tuned at (The Parish); lamps step by log2(this / map exposure), 0 = off");
	g_cvLotPitch = CreateConVar("l4d_nightmode_lot_pitch", "85", "Parking-lot light tilt: 90 straight down, 0 level");
	g_cvLampPitch = CreateConVar("l4d_nightmode_lamp_pitch", "90", "Street lamp tilt: 90 straight down, 0 level");
	g_cvWallCone = CreateConVar("l4d_nightmode_wall_cone", "80", "Wall lamp and flood light cone (half-angle, at most 89), pointing down", _, true, 1.0, true, 89.0);
	g_cvLamps.AddChangeHook(OnLampsCvar);
	g_cvPoolClose = CreateConVar("l4d_nightmode_pool_close", "0.3", "Untuned lamps whose pool lands on a surface close to the bulb are stepped down until (1 - hit fraction)^2 is at most this (the engine brightens the pool that way: a vanity's wall went white); 0 = off", _, true, 0.0, true, 1.0);
	g_cvPoolClose.AddChangeHook(OnLampsRebuild);
	g_cvPoolThin = CreateConVar("l4d_nightmode_pool_thin", "1", "Shrink a lamp's pool so it cannot reach through the surface it lands on (a roof flood lit the bathroom under it); 0 = off");
	g_cvPoolThin.AddChangeHook(OnLampsRebuild);
	g_cvSconceFloor = CreateConVar("l4d_nightmode_sconce_floor", "1", "Brightness steps (from the lamp's own) of a floor-pool sconce's pool (wall yaw 3000+); the carpet is dark, so -1 read as nothing");
	g_cvSconceFloor.AddChangeHook(OnLampsRebuild);
	// green !mark glows a plugin reload orphaned (their removal timer died with it)
	int stray = -1;
	char sname[32];
	while ((stray = FindEntityByClassname(stray, "env_sprite")) != -1)
	{
		GetEntPropString(stray, Prop_Data, "m_iName", sname, sizeof(sname));
		if (StrEqual(sname, "nightmode_mark") || (!sname[0] && GetEntProp(stray, Prop_Send, "m_clrRender") == 0xFF78FF50))
			RemoveEntity(stray);
	}

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	RegAdminCmd("sm_nightmode_set", Cmd_Set, ADMFLAG_ROOT, "sm_nightmode_set <style|exposure|exposure_indoor|sky|fog_color|fog_start|fog_end|fog_density|cc> <value>: change the current map's setting live");
	RegAdminCmd("sm_nightmode_reload", Cmd_Reload, ADMFLAG_ROOT, "Re-read the config for the current map and apply it");
	RegAdminCmd("sm_nightmode_strike", Cmd_Strike, ADMFLAG_ROOT, "sm_nightmode_strike [0|1|2] [hold]: a lightning strike now (far, medium, close); hold keeps the flash on for screenshots");
	RegAdminCmd("sm_nightmode_bolt", Cmd_Bolt, ADMFLAG_ROOT, "sm_nightmode_bolt [0|1|2] [1|2]: a lightning strike now (far, medium, close; default close) with a bolt particle forced on (mode 1 bolt, 2 bolt + screen glow; default the cvar or 1)");
	RegAdminCmd("sm_nightmode_moon", Cmd_Moon, ADMFLAG_ROOT, "sm_nightmode_moon <pitch> <yaw> <size> [r g b]: test a moon glow in the sky (size 0 removes it)");
	RegAdminCmd("sm_nightmode_dump", Cmd_Dump, ADMFLAG_ROOT, "Print the current map's settings");
	RegAdminCmd("sm_nightmode_variant", Cmd_Variant, ADMFLAG_ROOT, "sm_nightmode_variant [name]: list this map's variants, or reload the map once as the named one (\"roll\" rolls again)");
	RegAdminCmd("sm_nightmode_spots", Cmd_Spots, ADMFLAG_ROOT, "List soundscape and survivor spawn spots with how much sky each sees (for screenshot tours)");
	RegAdminCmd("sm_mark", Cmd_Mark, ADMFLAG_ROOT, "!mark <note>: log what your crosshair is on (for tuning sessions)");
	RegAdminCmd("sm_nightmode_sprites", Cmd_Sprites, ADMFLAG_ROOT, "List lamp sprites near a point: sm_nightmode_sprites x y z [radius]");
	RegAdminCmd("sm_unlight", Cmd_Unlight, ADMFLAG_ROOT, "!unlight [undo]: switch off the lamp at your crosshair (logged so it can be removed for good)");
	RegAdminCmd("sm_tod", Cmd_Tod, ADMFLAG_ROOT, "!tod: menu of this map's times of day; pick one and the map reloads as it");
	RegAdminCmd("sm_todmap", Cmd_TodMap, ADMFLAG_ROOT, "!todmap: campaign -> map -> time of day; changes level with that variant");
	g_cvSkyOverride = CreateConVar("l4d_nightmode_sky", "", "Test tool: a sky name that overrides every look's sky at map load until cleared (!sky)");
	g_cvCampaignLock = CreateConVar("l4d_nightmode_campaign_lock", "1", "A campaign's first map rolls its look; the next chapters of the same campaign keep it (a forced pick, !tod or !todr still win)");
	g_cvTellJoin = CreateConVar("l4d_nightmode_tell_join", "1", "Whisper the map's look (weather / time of day) to a player when they join a team; !weather shows it any time");
	RegConsoleCmd("sm_weather", Cmd_Weather, "!weather: what time of day / weather this map rolled");
	HookEvent("player_team", Event_PlayerTeam);
	RegAdminCmd("sm_sky", Cmd_Sky, ADMFLAG_ROOT, "!sky <skyname|off>: sky override, reloads this map with the same look");
	RegAdminCmd("sm_todr", Cmd_TodR, ADMFLAG_ROOT, "!todr [flat|live]: stay on this map and re-roll; default every layer by its weights, flat = equal odds per option, live = the rotation's preset dice; the campaign arc is ignored once");
	RegAdminCmd("sm_nightmode_lampdump", Cmd_LampDump, ADMFLAG_ROOT, "sm_nightmode_lampdump x y z [range]: the lamp table entries near a point (index, position, kind, wall code, step, off/on), for fill debugging");
	RegAdminCmd("sm_nightmode_probe", Cmd_Probe, ADMFLAG_ROOT, "sm_nightmode_probe x y z [dx dy dz]: point contents every 4 units along a direction (default down), for pool depth debugging");
	RegAdminCmd("sm_ul", Cmd_Unlight, ADMFLAG_ROOT, "!ul [undo]: short for !unlight");
	RegAdminCmd("sm_next", Cmd_TourNext, ADMFLAG_ROOT, "!next: the next map of the lamp QA tour (l4d_nightmode_tour_maps)");
	RegAdminCmd("sm_prev", Cmd_TourPrev, ADMFLAG_ROOT, "!prev: the previous map of the lamp QA tour");
	RegAdminCmd("sm_light", Cmd_Light, ADMFLAG_ROOT, "!light on|off|<brightness>|reach <units>|max <count>: lamps, for comparing in game");
	RegAdminCmd("sm_nightmode_lamps", Cmd_Lamps, ADMFLAG_ROOT, "sm_nightmode_lamps [0|1]: lamps off/on now (sets l4d_nightmode_lamps)");
	RegAdminCmd("sm_nightmode_sting", Cmd_Sting, ADMFLAG_ROOT, "sm_nightmode_sting [human]: play one of the current variant's distant sounds now (human: around the first human player)");
	CreateTimer(1.0, Timer_Enforce, _, TIMER_REPEAT);
	CreateTimer(0.1, Timer_LampFade, _, TIMER_REPEAT);
	CreateTimer(0.1, Timer_Indoor, _, TIMER_REPEAT);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}

	// Late load: lighting, fog and sky now; soundscapes need a map reload. Keep
	// the variant this map already rolled, so versus halves still match.
	// (a layered map's value carries the preset and all five options after the map)
	char map[64], current[256];
	GetCurrentMap(map, sizeof(map));
	g_cvCurrent.GetString(current, sizeof(current));
	int sp = FindCharInString(current, ' ');
	if (sp > 0)
	{
		current[sp] = '\0';
		if (StrEqual(current, map))
			strcopy(g_sForceOnce, sizeof(g_sForceOnce), current[sp + 1]);
	}
	// late load on a running map (test server): apply now. At server boot the map name is
	// already known but no map runs yet, and a spawn there throws ("Cannot create new entity
	// when no map is running"): three pool boxes rolled Midnight at boot and the plugin stayed
	// unloaded (2026-10-04 16:42 UTC). SourceMod calls OnMapStart itself once the map is up.
	if (map[0] && IsServerProcessing())
	{
		// riverside1 (audit C5): a reload mid-map starts with every glow flag off, so the old
		// instance's bulbs and hums would stay and get a second copy (double hum loops)
		RemoveLamps();
		OnMapStart();
	}
}

// ---------------------------------------------------------------------------
// Config

void EnsureLoaded()
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	if (StrEqual(map, g_sLoadedMap))
		return;
	strcopy(g_sLoadedMap, sizeof(g_sLoadedMap), map);
	// a !todmap pick stored under the live lock waits for the map it named:
	// hide it from this load and put it back afterwards
	char held[sizeof(g_sForceOnce)];
	bool hold = g_sForceMap[0] && !StrEqual(map, g_sForceMap, false);
	if (hold)
	{
		strcopy(held, sizeof(held), g_sForceOnce);
		g_sForceOnce[0] = '\0';
	}
	LoadMapSettings(map);
	g_bRollFresh = false;
	g_bRollFlat = false;
	if (hold)
		strcopy(g_sForceOnce, sizeof(g_sForceOnce), held);
	else
		g_sForceMap[0] = '\0';
}

void LoadMapSettings(const char[] map)
{
	g_bActive = false;
	g_bFog = false;
	g_sStyle[0] = g_sSky[0] = g_sCC[0] = g_sVariant[0] = g_sTitle[0] = g_sMoon[0] = '\0';
	g_sPostFx[0] = '\0';
	g_bLayered = false;
	g_bLayerRead = false;
	g_sCombo[0] = '\0';
	for (int i = 0; i < sizeof(LAYERS); i++)
		g_sLayer[i][0] = '\0';
	g_fExposure = g_fExposureIn = 0.0;
	g_bIndoorStock = false;
	g_fHandoff = 1.5;
	g_fAutoLo = g_fAutoHi = 0.0;
	g_hSwap.Clear();
	g_iSwapped = 0;
	g_fLightningMin = g_fLightningMax = 0.0;
	g_bBloodMoon = false;
	g_hStingers.Clear();
	g_hLamps.Clear();
	g_hLampProps.Clear();
	g_bLamps = false;
	g_iLampMode = 0;
	g_iLampMaxVariant = 0;
	g_bPowerOut = false;
	g_bCCSolo = false;
	g_bSunOff = false;
	g_bRainOff = false;
	g_sMapCampaign[0] = '\0';
	g_iMapChapter = 0;
	g_fStingMin = g_fStingMax = 0.0;
	g_fStingVol = 0.6;
	g_fFogStart = 0.0;
	g_fFogEnd = 1500.0;
	g_fFogDensity = 0.9;

	if (!g_cvEnable.BoolValue)
		return;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);
	KeyValues kv = new KeyValues("NightMode");
	if (!kv.ImportFromFile(path))
	{
		LogError("could not read %s", path);
		delete kv;
		return;
	}
	if (!kv.JumpToKey(map))
	{
		g_sForceOnce[0] = '\0';
		delete kv;
		return;
	}

	// campaign arcs: this map's place in its campaign, then continue or roll an arc
	// (before the enabled/chance checks, so a chapter that rolls off keeps the chain)
	kv.GetString("arc_campaign", g_sMapCampaign, sizeof(g_sMapCampaign));
	g_iMapChapter = kv.GetNum("arc_chapter", 0);
	kv.GoBack();
	ArcAdvance(kv, map);
	kv.JumpToKey(map);

	if (kv.GetNum("enabled", 1) == 0)
	{
		g_sForceOnce[0] = '\0';
		delete kv;
		return;
	}
	int chance = kv.GetNum("chance", 100);
	if (chance < 100 && GetRandomInt(1, 100) > chance)
	{
		LogMessage("%s: night mode rolled off (chance %d%%)", map, chance);
		delete kv;
		return;
	}

	g_bActive = true;
	ReadSettings(kv);

	if (kv.JumpToKey("presets"))
	{
		kv.GoBack();
		LoadLayers(kv, map);
	}
	else if (kv.JumpToKey("variants"))
	{
		if (PickVariant(kv, g_sVariant, sizeof(g_sVariant)) && kv.JumpToKey(g_sVariant))
		{
			ReadSettings(kv);
			kv.GoBack();
		}
		kv.GoBack();
		RememberLook();
	}
	g_sForceOnce[0] = '\0';
	char current[256];
	FormatEx(current, sizeof(current), "%s %s", map, g_bLayered ? g_sCombo : g_sVariant);
	g_cvCurrent.SetString(current);
	if (g_fExposureIn <= 0.0)
		g_fExposureIn = g_fExposure;
	delete kv;
}

// Reads whatever keys this section sets; keys it leaves out keep their value,
// so a variant only needs what differs from the map's own section.
void ReadSettings(KeyValues kv)
{
	char parts[2][16];
	if (kv.GetDataType("style") != KvData_None)
		kv.GetString("style", g_sStyle, sizeof(g_sStyle));
	if (kv.GetDataType("sky") != KvData_None)
		kv.GetString("sky", g_sSky, sizeof(g_sSky));
	if (kv.GetDataType("cc") != KvData_None)
		kv.GetString("cc", g_sCC, sizeof(g_sCC));
	if (kv.GetDataType("title") != KvData_None)
		kv.GetString("title", g_sTitle, sizeof(g_sTitle));
	if (kv.GetDataType("moon") != KvData_None)
		kv.GetString("moon", g_sMoon, sizeof(g_sMoon));
	if (kv.GetDataType("postfx") != KvData_None)
		kv.GetString("postfx", g_sPostFx, sizeof(g_sPostFx));
	if (kv.GetDataType("exposure") != KvData_None)
		g_fExposure = kv.GetFloat("exposure");
	if (kv.GetDataType("indoor_auto") != KvData_None)
	{
		char range[32];
		kv.GetString("indoor_auto", range, sizeof(range));
		g_fAutoLo = g_fAutoHi = 0.0;
		if (ExplodeString(range, " ", parts, 2, 16) == 2)
		{
			g_fAutoLo = StringToFloat(parts[0]);
			g_fAutoHi = StringToFloat(parts[1]);
		}
	}
	if (kv.GetDataType("indoor_handoff") != KvData_None)
		g_fHandoff = kv.GetFloat("indoor_handoff");
	if (kv.GetDataType("indoor_stock") != KvData_None)
		g_bIndoorStock = kv.GetNum("indoor_stock") != 0;
	if (kv.GetDataType("exposure_indoor") != KvData_None)
		g_fExposureIn = kv.GetFloat("exposure_indoor");

	char color[32];
	if (kv.GetDataType("fog_color") != KvData_None)
	{
		kv.GetString("fog_color", color, sizeof(color));
		g_bFog = ParseColor(color, g_iFogColor);
	}
	if (kv.GetDataType("fog_start") != KvData_None)
		g_fFogStart = kv.GetFloat("fog_start");
	if (kv.GetDataType("fog_end") != KvData_None)
		g_fFogEnd = kv.GetFloat("fog_end");
	if (kv.GetDataType("fog_density") != KvData_None)
		g_fFogDensity = kv.GetFloat("fog_density");

	if (kv.GetDataType("lightning") != KvData_None)
	{
		char range[32];
		kv.GetString("lightning", range, sizeof(range));
		g_fLightningMin = g_fLightningMax = 0.0;
		if (range[0] && ExplodeString(range, " ", parts, 2, 16) == 2)
		{
			g_fLightningMin = StringToFloat(parts[0]);
			g_fLightningMax = StringToFloat(parts[1]);
		}
	}

	if (kv.GetDataType("stingers") != KvData_None)
	{
		char list[2048], files[32][PLATFORM_MAX_PATH];
		kv.GetString("stingers", list, sizeof(list));
		if (!g_bLayerRead)   // layer options add to the list (LoadLayers clears it once)
			g_hStingers.Clear();
		int n = ExplodeString(list, ";", files, sizeof(files), sizeof(files[]));
		for (int i = 0; i < n; i++)
		{
			TrimString(files[i]);
			if (files[i][0])
				g_hStingers.PushString(files[i]);
		}
	}
	if (kv.GetDataType("lamps") != KvData_None)
	{
		g_iLampMode = kv.GetNum("lamps");
		g_bLamps = g_iLampMode != 0;
	}
	if (kv.GetDataType("lamp_max") != KvData_None)
		g_iLampMaxVariant = kv.GetNum("lamp_max");
	if (kv.GetDataType("power_out") != KvData_None)
		g_bPowerOut = kv.GetNum("power_out") != 0;
	if (kv.GetDataType("cc_solo") != KvData_None)
		g_bCCSolo = kv.GetNum("cc_solo") != 0;
	if (kv.GetDataType("sun_off") != KvData_None)
		g_bSunOff = kv.GetNum("sun_off") != 0;
	if (kv.GetDataType("rain_off") != KvData_None)
		g_bRainOff = kv.GetNum("rain_off") != 0;
	// lamp_spots is a section, one "n" "x y z k" per lamp (a single string
	// value is cut at 1024 characters by the KeyValues reader)
	if (kv.JumpToKey("lamp_spots"))
	{
		g_hLamps.Clear();
		if (kv.GotoFirstSubKey(false))
		{
			char spot[72], p4[8][12];
			do
			{
				kv.GetString(NULL_STRING, spot, sizeof(spot));
				int fields = ExplodeString(spot, " ", p4, 8, 12);
				if (fields < 4)
					continue;
				float lamp[8];
				lamp[4] = fields >= 5 ? StringToFloat(p4[4]) : 0.0;
				lamp[5] = fields >= 6 ? StringToFloat(p4[5]) : 0.0;
				// 'f' = a flickering bulb, 's' = a slight flicker
				lamp[6] = fields >= 7 && p4[6][0] == 'f' ? 1.0 : fields >= 7 && p4[6][0] == 's' ? 2.0 : 0.0;
				lamp[7] = fields >= 8 ? StringToFloat(p4[7]) : 1.0;   // glow size multiplier
				lamp[0] = StringToFloat(p4[0]);
				lamp[1] = StringToFloat(p4[1]);
				lamp[2] = StringToFloat(p4[2]);
				// an upper-case kind is a fixture we placed: it always lights (+10)
				int c = CharToLower(p4[3][0]);
				lamp[3] = (c == 'p' ? 0.0 : c == 'w' ? 1.0 : c == 'l' ? 3.0 : c == 't' ? 4.0 : c == 'x' ? 5.0 : c == 'y' ? 6.0 : c == 'c' ? 7.0 : c == 'b' ? 1.0 : c == 'g' ? 8.0 : 2.0) + (IsCharUpper(p4[3][0]) ? 10.0 : 0.0);
				g_hLamps.PushArray(lamp);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
	}
	if (kv.JumpToKey("lamp_props"))
	{
		g_hLampProps.Clear();
		if (kv.GotoFirstSubKey(false))
		{
			char line[160];
			do
			{
				kv.GetString(NULL_STRING, line, sizeof(line));
				if (line[0])
					g_hLampProps.PushString(line);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
	}
	if (kv.GetDataType("stinger_interval") != KvData_None)
	{
		char range[32];
		kv.GetString("stinger_interval", range, sizeof(range));
		if (ExplodeString(range, " ", parts, 2, 16) == 2)
		{
			g_fStingMin = StringToFloat(parts[0]);
			g_fStingMax = StringToFloat(parts[1]);
		}
	}
	if (kv.GetDataType("stinger_volume") != KvData_None)
		g_fStingVol = kv.GetFloat("stinger_volume");

	int blood = kv.GetNum("bloodmoon", 0);
	if (blood > 0 && GetRandomInt(1, 100) <= blood)
	{
		g_bBloodMoon = true;
		kv.GetString("bloodmoon_cc", g_sCC, sizeof(g_sCC), "materials/correction/urban_night_red.raw");
		kv.GetString("bloodmoon_fog", color, sizeof(color), "40 8 6");
		g_bFog = ParseColor(color, g_iFogColor) || g_bFog;
		LogMessage("%s: blood moon", g_sLoadedMap);
	}

	// A section's soundscape list replaces the one before it as a whole
	// (a layer option's merges into it instead, later wins per name).
	if (kv.JumpToKey("soundscapes"))
	{
		if (!g_bLayerRead)
			g_hSwap.Clear();
		if (kv.GotoFirstSubKey(false))
		{
			char from[64], to[64];
			do
			{
				kv.GetSectionName(from, sizeof(from));
				kv.GetString(NULL_STRING, to, sizeof(to));
				StringToLower(from);
				g_hSwap.SetString(from, to);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
	}
}

// A variant's "october" weight replaces its "weight" for the whole of October
// (server clock), so Halloween month leans spooky.
int VariantWeight(KeyValues kv)
{
	int weight = kv.GetNum("weight", 1);
	char month[4];
	FormatTime(month, sizeof(month), "%m");
	if (StrEqual(month, "10") && kv.GetDataType("october") != KvData_None)
		weight = kv.GetNum("october");
	return weight;
}

// kv sits on the "variants" block. A forced name wins when the map has it;
// otherwise a weighted roll.
// kv at the root: continue the running arc if this map is the next chapter of
// the same campaign, otherwise roll a new arc for this campaign (or none)
void ArcAdvance(KeyValues kv, const char[] map)
{
	if (!g_sMapCampaign[0] || g_iMapChapter <= 0 || !g_cvArcs.BoolValue)
	{
		g_sArcName[0] = g_sArcChapters[0] = '\0';
		return;
	}
	// the next chapter continues the arc; so does the SAME chapter again (the PUG setup reloads
	// map 1 right after load, sm_nightmode_reload, a crash recovery). "none" is kept as a
	// sentinel so a campaign that rolled no arc does not re-roll one at every chapter.
	bool cont = g_sArcName[0] && StrEqual(g_sMapCampaign, g_sArcCampaign)
		&& (g_iMapChapter == g_iArcChapter + 1 || g_iMapChapter == g_iArcChapter);
	if (!cont)
	{
		g_sArcName[0] = g_sArcChapters[0] = '\0';
		if (kv.JumpToKey("arcs"))
		{
			if (kv.JumpToKey(g_sMapCampaign))
			{
				int total = 0;
				if (kv.GotoFirstSubKey())
				{
					do
						total += kv.GetNum("weight", 1);
					while (kv.GotoNextKey());
					kv.GoBack();
				}
				if (total > 0)
				{
					int roll = GetRandomInt(1, total);
					if (kv.GotoFirstSubKey())
					{
						do
						{
							roll -= kv.GetNum("weight", 1);
							if (roll <= 0)
							{
								kv.GetSectionName(g_sArcName, sizeof(g_sArcName));
								kv.GetString("chapters", g_sArcChapters, sizeof(g_sArcChapters));
								break;
							}
						}
						while (kv.GotoNextKey());
						kv.GoBack();
					}
				}
				kv.GoBack();
			}
			kv.GoBack();
		}
		if (!g_sArcName[0] || StrEqual(g_sArcName, "none"))
		{
			strcopy(g_sArcName, sizeof(g_sArcName), "none");
			g_sArcChapters[0] = '\0';
		}
		if (g_sArcChapters[0])
			LogMessage("%s: campaign %s chapter %d starts arc \"%s\" (%s)", map, g_sMapCampaign, g_iMapChapter, g_sArcName, g_sArcChapters);
	}
	strcopy(g_sArcCampaign, sizeof(g_sArcCampaign), g_sMapCampaign);
	g_iArcChapter = g_iMapChapter;
}

// kv at the map's "variants": the running arc's variant for this chapter, if the map has it
bool ArcPick(KeyValues kv, char[] name, int maxlen)
{
	if (g_bRollFresh || !g_sArcChapters[0] || g_iMapChapter <= 0)
		return false;
	char toks[8][32];
	int n = ExplodeString(g_sArcChapters, " ", toks, sizeof(toks), sizeof(toks[]));
	if (g_iMapChapter > n)
		return false;
	TrimString(toks[g_iMapChapter - 1]);
	if (!toks[g_iMapChapter - 1][0] || StrEqual(toks[g_iMapChapter - 1], "*"))
		return false;   // an empty key would re-read the "variants" block itself
	if (!kv.JumpToKey(toks[g_iMapChapter - 1]))
		return false;
	int w = VariantWeight(kv);
	kv.GoBack();
	if (w <= 0)
		return false;   // an out-of-season variant (Hallow's Eve outside October)
	strcopy(name, maxlen, toks[g_iMapChapter - 1]);
	return true;
}

// The campaign lock: when this map is the next chapter (or the same chapter again) of the campaign
// the last map belonged to, and nothing forces a look, the last map's look is re-used as a force-once.
// g_sMapCampaign / g_iMapChapter already hold this map's values (read before the pick).
void ApplyCampaignLock(const char[] map)
{
	if (!g_cvCampaignLock.BoolValue || g_sForceOnce[0] || g_bRollFresh || !g_sLockForce[0])
		return;
	if (!g_sMapCampaign[0] || g_iMapChapter <= 0 || !StrEqual(g_sMapCampaign, g_sLockCampaign))
		return;
	if (g_iMapChapter != g_iLockChapter + 1 && g_iMapChapter != g_iLockChapter)
		return;
	strcopy(g_sForceOnce, sizeof(g_sForceOnce), g_sLockForce);
	g_bLockPick = true;
	LogMessage("%s: campaign lock, chapter %d keeps \"%s\"", map, g_iMapChapter, g_sLockForce);
}

// After a load: remember this map's campaign, chapter and look for the lock
void RememberLook()
{
	strcopy(g_sLockCampaign, sizeof(g_sLockCampaign), g_sMapCampaign);
	g_iLockChapter = g_iMapChapter;
	strcopy(g_sLockForce, sizeof(g_sLockForce), g_bLayered ? g_sCombo : g_sVariant);
}

bool PickVariant(KeyValues kv, char[] name, int maxlen)
{
	char forced[32], section[32];
	g_bLockPick = false;
	ApplyCampaignLock(g_sLoadedMap);
	strcopy(forced, sizeof(forced), g_sForceOnce);
	g_sForceOnce[0] = '\0';
	if (forced[0] && !g_bLockPick)
		LogMessage("%s: forced variant \"%s\" (a stored pick, not the rotation's roll)", g_sLoadedMap, forced);
	if (forced[0] && kv.JumpToKey(forced))
	{
		kv.GoBack();
		strcopy(name, maxlen, forced);
		return true;
	}
	g_cvVariant.GetString(forced, sizeof(forced));
	if (forced[0] && kv.JumpToKey(forced))
	{
		kv.GoBack();
		strcopy(name, maxlen, forced);
		return true;
	}
	if (ArcPick(kv, name, maxlen))
		return true;

	int total = 0;
	if (kv.GotoFirstSubKey())
	{
		do
			total += VariantWeight(kv);
		while (kv.GotoNextKey());
		kv.GoBack();
	}
	if (total <= 0)
		return false;

	int roll = GetRandomInt(1, total);
	if (kv.GotoFirstSubKey())
	{
		do
		{
			roll -= VariantWeight(kv);
			if (roll <= 0)
			{
				kv.GetSectionName(section, sizeof(section));
				kv.GoBack();
				strcopy(name, maxlen, section);
				return true;
			}
		}
		while (kv.GotoNextKey());
		kv.GoBack();
	}
	return false;
}

// ---------------------------------------------------------------------------
// Layers (0.8): presets + five merged layers (see the header)

int LayerIndex(const char[] name)
{
	for (int i = 0; i < sizeof(LAYERS); i++)
	{
		if (StrEqual(name, LAYERS[i], false))
			return i;
	}
	return -1;
}

// Splits a force value into a preset name and layer options: "hardrain",
// "time=night,weather=storm", "night time=night weather=storm" (commas or
// spaces, any subset, case-insensitive). Unknown layers are logged and
// ignored. True when it named anything.
bool ParseForce(const char[] value, char[] preset, int plen, char spec[5][32])
{
	preset[0] = '\0';
	for (int i = 0; i < sizeof(LAYERS); i++)
		spec[i][0] = '\0';
	char buf[256], toks[12][64], tok[64], key[32];
	strcopy(buf, sizeof(buf), value);
	ReplaceString(buf, sizeof(buf), ",", " ");
	TrimString(buf);
	if (!buf[0])
		return false;
	bool any = false;
	int n = ExplodeString(buf, " ", toks, sizeof(toks), sizeof(toks[]));
	for (int t = 0; t < n; t++)
	{
		strcopy(tok, sizeof(tok), toks[t]);
		TrimString(tok);
		if (!tok[0])
			continue;
		int eq = FindCharInString(tok, '=');
		if (eq < 0)
		{
			if (!preset[0])
			{
				strcopy(preset, plen, tok);
				any = true;
			}
			else
				LogMessage("force \"%s\": second name \"%s\" ignored", value, tok);
			continue;
		}
		strcopy(key, sizeof(key), tok);
		if (eq < sizeof(key))
			key[eq] = '\0';
		int layer = LayerIndex(key);
		if (layer < 0)
		{
			LogMessage("force \"%s\": unknown layer \"%s\" ignored", value, key);
			continue;
		}
		strcopy(spec[layer], 32, tok[eq + 1]);
		if (spec[layer][0])
			any = true;
	}
	return any;
}

// kv on a section of weighted sub-sections: a weighted roll (VariantWeight,
// so weight 0 is never picked)
bool RollSection(KeyValues kv, char[] name, int maxlen)
{
	int total = 0;
	if (kv.GotoFirstSubKey())
	{
		do
			total += g_bRollFlat ? (VariantWeight(kv) > 0 ? 1 : 0) : VariantWeight(kv);
		while (kv.GotoNextKey());
		kv.GoBack();
	}
	if (total <= 0)
		return false;
	int roll = GetRandomInt(1, total);
	if (kv.GotoFirstSubKey())
	{
		do
		{
			roll -= g_bRollFlat ? (VariantWeight(kv) > 0 ? 1 : 0) : VariantWeight(kv);
			if (roll <= 0)
			{
				kv.GetSectionName(name, maxlen);
				kv.GoBack();
				return true;
			}
		}
		while (kv.GotoNextKey());
		kv.GoBack();
	}
	return false;
}

// kv on a section: does it have a sub-section NAME (case-insensitive)? Writes
// the section's own spelling to out.
bool SubSection(KeyValues kv, const char[] name, char[] out, int maxlen)
{
	if (!name[0] || !kv.JumpToKey(name))
		return false;
	kv.GetSectionName(out, maxlen);
	kv.GoBack();
	return true;
}

// kv on the map's section (and left there): pick the preset, resolve the five
// layers and read each chosen option over the map's own settings.
void LoadLayers(KeyValues kv, const char[] map)
{
	g_bLayered = true;
	char preset[32], spec[5][32], src[256], canon[32];
	bool forced = false;
	// force-once first, then the l4d_nightmode_variant cvar
	for (int s = 0; s < 2 && !forced; s++)
	{
		if (s == 0)
		{
			g_bLockPick = false;
			ApplyCampaignLock(g_sLoadedMap);
			strcopy(src, sizeof(src), g_sForceOnce);
			g_sForceOnce[0] = '\0';
			// 2026-10-05: three matches went inconsistent mid-campaign with no lock line and no
			// command in any log; a pick is invisible at load time, so say so here
			if (src[0] && !g_bLockPick)
				LogMessage("%s: forced look \"%s\" (a stored pick, not the rotation's roll)", map, src);
		}
		else
			g_cvVariant.GetString(src, sizeof(src));
		if (!ParseForce(src, preset, sizeof(preset), spec))
			continue;
		if (preset[0] && !StrEqual(preset, "custom", false))
		{
			bool found = false;
			if (kv.JumpToKey("presets"))
			{
				found = SubSection(kv, preset, canon, sizeof(canon));
				kv.GoBack();
			}
			if (found)
				strcopy(preset, sizeof(preset), canon);
			else
			{
				LogMessage("%s: forced preset \"%s\" is not one of this map's presets, ignored", map, preset);
				preset[0] = '\0';
			}
		}
		else if (preset[0])
			strcopy(preset, sizeof(preset), "custom");
		for (int i = 0; i < sizeof(LAYERS) && !forced; i++)
			forced = spec[i][0] != '\0';
		if (preset[0])
			forced = true;
		else if (forced)
			strcopy(preset, sizeof(preset), "custom");   // a spec alone rolls the layers it leaves out
	}
	if (!forced)
	{
		for (int i = 0; i < sizeof(LAYERS); i++)
			spec[i][0] = '\0';
		preset[0] = '\0';
	}

	// the preset's own choices (a preset that names nothing rolls every layer)
	char named[5][32], ptitle[64];
	ptitle[0] = '\0';
	for (int i = 0; i < sizeof(LAYERS); i++)
		named[i][0] = '\0';
	if (kv.JumpToKey("presets"))
	{
		if (!preset[0] && !ArcPick(kv, preset, sizeof(preset)) && !RollSection(kv, preset, sizeof(preset)))
			strcopy(preset, sizeof(preset), "custom");
		if (kv.JumpToKey(preset))
		{
			for (int i = 0; i < sizeof(LAYERS); i++)
				kv.GetString(LAYERS[i], named[i], sizeof(named[]));
			kv.GetString("title", ptitle, sizeof(ptitle));
			kv.GoBack();
		}
		kv.GoBack();
	}
	strcopy(g_sVariant, sizeof(g_sVariant), preset);

	bool titleOk = ptitle[0] != '\0';
	float mult = 1.0, fogRef = 0.0, nominal = 0.0, fogMult = 1.0, defExp = 0.0;
	float fogEndMin = 0.0, fogDensMax = -1.0;   // layers that disagree on fog: closest end, highest density
	bool timeClamp = false;
	// who supplied the merged fog colour: fog_mult is for a weather/event colour
	// judged at night, not the time's own (judged at its exposure) nor a daylit one
	int fogSrc = -1;   // layer index, -1 = the map's own section
	bool fogDaylit = false;
	char titles[5][64], want[32];
	for (int i = 0; i < sizeof(LAYERS); i++)
		titles[i][0] = '\0';
	g_hStingers.Clear();   // the map's own stingers give way to the layers'
	g_bLayerRead = true;
	if (kv.JumpToKey("layers"))
	{
		bool noMoon = false;
		for (int i = 0; i < sizeof(LAYERS); i++)
		{
			if (!kv.JumpToKey(LAYERS[i]))
				continue;
			want[0] = '\0';
			if (noMoon && (i == 2 || i == 3))
			{
				// day-like times have no moon and no event
				SubSection(kv, "none", want, sizeof(want));
				if (spec[i][0] && !StrEqual(spec[i], "none", false))
					LogMessage("%s: %s=%s dropped, time \"%s\" has no_moon", map, LAYERS[i], spec[i], g_sLayer[0]);
			}
			else
			{
				if (spec[i][0])
				{
					if (SubSection(kv, spec[i], want, sizeof(want)))
					{
						if (named[i][0] && !StrEqual(named[i], want, false))
							titleOk = false;   // the preset no longer describes it
					}
					else
						LogMessage("%s: forced %s option \"%s\" not on this map, ignored", map, LAYERS[i], spec[i]);
				}
				if (!want[0] && named[i][0] && !SubSection(kv, named[i], want, sizeof(want)))
					LogMessage("%s: preset \"%s\" names %s option \"%s\", not on this map; rolled", map, preset, LAYERS[i], named[i]);
				if (!want[0])
					RollSection(kv, want, sizeof(want));
			}
			if (want[0] && kv.JumpToKey(want))
			{
				strcopy(g_sLayer[i], sizeof(g_sLayer[]), want);
				ReadSettings(kv);
				if (kv.GetDataType("exposure_mult") != KvData_None)
					mult *= kv.GetFloat("exposure_mult", 1.0);
				// fog_ref belongs to the colour it was judged with
				if (kv.GetDataType("fog_color") != KvData_None)
				{
					fogRef = kv.GetFloat("fog_ref", 0.0);
					fogSrc = i;
					fogDaylit = kv.GetNum("fog_daylit", 0) != 0;
				}
				else if (kv.GetDataType("fog_ref") != KvData_None)
					fogRef = kv.GetFloat("fog_ref");
				if (kv.GetDataType("exposure_nominal") != KvData_None)
					nominal = kv.GetFloat("exposure_nominal");
				if (kv.GetDataType("fog_mult") != KvData_None)
					fogMult = kv.GetFloat("fog_mult", 1.0);
				if (kv.GetDataType("fog_end") != KvData_None)
				{
					float fe = kv.GetFloat("fog_end");
					if (fogEndMin <= 0.0 || fe < fogEndMin)
						fogEndMin = fe;
				}
				if (kv.GetDataType("fog_density") != KvData_None)
				{
					float fd = kv.GetFloat("fog_density");
					if (fd > fogDensMax)
						fogDensMax = fd;
				}
				if (i == 0)
					timeClamp = kv.GetDataType("exposure") != KvData_None;
				else if (kv.GetDataType("exposure_default") != KvData_None)
					defExp = kv.GetFloat("exposure_default");
				if (i == 0)
					noMoon = kv.GetNum("no_moon", 0) != 0;
				kv.GetString("title", titles[i], sizeof(titles[]));
				if (StrEqual(want, "none", false) || StrEqual(titles[i], "none", false))
					titles[i][0] = '\0';
				kv.GoBack();
			}
			kv.GoBack();
		}
		kv.GoBack();
	}
	g_bLayerRead = false;

	if (fogEndMin > 0.0)
		g_fFogEnd = fogEndMin;
	if (fogDensMax >= 0.0)
		g_fFogDensity = fogDensMax;
	if (!timeClamp && defExp > 0.0)
	{
		// a stock night (no clamp) under a look that was calibrated with one: use that
		// calibration as the clamp, no multiplier (it already is the look)
		g_fExposure = defExp;
		mult = 1.0;
	}
	if (mult != 1.0)
	{
		if (g_fExposure > 0.0)
			g_fExposure *= mult;
		if (g_fExposureIn > 0.0)
			g_fExposureIn *= mult;
	}
	if (g_bFog && fogRef > 0.0)
	{
		float used = g_fExposure > 0.0 ? g_fExposure : nominal > 0.0 ? nominal : 1.0;
		// the colour scales in linear light: ratio^(1/2.2) on the 0-255 values (2026-10-04)
		float f = Pow(fogRef / used, 1.0 / 2.2);
		if (f < 0.1)
			f = 0.1;
		else if (f > 2.0)
			f = 2.0;
		if (fogSrc > 0 && !fogDaylit)
			f *= fogMult;
		int packed = 255 << 24;
		for (int c = 0; c < 3; c++)
		{
			int v = RoundToNearest(float((g_iFogColor >> (8 * c)) & 0xFF) * f);
			packed |= (v < 0 ? 0 : v > 255 ? 255 : v) << (8 * c);
		}
		g_iFogColor = packed;
	}
	if (titleOk)
		strcopy(g_sTitle, sizeof(g_sTitle), ptitle);
	else
	{
		g_sTitle[0] = '\0';
		for (int i = 0; i < sizeof(LAYERS); i++)
		{
			if (!titles[i][0])
				continue;
			if (g_sTitle[0])
				StrCat(g_sTitle, sizeof(g_sTitle), ", ");
			StrCat(g_sTitle, sizeof(g_sTitle), titles[i]);
		}
	}
	FormatEx(g_sCombo, sizeof(g_sCombo), "%s time=%s weather=%s moon=%s event=%s power=%s",
		preset, g_sLayer[0], g_sLayer[1], g_sLayer[2], g_sLayer[3], g_sLayer[4]);
	RememberLook();
}

bool ParseColor(const char[] text, int &packed)
{
	char parts[3][8];
	if (!text[0] || ExplodeString(text, " ", parts, 3, 8) != 3)
		return false;
	packed = StringToInt(parts[0]) | (StringToInt(parts[1]) << 8) | (StringToInt(parts[2]) << 16) | (255 << 24);
	return true;
}

void StringToLower(char[] s)
{
	for (int i = 0; s[i]; i++)
		s[i] = CharToLower(s[i]);
}

// ---------------------------------------------------------------------------
// Map start: lighting and sky

public void OnMapStart()
{
	for (int i = 1; i <= MaxClients; i++)
		g_bToldLook[i] = false;
	EnsureLoaded();
	g_iCC = INVALID_ENT_REFERENCE;
	g_iPostFx = INVALID_ENT_REFERENCE;
	g_sPostFxSpawned[0] = '\0';
	// before the active check: sm_nightmode_bolt works on any map
	if (g_cvBolts.BoolValue)
		PrecacheBolts(true);
	// round_start spawns it too; this covers a late load, which gets no round_start
	if (PostFxSpec())
		CreateTimer(2.5, Timer_PostFx, _, TIMER_FLAG_NO_MAPCHANGE);
	if (!g_bActive)
		return;
	if (g_sStyle[0])
		SetLightStyle(0, g_sStyle);
	ApplySky();
	PrecacheModel(LAMP_GLOW, true);
	PrecacheSound(GENERATOR_HUM, true);
	PrecacheSound(FIRE_CRACKLE, true);
	PrecacheModel(FIRE_SPRITE, true);
	char line[160], part[7][PLATFORM_MAX_PATH];
	for (int i = 0; i < g_hLampProps.Length; i++)
	{
		g_hLampProps.GetString(i, line, sizeof(line));
		if (ExplodeString(line, " ", part, 7, PLATFORM_MAX_PATH) == 7)
			PrecacheModel(part[0], true);
	}
	for (int i = 0; i < sizeof(THUNDER_FAR); i++) PrecacheScriptSound(THUNDER_FAR[i]);
	for (int i = 0; i < sizeof(THUNDER_MED); i++) PrecacheScriptSound(THUNDER_MED[i]);
	for (int i = 0; i < sizeof(THUNDER_CLOSE); i++) PrecacheScriptSound(THUNDER_CLOSE[i]);
	ScheduleLightning();
	PrecacheStingers();
	ScheduleSting();
	g_iMoon = INVALID_ENT_REFERENCE;
	if (g_sMoon[0])
		SpawnMoon(g_sMoon);
	CreateTimer(2.0, Timer_PropTint, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bPowerOut)
		CreateTimer(2.5, Timer_PowerOut, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bCCSolo)
		CreateTimer(2.5, Timer_CCSolo, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bSunOff)
		CreateTimer(2.5, Timer_SunOff, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bRainOff)
		CreateTimer(2.5, Timer_RainOff, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bLayered)
		LogMessage("%s: night mode on, preset %s, \"%s\", %d soundscape entities swapped", g_sLoadedMap, g_sCombo, g_sTitle, g_iSwapped);
	else
		LogMessage("%s: night mode on, variant \"%s\", %d soundscape entities swapped", g_sLoadedMap, g_sVariant, g_iSwapped);
}

// Blackout: the map's own light sources go dark. Everything of ours is named
// "nightmode*" and is left alone; a map's own ShowSprite/TurnOn (alarms, events)
// still works afterwards, so this is per round, not permanent.
Action Timer_PowerOut(Handle timer)
{
	if (!g_bActive || !g_bPowerOut)
		return Plugin_Stop;
	static const char CLASSES[][] = { "env_sprite", "point_spotlight", "light_dynamic", "env_lightglow", "beam_spotlight", "prop_glowing_object", "light", "light_spot" };
	static const char INPUTS[][] = { "HideSprite", "LightOff", "TurnOff", "Kill", "LightOff", "Kill", "TurnOff", "TurnOff" };
	int n = 0;
	char name[64];
	for (int c = 0; c < sizeof(CLASSES); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, CLASSES[c])) != -1)
		{
			GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
			if (strncmp(name, "nightmode", 9) == 0)
				continue;
			if (c >= 6 && !name[0])
				continue;   // an unnamed light is baked only, nothing to switch
			AcceptEntityInput(ent, INPUTS[c]);
			n++;
		}
	}
	LogMessage("%s: power out, %d map lights switched off", g_sLoadedMap, n);
	return Plugin_Stop;
}

// cc_solo: the map's own colour grades off, ours stays (named "nightmode_cc")
Action Timer_CCSolo(Handle timer)
{
	if (!g_bActive || !g_bCCSolo)
		return Plugin_Stop;
	int n = 0, ent = -1;
	char name[64];
	static const char CLASSES[][] = { "color_correction", "color_correction_volume" };
	for (int c = 0; c < sizeof(CLASSES); c++)
	{
		ent = -1;
		while ((ent = FindEntityByClassname(ent, CLASSES[c])) != -1)
		{
			GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
			if (strncmp(name, "nightmode", 9) == 0)
				continue;
			AcceptEntityInput(ent, "Disable");
			n++;
		}
	}
	LogMessage("%s: cc solo, %d map colour grades disabled", g_sLoadedMap, n);
	return Plugin_Stop;
}

// sun_off: the map's own env_sun off (ours is "nightmode_moon")
Action Timer_SunOff(Handle timer)
{
	if (!g_bActive || !g_bSunOff)
		return Plugin_Stop;
	int n = 0, ent = -1;
	char name[64];
	while ((ent = FindEntityByClassname(ent, "env_sun")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
		if (strncmp(name, "nightmode", 9) == 0)
			continue;
		AcceptEntityInput(ent, "TurnOff");
		n++;
	}
	if (n)
		LogMessage("%s: sun off, %d env_sun", g_sLoadedMap, n);
	return Plugin_Stop;
}

// rain_off: the map's own rain removed (func_precipitation; creating one crashes srcds,
// removing an existing one is an ordinary Kill)
Action Timer_RainOff(Handle timer)
{
	if (!g_bActive || !g_bRainOff)
		return Plugin_Stop;
	int n = 0, ent = -1;
	while ((ent = FindEntityByClassname(ent, "func_precipitation")) != -1)
	{
		AcceptEntityInput(ent, "Kill");
		n++;
	}
	if (n)
		LogMessage("%s: rain off, %d func_precipitation removed", g_sLoadedMap, n);
	return Plugin_Stop;
}

public void OnPluginEnd()
{
	ApplyPropTint(true);   // props back to full colour
}

public void OnMapEnd()
{
	g_sLoadedMap[0] = '\0';
	// TIMER_FLAG_NO_MAPCHANGE timers are already gone; deleting the handle
	// again at the next map start would throw and abort OnMapStart.
	g_hLightning = null;
	g_hSting = null;
	for (int i = 0; i < LADDER; i++)
		g_iLadder[i] = INVALID_ENT_REFERENCE;
	g_iHandoff = INVALID_ENT_REFERENCE;
	for (int i = 0; i <= MaxClients; i++)
		g_fIndoorSince[i] = 0.0;   // game time restarts with the map
	for (int i = 0; i < MAX_LAMPS; i++)
	{
		g_bLampOn[i] = false;   // the map's entities are gone
		g_iLampRef[i] = INVALID_ENT_REFERENCE;
		g_bLampOff[i] = false;
		g_bGlowOn[i] = false;
		g_bFadeOut[i] = false;
		g_fLevel[i] = 0.0;
	}
	g_iLastUnlit = -1;
}

public void OnConfigsExecuted()
{
	if (g_bActive)
		ApplySky();
}

void ApplySky()
{
	// l4d_nightmode_sky (test tool, !sky): a sky that overrides every look's until cleared
	char over[64];
	g_cvSkyOverride.GetString(over, sizeof(over));
	if (over[0])
		FindConVar("sv_skyname").SetString(over);
	else if (g_sSky[0])
		FindConVar("sv_skyname").SetString(g_sSky);
}

// !sky <name|off>: set the sky override and reload this map with the SAME look (a sky only
// changes on a map load), so skies can be compared on one set of settings (owner 2026-10-04)
Action Cmd_Sky(int client, int args)
{
	char map[64], name[64];
	GetCurrentMap(map, sizeof(map));
	if (args < 1)
	{
		g_cvSkyOverride.GetString(name, sizeof(name));
		ReplyToCommand(client, "[nightmode] sky override: %s (usage: !sky <skyname|off>; the pack has sky_coldstream_1_hdr, sky_coldstream_2_hdr, sky_l4d_c1_1_hdr, sky_l4d_c2m1_hdr, sky_l4d_c4m1_hdr, sky_l4d_c4m4_hdr, sky_l4d_c5_1_hdr, sky_l4d_c6m1_hdr, sky_l4d_night02_hdr, sky_l4d_predawn02_hdr, sky_day01_09_hdr; stock: sky_l4d_urban01_hdr, sky_l4d_rural02_hdr, river_hdr, docks_hdr, highrise_hdr, nighturban01_hdr, urbannightburning_hdr, urbannightstormhdr, test_moon_hdr, moonairpo)", name[0] ? name : "(none)");
		return Plugin_Handled;
	}
	GetCmdArg(1, name, sizeof(name));
	if (StrEqual(name, "off", false) || StrEqual(name, "none", false))
		name[0] = '\0';
	g_cvSkyOverride.SetString(name);
	int humans = LiveLocked();
	SetForce(g_bLayered ? g_sCombo : g_sVariant);   // keep the look, only the sky changes
	LogMessage("%L: !sky %s on %s (%s)", client, name[0] ? name : "off", map, humans ? "stored for the next map, live lock" : "reloading now");
	if (humans)
	{
		ReplyToCommand(client, "[nightmode] sky %s set for the next map (%d players on, live lock)", name[0] ? name : "off", humans);
		return Plugin_Handled;
	}
	if (client)
		PrintToChatAll("[nightmode] %N: sky %s on %s", client, name[0] ? name : "off (the look's own)", map);
	ForceChangeLevel(map, "night mode: sky test");
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Soundscapes: rename before Spawn so Precache resolves the new index

public void OnEntityCreated(int entity, const char[] classname)
{
	if (IsTintable(classname))
	{
		if (g_bActive && g_cvPropTint.FloatValue > 0.0)
			SDKHook(entity, SDKHook_SpawnPost, OnTintableSpawn);
		return;
	}
	if (strncmp(classname, "env_soundscape", 14) != 0)
		return;
	EnsureLoaded();
	if (g_bActive && g_hSwap.Size)
		SDKHook(entity, SDKHook_Spawn, OnSoundscapeSpawn);
}

Action OnSoundscapeSpawn(int entity)
{
	char name[64], to[64];
	GetEntPropString(entity, Prop_Data, "m_soundscapeName", name, sizeof(name));
	StringToLower(name);
	if (g_hSwap.GetString(name, to, sizeof(to)))
	{
		DispatchKeyValue(entity, "soundscape", to);
		g_iSwapped++;
	}
	return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Fog, exposure, color correction: map triggers keep switching these, so they
// are re-asserted every second.

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_bActive && g_bPowerOut)
		CreateTimer(2.5, Timer_PowerOut, _, TIMER_FLAG_NO_MAPCHANGE);   // the second half respawns the map's lights
	if (g_bActive && g_bCCSolo)
		CreateTimer(2.5, Timer_CCSolo, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bActive && g_bSunOff)
		CreateTimer(2.5, Timer_SunOff, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bActive && g_bRainOff)
		CreateTimer(2.5, Timer_RainOff, _, TIMER_FLAG_NO_MAPCHANGE);
	// Versus halftime restarts the round without a map load.
	if (g_bActive && g_sStyle[0])
		SetLightStyle(0, g_sStyle);
	CreateTimer(1.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_bActive && g_sTitle[0] && g_cvAnnounce.BoolValue)
		CreateTimer(8.0, Timer_Announce, _, TIMER_FLAG_NO_MAPCHANGE);
	// one game-log line per round so the site can attribute rounds to a look (owner 2026-10-04: do the
	// darker or stormy looks change survival?)
	if (g_bActive)
		LogToGame("[nightmode] look \"%s\" preset \"%s\" time=%s weather=%s moon=%s event=%s power=%s", g_sTitle, g_sVariant, g_sLayer[0], g_sLayer[1], g_sLayer[2], g_sLayer[3], g_sLayer[4]);
	else
		LogToGame("[nightmode] look \"default\" preset \"default\"");
	// the round restart removed the last round's controller with the map's entities
	if (PostFxSpec())
		CreateTimer(2.5, Timer_PostFx, _, TIMER_FLAG_NO_MAPCHANGE);
	// riverside1 (audit C1): the restart also deleted our bulbs, flames and hums (env_sprite,
	// ambient_generic), but their g_bGlowOn flags stayed on, so the second half had lit pools
	// under dark fixtures until a lamp left the glow set. Resync the flags with what exists.
	CreateTimer(1.0, Timer_LampResync, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_LampResync(Handle timer)
{
	ResyncLampFlags();
	return Plugin_Stop;
}

// clears the per-lamp flags whose entities are gone (a round restart removes them); the next
// EnsureLamps pass (every half second) respawns whatever is still wanted. One pass over the
// classes our lamp parts use instead of a name search per lamp.
void ResyncLampFlags()
{
	static const char CLASSES[][] = { "light_dynamic", "env_sprite", "ambient_generic", "prop_dynamic" };
	bool glowSeen[MAX_LAMPS];
	char tname[32];
	for (int c = 0; c < sizeof(CLASSES); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, CLASSES[c])) != -1)
		{
			GetEntPropString(ent, Prop_Data, "m_iName", tname, sizeof(tname));
			if (strncmp(tname, "nightmode_glow_", 15) != 0)
				continue;
			int i = StringToInt(tname[15]);
			if (0 <= i < MAX_LAMPS)
				glowSeen[i] = true;
		}
	}
	int fixed;
	for (int i = 0; i < MAX_LAMPS; i++)
	{
		if (g_bGlowOn[i] && !glowSeen[i])
		{
			g_bGlowOn[i] = false;
			fixed++;
		}
		if (g_bLampOn[i] && EntRefToEntIndex(g_iLampRef[i]) == INVALID_ENT_REFERENCE)
		{
			g_bLampOn[i] = false;
			g_bFadeOut[i] = false;
			g_iLampRef[i] = INVALID_ENT_REFERENCE;
			g_fLevel[i] = 0.0;
		}
	}
	if (fixed)
		LogMessage("%s: round restart removed %d lamp glows, respawning", g_sLoadedMap, fixed);
}

// What this map rolled, for anyone (chat !weather) and whispered once per map when a player joins a team
void TellLook(int client)
{
	if (!g_bActive || !g_sTitle[0])
		PrintToChat(client, "\x04Weather:\x01 the map as Valve made it");
	else if (g_bLayered && !StrEqual(g_sVariant, "custom", false))
		PrintToChat(client, "\x04Weather:\x01 %s", g_sTitle);
	else if (g_bLayered)
		PrintToChat(client, "\x04Weather:\x01 %s (%s, %s, moon %s, %s, power %s)", g_sTitle, g_sLayer[0], g_sLayer[1], g_sLayer[2], g_sLayer[3], g_sLayer[4]);
	else
		PrintToChat(client, "\x04Weather:\x01 %s", g_sTitle);
}

Action Cmd_Weather(int client, int args)
{
	if (client && IsClientInGame(client))
		TellLook(client);
	else
		ReplyToCommand(client, "[nightmode] %s", g_bActive && g_sTitle[0] ? g_sTitle : "default");
	return Plugin_Handled;
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || !g_cvTellJoin.BoolValue || g_bToldLook[client] || event.GetInt("team") < 2)
		return;
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;
	g_bToldLook[client] = true;
	CreateTimer(4.0, Timer_TellLook, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_TellLook(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		TellLook(client);
		PrintToChat(client, "\x01(!weather shows it any time)");
	}
	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	g_bToldLook[client] = false;
}

Action Timer_Announce(Handle timer)
{
	if (!g_bActive || !g_sTitle[0])
		return Plugin_Stop;
	if (g_bLayered)
		PrintToChatAll("\x04%s\x01  (time %s, weather %s, moon %s, event %s, power %s)", g_sTitle, g_sLayer[0], g_sLayer[1], g_sLayer[2], g_sLayer[3], g_sLayer[4]);
	else
		PrintToChatAll("\x04%s", g_sTitle);
	return Plugin_Stop;
}

Action Timer_Enforce(Handle timer)
{
	if (g_bActive)
	{
		ApplyTonemap();
		ApplyFog();
		ApplyColorCorrection();
	}
	EnsureLamps();
	LightHud();
	return Plugin_Continue;
}

void ApplyTonemap()
{
	if (g_fExposure <= 0.0)
		return;

	// The map's own controllers get the outdoor clamp too, for anyone the
	// ladder has not picked up yet.
	int ent = -1;
	char tname[32];
	while ((ent = FindEntityByClassname(ent, "env_tonemap_controller")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", tname, sizeof(tname));
		if (strncmp(tname, "nightmode_", 10) != 0 && !g_bIndoorStock)
			SetExposure(ent, g_fExposure);
	}

	if (g_bIndoorStock)
	{
		// Valve's auto exposure creeps down from a daylight clamp for 10+ s, so a
		// player stepping inside sits briefly on a fast-adapting controller at a
		// moderate value, then gets the map's own tonemapping.
		int ho = EntRefToEntIndex(g_iHandoff);
		if (ho == INVALID_ENT_REFERENCE)
		{
			ho = FindByName("env_tonemap_controller", "nightmode_tm_handoff");
			if (ho == -1)
				ho = CreateTonemap("nightmode_tm_handoff", g_fHandoff);
			g_iHandoff = ho == -1 ? INVALID_ENT_REFERENCE : EntIndexToEntRef(ho);
		}
		if (ho != -1 && ho != INVALID_ENT_REFERENCE)
		{
			SetExposure(ho, g_fHandoff);
			SetRate(ho, FAST_RATE);
		}
	}

	int steps = LadderSteps();
	for (int k = 0; k < steps; k++)
	{
		int tm = EntRefToEntIndex(g_iLadder[k]);
		if (tm == INVALID_ENT_REFERENCE)
		{
			FormatEx(tname, sizeof(tname), "nightmode_tm_%d", k);
			tm = FindByName("env_tonemap_controller", tname);
			if (tm == -1)
				tm = CreateTonemap(tname, LadderExposure(k));
			if (tm == -1)
				continue;
			g_iLadder[k] = EntIndexToEntRef(tm);
		}
		if (g_fAutoHi > 0.0)
		{
			// indoor_auto: the steps open from the outdoor clamp to a real
			// auto-exposure range [lo, hi], so the game meters each room itself
			float t = float(k) / float(steps - 1);
			SetExposureRange(tm, LogLerp(g_fExposure, g_fAutoLo, t), LogLerp(g_fExposure, g_fAutoHi, t));
		}
		else
			SetExposure(tm, LadderExposure(k));
		if (g_bIndoorStock)
			SetRate(tm, FAST_RATE);
	}
}

void SetRate(int ent, float rate)
{
	SetVariantFloat(rate);
	AcceptEntityInput(ent, "SetTonemapRate");
}

float LogLerp(float a, float b, float t)
{
	return Exponential(Logarithm(a, 2.718281828) * (1.0 - t) + Logarithm(b, 2.718281828) * t);
}

void SetExposureRange(int ent, float lo, float hi)
{
	SetVariantFloat(lo);
	AcceptEntityInput(ent, "SetAutoExposureMin");
	SetVariantFloat(hi);
	AcceptEntityInput(ent, "SetAutoExposureMax");
}

int LadderSteps()
{
	if (g_fAutoHi > 0.0)
		return LADDER;
	if (g_bIndoorStock)
		return 1;
	return g_fExposureIn > 0.0 && g_fExposureIn != g_fExposure ? LADDER : 1;
}

// Even steps in log space: equal ratios look like equal changes in brightness.
float LadderExposure(int k)
{
	int steps = LadderSteps();
	if (steps == 1)
		return g_fExposure;
	float t = float(k) / float(steps - 1);
	return Exponential(Logarithm(g_fExposure, 2.718281828) * (1.0 - t) + Logarithm(g_fExposureIn, 2.718281828) * t);
}

int FindByName(const char[] classname, const char[] name)
{
	int ent = -1;
	char tname[64];
	while ((ent = FindEntityByClassname(ent, classname)) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", tname, sizeof(tname));
		if (StrEqual(tname, name))
			return ent;
	}
	return -1;
}

// Ten times a second: where on the ladder each player should be (no sky = top,
// one ray of sky = halfway, more = bottom) and one step towards it. A player
// with no step yet (just joined, the map just loaded) starts on the target.
Action Timer_Indoor(Handle timer)
{
	if (!g_bActive || g_fExposure <= 0.0)
	{
		for (int i = 1; i <= MaxClients; i++)
			g_iTonemapFor[i] = INVALID_ENT_REFERENCE;
		return Plugin_Continue;
	}
	int steps = LadderSteps();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		// indoor_stock: under a roof the player keeps the map's own tonemapping
		// (Valve's auto exposure lights L4D1 interiors well; one fixed value
		// cannot suit a lit train car and a dark drainage tunnel on one map).
		if (g_bIndoorStock && g_fAutoHi <= 0.0)
		{
			if (SkyRays(i, 1) == 0)
			{
				float now = GetGameTime();
				if (g_fIndoorSince[i] <= 0.0)
					g_fIndoorSince[i] = now;
				g_iTonemapFor[i] = now - g_fIndoorSince[i] < HANDOFF_TIME ? g_iHandoff : INVALID_ENT_REFERENCE;
				g_fStep[i] = -1.0;
				continue;
			}
			g_fIndoorSince[i] = 0.0;
		}
		float target = 0.0;
		if (steps > 1)
		{
			int sky = SkyRays(i, 2);
			target = sky == 0 ? float(steps - 1) : sky == 1 ? float(steps - 1) * 0.5 : 0.0;
		}
		if (g_fStep[i] < 0.0)
			g_fStep[i] = target;
		else if (g_fStep[i] < target)
			g_fStep[i] = g_fStep[i] + STEP_PER_TICK > target ? target : g_fStep[i] + STEP_PER_TICK;
		else if (g_fStep[i] > target)
			g_fStep[i] = g_fStep[i] - STEP_PER_TICK < target ? target : g_fStep[i] - STEP_PER_TICK;
		int k = RoundToNearest(g_fStep[i]);
		if (k >= steps)
			k = steps - 1;
		g_iTonemapFor[i] = g_iLadder[k];
	}
	return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
	g_iTonemapFor[client] = INVALID_ENT_REFERENCE;
	g_fStep[client] = -1.0;
	g_fIndoorSince[client] = 0.0;
	g_bLightHud[client] = false;
	SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
}

void OnPostThinkPost(int client)
{
	if (!g_bActive)
		return;
	int ctrl = EntRefToEntIndex(g_iTonemapFor[client]);
	if (ctrl != INVALID_ENT_REFERENCE)
		SetEntPropEnt(client, Prop_Send, "m_hTonemapController", ctrl);
}

int CreateTonemap(const char[] name, float exposure)
{
	int ent = CreateEntityByName("env_tonemap_controller");
	if (ent == -1)
		return -1;
	DispatchKeyValue(ent, "targetname", name);
	DispatchSpawn(ent);
	SetExposure(ent, exposure);
	return ent;
}

void SetExposure(int ent, float exposure)
{
	SetVariantFloat(exposure);
	AcceptEntityInput(ent, "SetAutoExposureMin");
	SetVariantFloat(exposure);
	AcceptEntityInput(ent, "SetAutoExposureMax");
}

// Traces hit the world only: without this the ray starts inside the player's
// own model and stops there at distance 0.
bool WorldOnly(int entity, int mask)
{
	return entity == 0;
}

// How many of five rays (straight up, and four tilted 35 degrees) reach the
// sky, stopping once `enough` have. None = indoors; a balcony or an awning
// over a street still sees some.
int SkyRays(int client, int enough = 5)
{
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	int hits = 0;
	for (int r = 0; r < 5 && hits < enough; r++)
	{
		ang[0] = r == 0 ? -90.0 : -55.0;
		ang[1] = r * 90.0;
		ang[2] = 0.0;
		GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
		ScaleVector(dir, 8192.0);
		AddVectors(eye, dir, end);
		Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
		if (TR_DidHit(tr) && (TR_GetSurfaceFlags(tr) & SURF_SKY))
			hits++;
		delete tr;
	}
	return hits;
}

// light_dynamic brightness is an exponent (each step doubles), and the screen
// multiplies it by the tonemap exposure, so a lamp tuned on The Parish (0.33)
// came out ten times too bright on Riverbank (3.45). Each lamp steps down by
// log2 of its map's exposure over the reference: the indoor exposure when no
// sky is above the lamp, the outdoor one otherwise.
int ExposureSteps(const float pos[3])
{
	float ref = g_cvLampRefExposure.FloatValue;
	if (ref <= 0.0 || g_fExposure <= 0.0)
		return 0;
	float e = g_fExposure;
	if (g_fExposureIn > 0.0 && g_fExposureIn != g_fExposure)
	{
		// a porch light under a roof still sits where players see sky, so blend
		// by how open the lamp is instead of a yes/no "indoor"
		float open = LampOpenness(pos);
		e = Exponential(Logarithm(g_fExposureIn, 2.718281828) * (1.0 - open) + Logarithm(g_fExposure, 2.718281828) * open);
	}
	int steps = RoundToNearest(Logarithm(ref / e, 2.0));
	return steps < -6 ? -6 : steps > 2 ? 2 : steps;
}

// 0 = closed in, 1 = open sky: rays straight up and at 55 and 25 degrees up
// in eight directions; any one reaching the sky counts as open (a porch light
// under its roof is outdoors to the players standing there)
float LampOpenness(const float pos[3])
{
	float start[3], ang[3], dir[3], end[3];
	start = pos;
	start[2] -= 8.0;   // from just under the bulb, clear of the fixture's own canopy
	int hits = 0;
	for (int r = 0; r < 17 && hits < 1; r++)
	{
		ang[0] = r == 0 ? -90.0 : r <= 8 ? -55.0 : -25.0;
		ang[1] = (r % 8) * 45.0;
		ang[2] = 0.0;
		GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
		ScaleVector(dir, 8192.0);
		AddVectors(start, dir, end);
		Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
		if (TR_DidHit(tr) && (TR_GetSurfaceFlags(tr) & SURF_SKY))
			hits++;
		delete tr;
	}
	return hits > 0 ? 1.0 : 0.0;
}

// ---------------------------------------------------------------------------
// Prop tint. Physics props, dynamic props and weapons are lit by the map's baked
// daylight ambient and sun, which the exposure clamp scales straight up: at an
// exposure of 2.5 and more they clip to white while the world (lightmaps) still
// reads as night (owner, Dark Carnival 1, 2026-10-03; the lightstyle cannot help,
// it is a no-op in HDR). A render tint of (reference / exposure)^power brings them
// back toward the look they had at the reference exposure. Static props are
// vertex-lit at compile time and look right already, so they are left alone.
bool IsTintable(const char[] classname)
{
	return strncmp(classname, "prop_physics", 12) == 0 || strncmp(classname, "prop_dynamic", 12) == 0
		|| strncmp(classname, "weapon_", 7) == 0 || StrEqual(classname, "prop_door_rotating");
}

int PropTintFor(int entity)
{
	float ref = g_cvPropTint.FloatValue;
	if (ref <= 0.0 || g_fExposure <= 0.0)
		return 255;
	float pos[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
	float e = g_fExposure;
	if (g_fExposureIn > 0.0 && LampOpenness(pos) == 0.0)
		e = g_fExposureIn;
	float t = Pow(ref / e, g_cvPropTintPower.FloatValue);
	float lo = g_cvPropTintMin.FloatValue;
	if (t < lo) t = lo;
	if (t > 1.0) t = 1.0;
	return RoundToNearest(255.0 * t);
}

void TintEntity(int entity, int v)
{
	if (entity <= 0 || !IsValidEntity(entity))
		return;
	SetEntityRenderColor(entity, v, v, v, 255);
}

void ApplyPropTint(bool reset = false)
{
	bool on = !reset && g_bActive && g_cvPropTint.FloatValue > 0.0;
	int n = 0;
	char cls[32];
	for (int ent = MaxClients + 1; ent < 2048; ent++)
	{
		if (!IsValidEntity(ent) || !GetEntityClassname(ent, cls, sizeof(cls)) || !IsTintable(cls))
			continue;
		if (strncmp(cls, "weapon_", 7) == 0 && GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") > 0)
			continue;   // carried weapons stay as they are
		TintEntity(ent, on ? PropTintFor(ent) : 255);
		n++;
	}
	if (on)
		LogMessage("prop tint: %d entities, reference %.2f power %.2f (exposure %.2f / %.2f)", n, g_cvPropTint.FloatValue, g_cvPropTintPower.FloatValue, g_fExposure, g_fExposureIn);
}

Action Timer_PropTint(Handle timer)
{
	ApplyPropTint();
	return Plugin_Stop;
}

void OnTintableSpawn(int entity)
{
	if (g_bActive && g_cvPropTint.FloatValue > 0.0)
		TintEntity(entity, PropTintFor(entity));
}

void OnPropTintCvar(ConVar cv, const char[] oldv, const char[] newv)
{
	ApplyPropTint();
}

void ApplyFog()
{
	if (!g_bFog)
		return;

	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "env_fog_controller")) != -1)
	{
		CaptureFog(ent);
		SetEntProp(ent, Prop_Send, "m_fog.enable", 1);
		SetEntProp(ent, Prop_Send, "m_fog.blend", 0);
		SetEntProp(ent, Prop_Send, "m_fog.colorPrimary", g_iFogColor);
		SetEntProp(ent, Prop_Send, "m_fog.colorSecondary", g_iFogColor);
		SetEntPropFloat(ent, Prop_Send, "m_fog.start", g_fFogStart);
		SetEntPropFloat(ent, Prop_Send, "m_fog.end", g_fFogEnd);
		SetEntPropFloat(ent, Prop_Send, "m_fog.maxdensity", g_fFogDensity);
		// the far clip: Valve sets it just past the map's own fog, so a cleared day showed the
		// world popping in out of the sky (owner, Death Toll 3, 2026-10-03 22:00). No clip when
		// the fog is off or far; otherwise never closer than the fog end.
		float farz = GetEntPropFloat(ent, Prop_Send, "m_fog.farz");
		if (g_fFogDensity <= 0.0 || g_fFogEnd >= 5000.0)
			SetEntPropFloat(ent, Prop_Send, "m_fog.farz", -1.0);
		else if (farz > 0.0 && farz < g_fFogEnd * 1.25)
			SetEntPropFloat(ent, Prop_Send, "m_fog.farz", g_fFogEnd * 1.5);
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		SetEntProp(i, Prop_Send, "m_skybox3d.fog.enable", 1);
		SetEntProp(i, Prop_Send, "m_skybox3d.fog.blend", 0);
		SetEntProp(i, Prop_Send, "m_skybox3d.fog.colorPrimary", g_iFogColor);
		SetEntProp(i, Prop_Send, "m_skybox3d.fog.colorSecondary", g_iFogColor);
		SetEntPropFloat(i, Prop_Send, "m_skybox3d.fog.start", g_fFogStart * 0.0625);
		SetEntPropFloat(i, Prop_Send, "m_skybox3d.fog.end", g_fFogEnd * 0.0625);
		// the skybox kept the map's own density: a day with the world fog off (density 0, start
		// 20000) still fogged the 3D skybox past 1250 skybox units to the haze colour, which at a
		// 10-24x day exposure is white (flat white building cutouts on Dead Air / No Mercy, 2026-10-04)
		if (HasEntProp(i, Prop_Send, "m_skybox3d.fog.maxdensity"))
			SetEntPropFloat(i, Prop_Send, "m_skybox3d.fog.maxdensity", g_fFogDensity);
	}
}

void ApplyColorCorrection()
{
	if (!g_sCC[0])
		return;

	// Turn off the map's own grades so ours is the only one.
	int ent = -1;
	char other[PLATFORM_MAX_PATH];
	while ((ent = FindEntityByClassname(ent, "color_correction")) != -1)
	{
		if (EntIndexToEntRef(ent) == g_iCC)
			continue;
		char own[32];
		GetEntPropString(ent, Prop_Data, "m_iName", own, sizeof(own));
		if (strncmp(own, "nightmode_", 10) == 0)
			continue;
		GetEntPropString(ent, Prop_Send, "m_netlookupFilename", other, sizeof(other));
		if (!StrEqual(other, g_sCC))
			SetEntProp(ent, Prop_Send, "m_bEnabled", 0);
	}

	if (EntRefToEntIndex(g_iCC) != INVALID_ENT_REFERENCE)
		return;
	char tname[32];
	ent = -1;
	while ((ent = FindEntityByClassname(ent, "color_correction")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", tname, sizeof(tname));
		if (StrEqual(tname, "nightmode_cc"))
		{
			g_iCC = EntIndexToEntRef(ent);
			return;
		}
	}

	int cc = CreateEntityByName("color_correction");
	if (cc == -1)
		return;
	DispatchKeyValue(cc, "targetname", "nightmode_cc");
	DispatchKeyValue(cc, "filename", g_sCC);
	DispatchKeyValue(cc, "maxweight", "1.0");
	DispatchKeyValue(cc, "minfalloff", "-1");
	DispatchKeyValue(cc, "maxfalloff", "-1");
	DispatchKeyValue(cc, "fadeInDuration", "0");
	DispatchKeyValue(cc, "StartDisabled", "0");
	DispatchSpawn(cc);
	ActivateEntity(cc);
	AcceptEntityInput(cc, "Enable");
	g_iCC = EntIndexToEntRef(cc);
}

// ---------------------------------------------------------------------------
// Live tuning

Action Cmd_Set(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "usage: sm_nightmode_set <style|exposure|exposure_indoor|sky|fog_color|fog_start|fog_end|fog_density|cc> <value>");
		return Plugin_Handled;
	}
	char key[32], value[PLATFORM_MAX_PATH];
	GetCmdArg(1, key, sizeof(key));
	GetCmdArgString(value, sizeof(value));
	// everything after the key, so "fog_color 10 12 18" works unquoted
	int skip = FindCharInString(value, ' ');
	strcopy(value, sizeof(value), value[skip + 1]);
	StripQuotes(value);
	TrimString(value);

	g_bActive = true;
	if (StrEqual(key, "style"))
	{
		strcopy(g_sStyle, sizeof(g_sStyle), value);
		SetLightStyle(0, g_sStyle[0] ? g_sStyle : "m");
	}
	else if (StrEqual(key, "exposure"))
	{
		g_fExposure = StringToFloat(value);
		ApplyPropTint();
	}
	else if (StrEqual(key, "exposure_indoor"))
	{
		g_fExposureIn = StringToFloat(value);
		ApplyPropTint();
	}
	else if (StrEqual(key, "indoor_handoff"))
		g_fHandoff = StringToFloat(value);
	else if (StrEqual(key, "indoor_stock"))
		g_bIndoorStock = StringToInt(value) != 0;
	else if (StrEqual(key, "indoor_auto"))
	{
		char parts[2][16];
		g_fAutoLo = g_fAutoHi = 0.0;
		if (ExplodeString(value, " ", parts, 2, 16) == 2)
		{
			g_fAutoLo = StringToFloat(parts[0]);
			g_fAutoHi = StringToFloat(parts[1]);
		}
	}
	else if (StrEqual(key, "sky"))
	{
		strcopy(g_sSky, sizeof(g_sSky), value);
		ApplySky();
		ReplyToCommand(client, "[nightmode] the sky shows after a map reload");
	}
	else if (StrEqual(key, "fog_color"))
		g_bFog = ParseColor(value, g_iFogColor);
	else if (StrEqual(key, "fog_start"))
		g_fFogStart = StringToFloat(value);
	else if (StrEqual(key, "fog_end"))
		g_fFogEnd = StringToFloat(value);
	else if (StrEqual(key, "fog_density"))
		g_fFogDensity = StringToFloat(value);
	else if (StrEqual(key, "cc"))
	{
		strcopy(g_sCC, sizeof(g_sCC), value);
		int old = EntRefToEntIndex(g_iCC);
		if (old != INVALID_ENT_REFERENCE)
			RemoveEntity(old);
		g_iCC = INVALID_ENT_REFERENCE;
	}
	else
	{
		ReplyToCommand(client, "[nightmode] unknown key %s", key);
		return Plugin_Handled;
	}
	Timer_Enforce(null);
	ReplyToCommand(client, "[nightmode] %s = %s", key, value);
	return Plugin_Handled;
}

Action Cmd_Reload(int client, int args)
{
	// Same variant, fresh values from the file; changing variant takes a map
	// load (sm_nightmode_variant), as the sky and soundscapes only change then.
	// A !todmap pick held for another map (live lock) survives the reload.
	char pend[sizeof(g_sForceOnce)], pendMap[sizeof(g_sForceMap)];
	strcopy(pend, sizeof(pend), g_sForceOnce);
	strcopy(pendMap, sizeof(pendMap), g_sForceMap);
	g_sForceMap[0] = '\0';
	strcopy(g_sForceOnce, sizeof(g_sForceOnce), g_bLayered ? g_sCombo : g_sVariant);
	g_sLoadedMap[0] = '\0';
	EnsureLoaded();
	if (pendMap[0])
	{
		strcopy(g_sForceOnce, sizeof(g_sForceOnce), pend);
		strcopy(g_sForceMap, sizeof(g_sForceMap), pendMap);
	}
	int old = EntRefToEntIndex(g_iCC);
	if (old != INVALID_ENT_REFERENCE)
		RemoveEntity(old);
	g_iCC = INVALID_ENT_REFERENCE;
	PrecacheStingers();
	SetLightStyle(0, g_bActive && g_sStyle[0] ? g_sStyle : "m");
	ApplySky();
	ScheduleLightning();
	ScheduleSting();
	if (g_sMoon[0])
		SpawnMoon(g_sMoon);
	else
		RemoveMoon();
	ApplyPostFx(true);   // the postfx key may have changed (removes it when now empty)
	Timer_Enforce(null);
	ReplyToCommand(client, "[nightmode] %s: %s, variant \"%s\"", g_sLoadedMap, g_bActive ? "configured" : "no section, untouched", g_sVariant);
	return Plugin_Handled;
}

Action Cmd_Dump(int client, int args)
{
	ReplyToCommand(client, "\"%s\" variant \"%s\" active %d, %d soundscape swaps loaded, %d entities swapped, lightning %.0f-%.0f s, blood moon %d, %d stingers every %.0f-%.0f s, moon \"%s\"", g_sLoadedMap, g_sVariant, g_bActive, g_hSwap.Size, g_iSwapped, g_fLightningMin, g_fLightningMax, g_bBloodMoon, g_hStingers.Length, g_fStingMin, g_fStingMax, g_sMoon);
	if (g_bLayered)
		ReplyToCommand(client, "  preset \"%s\" layers time=%s weather=%s moon=%s event=%s power=%s, title \"%s\"",
			g_sVariant, g_sLayer[0], g_sLayer[1], g_sLayer[2], g_sLayer[3], g_sLayer[4], g_sTitle);
	ReplyToCommand(client, "  campaign \"%s\" chapter %d, arc \"%s\" (%s)", g_sMapCampaign, g_iMapChapter, g_sArcName, g_sArcChapters);
	ReplyToCommand(client, "  style \"%s\" exposure %.2f indoor %.2f sky \"%s\" cc \"%s\"", g_sStyle, g_fExposure, g_fExposureIn, g_sSky, g_sCC);
	if (g_bFog)
		ReplyToCommand(client, "  fog_color \"%d %d %d\" fog_start %.0f fog_end %.0f fog_density %.2f",
			g_iFogColor & 0xFF, (g_iFogColor >> 8) & 0xFF, (g_iFogColor >> 16) & 0xFF, g_fFogStart, g_fFogEnd, g_fFogDensity);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		int ctrl = GetEntPropEnt(i, Prop_Send, "m_PlayerFog.m_hCtrl");
		{
			float eye[3], end[3];
			GetClientEyePosition(i, eye);
			end = eye; end[2] += 8192.0;
			Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
			char surf[64];
			TR_GetSurfaceName(tr, surf, sizeof(surf));
			float hit[3];
			TR_GetEndPosition(hit, tr);
			ReplyToCommand(client, "  up ray: hit %d, dist %.0f, surface %s, flags %x", TR_DidHit(tr), hit[2] - eye[2], surf, TR_GetSurfaceFlags(tr));
			delete tr;
		}
		ReplyToCommand(client, "  %N fog ctrl %d, sky rays %d, ladder step %.2f, tonemap ctrl %d", i, ctrl, SkyRays(i), g_fStep[i], GetEntPropEnt(i, Prop_Send, "m_hTonemapController"));
		if (ctrl > 0)
			ReplyToCommand(client, "    enable %d end %.0f density %.2f color %08x", GetEntProp(ctrl, Prop_Send, "m_fog.enable"),
				GetEntPropFloat(ctrl, Prop_Send, "m_fog.end"), GetEntPropFloat(ctrl, Prop_Send, "m_fog.maxdensity"), GetEntProp(ctrl, Prop_Send, "m_fog.colorPrimary"));
	}
	int ent = -1;
	char file[PLATFORM_MAX_PATH];
	while ((ent = FindEntityByClassname(ent, "color_correction")) != -1)
	{
		GetEntPropString(ent, Prop_Send, "m_netlookupFilename", file, sizeof(file));
		ReplyToCommand(client, "  cc #%d enabled %d weight %.2f min %.0f max %.0f %s", ent, GetEntProp(ent, Prop_Send, "m_bEnabled"),
			GetEntPropFloat(ent, Prop_Send, "m_flCurWeight"), GetEntPropFloat(ent, Prop_Send, "m_MinFalloff"), GetEntPropFloat(ent, Prop_Send, "m_MaxFalloff"), file);
	}
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Lightning

void ScheduleLightning()
{
	delete g_hLightning;
	if (!g_bActive || g_fLightningMax <= 0.0)
		return;
	g_hLightning = CreateTimer(GetRandomFloat(g_fLightningMin, g_fLightningMax), Timer_Lightning, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_Lightning(Handle timer)
{
	g_hLightning = null;
	Strike(GetRandomInt(0, 2));
	ScheduleLightning();
	return Plugin_Stop;
}

Action Cmd_Strike(int client, int args)
{
	int kind = args ? GetCmdArgInt(1) : GetRandomInt(0, 2);
	kind = kind < 0 ? 0 : kind > 2 ? 2 : kind;
	float hold = args > 1 ? GetCmdArgFloat(2) : 0.0;
	if (hold > 0.0)
		Flash(kind, 0.0, hold);
	else
		Strike(kind);
	ReplyToCommand(client, "[nightmode] strike %d", kind);
	return Plugin_Handled;
}

// kind 0 far: a faint flash, thunder seconds later; 1 medium: two flickers,
// thunder after a beat; 2 close: a full flash and the crack at once.
// bolt: -1 follows l4d_nightmode_bolts (medium and close strikes only), else
// the bolt mode for this strike (0 none, 1 bolt, 2 bolt + screen glow).
void Strike(int kind, int bolt = -1)
{
	int level = kind;
	Flash(level, 0.0, 0.2);
	if (kind >= 1)
		Flash(level > 0 ? level - 1 : 0, 0.32, 0.15);
	if (bolt < 0)
		bolt = kind >= 1 ? g_cvBolts.IntValue : 0;
	if (bolt > 0)
		SpawnBolt(bolt);

	DataPack dp;
	float delay = kind == 2 ? 0.05 : kind == 1 ? GetRandomFloat(0.8, 1.8) : GetRandomFloat(2.0, 4.0);
	CreateDataTimer(delay, Timer_Thunder, dp, TIMER_FLAG_NO_MAPCHANGE);
	dp.WriteCell(kind);
}

// A flash is a fresh color_correction spawned already on and removed when it
// ends: toggling a standing one (Enable input or m_bEnabled) does not stick in
// L4D1, the entity drops back to off by itself.
void Flash(int level, float at, float length)
{
	DataPack dp;
	CreateDataTimer(at + 0.01, Timer_FlashOn, dp, TIMER_FLAG_NO_MAPCHANGE);
	dp.WriteCell(level);
	dp.WriteFloat(length);
}

Action Timer_FlashOn(Handle timer, DataPack dp)
{
	dp.Reset();
	int level = dp.ReadCell();
	float length = dp.ReadFloat();
	int ent = CreateEntityByName("color_correction");
	if (ent == -1)
		return Plugin_Stop;
	DispatchKeyValue(ent, "targetname", "nightmode_strike");
	DispatchKeyValue(ent, "filename", STRIKE_FILES[level]);
	DispatchKeyValue(ent, "maxweight", "1.0");
	DispatchKeyValue(ent, "minfalloff", "-1");
	DispatchKeyValue(ent, "maxfalloff", "-1");
	DispatchKeyValue(ent, "fadeInDuration", "0");
	DispatchKeyValue(ent, "fadeOutDuration", "0");
	DispatchKeyValue(ent, "StartDisabled", "0");
	DispatchSpawn(ent);
	ActivateEntity(ent);
	AcceptEntityInput(ent, "Enable");
	CreateTimer(length, Timer_FlashOff, EntIndexToEntRef(ent), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

Action Timer_FlashOff(Handle timer, int ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent != INVALID_ENT_REFERENCE)
		RemoveEntity(ent);
	return Plugin_Stop;
}

Action Timer_Thunder(Handle timer, DataPack dp)
{
	dp.Reset();
	int kind = dp.ReadCell();
	if (kind == 0)
		EmitGameSoundToAll(THUNDER_FAR[GetRandomInt(0, sizeof(THUNDER_FAR) - 1)]);
	else if (kind == 1)
		EmitGameSoundToAll(THUNDER_MED[GetRandomInt(0, sizeof(THUNDER_MED) - 1)]);
	else
		EmitGameSoundToAll(THUNDER_CLOSE[GetRandomInt(0, sizeof(THUNDER_CLOSE) - 1)]);
	return Plugin_Stop;
}

Action Cmd_Bolt(int client, int args)
{
	int kind = args ? GetCmdArgInt(1) : 2;
	kind = kind < 0 ? 0 : kind > 2 ? 2 : kind;
	int mode = args > 1 ? GetCmdArgInt(2) : g_cvBolts.IntValue;
	mode = mode < 1 ? 1 : mode > 2 ? 2 : mode;
	float hold = args > 2 ? GetCmdArgFloat(3) : 0.0;   // hold: keep the bolt entity this long (tour screenshots)
	g_fBoltHold = hold > 0.0 ? hold : 2.0;
	Strike(kind, mode);
	g_fBoltHold = 2.0;
	ReplyToCommand(client, "[nightmode] strike %d with a bolt (%s)", kind, mode == 2 ? "bolt + screen glow" : "bolt");
	return Plugin_Handled;
}

// Puts the bolt systems in ParticleEffectNames (what PrecacheParticleSystem does)
// so clients can resolve the entity's effect index. generic: also precache the
// pcf itself, only at map start (the engine takes precaches during map load).
void PrecacheBolts(bool generic = false)
{
	int table = FindStringTable("ParticleEffectNames");
	if (table != INVALID_STRING_TABLE)
	{
		// the tables are locked outside map load; unlock just for this
		bool locked = LockStringTables(false);
		if (FindStringIndex(table, BOLT_EFFECT) == INVALID_STRING_INDEX)
			AddToStringTable(table, BOLT_EFFECT);
		if (FindStringIndex(table, BOLT_GLOW) == INVALID_STRING_INDEX)
			AddToStringTable(table, BOLT_GLOW);
		LockStringTables(locked);
	}
	if (!generic)
		return;
	// the pcf ships in the L4D2 map pack VPKs, which a server may not mount;
	// the names alone are enough for clients that have it, so this only logs
	static bool warned;
	if (FileExists(BOLT_PCF, true))
		PrecacheGeneric(BOLT_PCF, true);
	else if (!warned)
	{
		warned = true;
		LogMessage("%s not found on the server, bolt particles rely on the clients' copy", BOLT_PCF);
	}
}

// A bolt somewhere in the sky around the survivors: 1800-3200 units out from a
// random alive human survivor (else any player, else the map origin), just
// under the sky brush above that survivor (else 1500 units over their eyes).
void SpawnBolt(int mode)
{
	if (EdictsLow())
		return;
	PrecacheBolts();
	int pool[MAXPLAYERS + 1], n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
			pool[n++] = i;
	}
	for (int i = 1; i <= MaxClients && !n; i++)
	{
		if (IsClientInGame(i))
			pool[n++] = i;
	}
	float eye[3], up[3], pos[3], ang[3], dir[3];
	if (n)
		GetClientEyePosition(pool[GetRandomInt(0, n - 1)], eye);
	up = eye;
	up[2] += 16384.0;
	TR_TraceRayFilter(eye, up, MASK_SOLID, RayType_EndPoint, NotPlayers, -1);   // -1: no self, so the world still stops it
	float top = eye[2] + 1500.0;
	if ((TR_GetSurfaceFlags() & SURF_SKY) || TR_GetFraction() >= 1.0)
	{
		TR_GetEndPosition(up);
		top = up[2] - 64.0;
		// an open ray ends far outside the map: keep the bolt inside the world box
		if (HasEntProp(0, Prop_Send, "m_WorldMaxs"))
		{
			float maxs[3];
			GetEntPropVector(0, Prop_Send, "m_WorldMaxs", maxs);
			if (top > maxs[2] - 64.0)
				top = maxs[2] - 64.0;
		}
	}
	ang[1] = GetRandomFloat(0.0, 360.0);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, GetRandomFloat(g_cvBoltNear.FloatValue, g_cvBoltFar.FloatValue));
	AddVectors(eye, dir, pos);
	pos[2] = top;
	LogMessage("%s: bolt at %.0f %.0f %.0f (eye %.0f %.0f %.0f)", g_sLoadedMap, pos[0], pos[1], pos[2], eye[0], eye[1], eye[2]);
	SpawnBoltParticle(BOLT_EFFECT, pos);
	if (mode >= 2)
		SpawnBoltParticle(BOLT_GLOW, pos);
}

void SpawnBoltParticle(const char[] effect, const float pos[3])
{
	int ent = CreateEntityByName("info_particle_system");
	if (ent == -1)
		return;
	DispatchKeyValue(ent, "targetname", "nightmode_bolt");
	DispatchKeyValue(ent, "effect_name", effect);
	DispatchKeyValue(ent, "start_active", "1");
	TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(ent);
	ActivateEntity(ent);
	AcceptEntityInput(ent, "Start");
	// Timer_FlashOff just removes the entity behind a reference
	CreateTimer(g_fBoltHold, Timer_FlashOff, EntIndexToEntRef(ent), TIMER_FLAG_NO_MAPCHANGE);
}

// ---------------------------------------------------------------------------
// Postprocess experiment: one postprocess_controller from l4d_nightmode_postfx,
// else the config key postfx

// The spec in force (cvar first), or "" for none; true when there is one.
bool PostFxSpec(char[] out = "", int maxlen = 0)
{
	char spec[96];
	g_cvPostFx.GetString(spec, sizeof(spec));
	TrimString(spec);
	if (!spec[0] && g_bActive)
		strcopy(spec, sizeof(spec), g_sPostFx);
	TrimString(spec);
	if (maxlen)
		strcopy(out, maxlen, spec);
	return spec[0] != '\0';
}

Action Timer_PostFx(Handle timer)
{
	ApplyPostFx();
	return Plugin_Stop;
}

void OnPostFxCvar(ConVar cv, const char[] oldv, const char[] newv)
{
	if (g_sLoadedMap[0])   // no map running yet (server boot): the map start spawns it
		ApplyPostFx(true);
}

void RemovePostFx()
{
	int old = EntRefToEntIndex(g_iPostFx);
	if (old != INVALID_ENT_REFERENCE)
		RemoveEntity(old);
	g_iPostFx = INVALID_ENT_REFERENCE;
	g_sPostFxSpawned[0] = '\0';
	// and any left by a plugin reload (its reference died with it)
	int ent = -1;
	char tname[32];
	while ((ent = FindEntityByClassname(ent, "postprocess_controller")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", tname, sizeof(tname));
		if (StrEqual(tname, "nightmode_postfx") && ent != old)
			RemoveEntity(ent);
	}
}

// fresh: respawn even when the standing controller already has this spec
void ApplyPostFx(bool fresh = false)
{
	char spec[96];
	PostFxSpec(spec, sizeof(spec));
	if (!fresh && spec[0] && StrEqual(spec, g_sPostFxSpawned) && EntRefToEntIndex(g_iPostFx) != INVALID_ENT_REFERENCE)
		return;   // map start and round_start both ask at a map load
	RemovePostFx();
	if (!spec[0] || EdictsLow())
		return;
	char buf[96], tok[6][16], val[6][16];
	strcopy(buf, sizeof(buf), spec);
	while (ReplaceString(buf, sizeof(buf), "  ", " ") > 0)
		continue;   // collapse runs of spaces so ExplodeString sees one per gap
	int n = ExplodeString(buf, " ", tok, sizeof(tok), sizeof(tok[]));
	for (int i = 0; i < sizeof(val); i++)
		FormatEx(val[i], sizeof(val[]), "%.3f", i < n ? StringToFloat(tok[i]) : 0.0);   // missing numbers are 0
	int ent = CreateEntityByName("postprocess_controller");
	if (ent == -1)
	{
		static bool warned;
		if (!warned)
		{
			warned = true;
			LogMessage("postprocess_controller could not be created on this game, postfx ignored");
		}
		return;
	}
	DispatchKeyValue(ent, "targetname", "nightmode_postfx");
	DispatchKeyValue(ent, "localcontraststrength", val[0]);
	DispatchKeyValue(ent, "localcontrastedgestrength", val[1]);
	DispatchKeyValue(ent, "vignettestart", val[2]);
	DispatchKeyValue(ent, "vignetteend", val[3]);
	DispatchKeyValue(ent, "vignetteblurstrength", val[4]);
	DispatchKeyValue(ent, "fadetoblackstrength", val[5]);
	DispatchKeyValue(ent, "fadetime", "0");
	DispatchKeyValue(ent, "StartDisabled", "0");
	DispatchSpawn(ent);
	ActivateEntity(ent);
	AcceptEntityInput(ent, "Enable");   // an unknown input is only a console warning
	g_iPostFx = EntIndexToEntRef(ent);
	strcopy(g_sPostFxSpawned, sizeof(g_sPostFxSpawned), spec);
}

// ---------------------------------------------------------------------------
// Moon: an env_sun glow sprite, "pitch yaw size [r g b]"

Action Cmd_Moon(int client, int args)
{
	if (args < 3 || GetCmdArgInt(3) <= 0)
	{
		RemoveMoon();
		ReplyToCommand(client, "[nightmode] moon off");
		return Plugin_Handled;
	}
	char spec[64];
	GetCmdArgString(spec, sizeof(spec));
	SpawnMoon(spec);
	ReplyToCommand(client, "[nightmode] moon %s", spec);
	return Plugin_Handled;
}

void RemoveMoon()
{
	int old = EntRefToEntIndex(g_iMoon);
	if (old == INVALID_ENT_REFERENCE)
		old = FindByName("env_sun", "nightmode_moon");   // left by a plugin reload
	if (old != -1 && old != INVALID_ENT_REFERENCE)
		RemoveEntity(old);
	g_iMoon = INVALID_ENT_REFERENCE;
}

void SpawnMoon(const char[] spec)
{
	RemoveMoon();
	if (EdictsLow())
		return;
	char p[6][16], color[32] = "200 215 255", angles[48];
	int n = ExplodeString(spec, " ", p, sizeof(p), sizeof(p[]));
	if (n < 3)
		return;
	if (n >= 6)
		FormatEx(color, sizeof(color), "%s %s %s", p[3], p[4], p[5]);
	FormatEx(angles, sizeof(angles), "0 %s 0", p[1]);
	int ent = CreateEntityByName("env_sun");
	if (ent == -1)
		return;
	DispatchKeyValue(ent, "targetname", "nightmode_moon");
	DispatchKeyValue(ent, "use_angles", "1");
	DispatchKeyValue(ent, "pitch", p[0]);
	DispatchKeyValue(ent, "angles", angles);
	DispatchKeyValue(ent, "size", p[2]);
	DispatchKeyValue(ent, "overlaysize", "-1");
	DispatchKeyValue(ent, "rendercolor", color);
	DispatchKeyValue(ent, "overlaycolor", "0 0 0");
	DispatchKeyValue(ent, "material", "sprites/light_glow02_add_noz");
	DispatchKeyValue(ent, "overlaymaterial", "sprites/light_glow02_add_noz");
	// the glow is multiplied by the tonemap exposure like everything else: at the L4D1 day's
	// 12-24x clamp a size-48 sun covered the whole sky in white (owner, Death Toll 1, 2026-10-04);
	// scale it back by the exposure so it keeps the brightness it was judged at near 1x
	char hdr[16];
	FormatEx(hdr, sizeof(hdr), "%.3f", g_fExposure > 1.0 ? (1.0 / g_fExposure < 0.05 ? 0.05 : 1.0 / g_fExposure) : 1.0);
	DispatchKeyValue(ent, "HDRColorScale", hdr);
	DispatchSpawn(ent);
	ActivateEntity(ent);
	AcceptEntityInput(ent, "TurnOn");
	g_iMoon = EntIndexToEntRef(ent);
}

// ---------------------------------------------------------------------------
// Stingers: a distant one-shot (an owl, a dog, a plane, far gunfire) from a
// point 1200-2200 units out from a random survivor, high up, loud enough to
// carry. Everyone hears the same sound from the same place.

// A stinger entry is "path" or "path@volume".
float StingerFile(int index, char[] file, int maxlen)
{
	g_hStingers.GetString(index, file, maxlen);
	int at = FindCharInString(file, '@', true);
	if (at == -1)
		return g_fStingVol;
	float vol = StringToFloat(file[at + 1]);
	file[at] = '\0';
	return vol;
}

void PrecacheStingers()
{
	char file[PLATFORM_MAX_PATH];
	for (int i = 0; i < g_hStingers.Length; i++)
	{
		StingerFile(i, file, sizeof(file));
		PrecacheSound(file);
	}
}

void ScheduleSting()
{
	delete g_hSting;
	if (!g_bActive || !g_hStingers.Length || g_fStingMax <= 0.0)
		return;
	g_hSting = CreateTimer(GetRandomFloat(g_fStingMin, g_fStingMax), Timer_Sting, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_Sting(Handle timer)
{
	g_hSting = null;
	Sting();
	ScheduleSting();
	return Plugin_Stop;
}

Action Cmd_Sting(int client, int args)
{
	if (!g_hStingers.Length)
	{
		ReplyToCommand(client, "[nightmode] this variant has no stingers");
		return Plugin_Handled;
	}
	// "human" anchors on the first human player (for listening tests)
	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));
	int anchor = 0;
	for (int i = 1; i <= MaxClients && StrEqual(arg, "human"); i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			anchor = i;
			break;
		}
	}
	char file[PLATFORM_MAX_PATH];
	Sting(file, sizeof(file), anchor);
	ReplyToCommand(client, "[nightmode] sting %s", file);
	return Plugin_Handled;
}

void Sting(char[] played = "", int maxlen = 0, int anchor = 0)
{
	int pool[MAXPLAYERS + 1], n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
			pool[n++] = i;
	}
	if (anchor)
		pool[n++] = anchor;
	if (!n)
		return;
	float pos[3], ang[3], dir[3];
	GetClientAbsOrigin(anchor ? anchor : pool[GetRandomInt(0, n - 1)], pos);
	ang[1] = GetRandomFloat(0.0, 360.0);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, GetRandomFloat(1200.0, 2200.0));
	AddVectors(pos, dir, pos);
	pos[2] += GetRandomFloat(300.0, 700.0);

	char file[PLATFORM_MAX_PATH];
	float vol = StingerFile(GetRandomInt(0, g_hStingers.Length - 1), file, sizeof(file));
	// Measured 2026-10-02 (game audio captured): at helicopter level a big dog or a
	// far explosion 1200-2200 units out sat under the ambient bed; this level carries.
	EmitSoundToAll(file, SOUND_FROM_WORLD, SNDCHAN_STATIC, SNDLEVEL_SNOWMOBILE, SND_NOFLAGS, vol, GetRandomInt(92, 106), -1, pos);
	if (maxlen)
		strcopy(played, maxlen, file);
}

// ---------------------------------------------------------------------------
// Variants

// The human count when the live lock holds (two or more humans in game), else 0.
int LiveLocked()
{
	if (!g_cvLiveLock.BoolValue)
		return 0;
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			n++;
	}
	return n >= 2 ? n : 0;
}

// Stores a force-once pick; map tags it to wait for that map (live lock only).
// Every pick replaces the one before, tagged or not.
void SetForce(const char[] value, const char[] map = "")
{
	strcopy(g_sForceOnce, sizeof(g_sForceOnce), value);
	strcopy(g_sForceMap, sizeof(g_sForceMap), map);
}

// A menu pick (!tod, !todmap, Custom...) under the live lock: stored, no reload.
void LockedPick(int client, const char[] map, const char[] force, const char[] title, int humans)
{
	char current[64];
	GetCurrentMap(current, sizeof(current));
	// Logged and announced: a pick made during a match changes the rest of the campaign for
	// both teams (the lock keeps whatever loaded), and until 2026-10-05 only the picker knew.
	if (StrEqual(map, current, false))
	{
		SetForce(force);
		LogMessage("%L picked \"%s\" for the next map on %s (live lock, %d humans)", client, force, current, humans);
		PrintToChatAll("[nightmode] %N: %s set for the next map", client, title);
		PrintToChat(client, "[nightmode] (%d players on, live lock; sm_nightmode_variant %s now reloads at once)", humans, force);
	}
	else
	{
		SetForce(force, map);
		LogMessage("%L picked \"%s\" for %s (live lock, %d humans)", client, force, map, humans);
		PrintToChat(client, "[nightmode] %s set for %s (%d players on, live lock); level not changed, use changelevel yourself when the server is free", title, map, humans);
	}
}

Action Cmd_Variant(int client, int args)
{
	char map[64], name[192], path[PLATFORM_MAX_PATH], opt[32];
	GetCurrentMap(map, sizeof(map));
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);
	KeyValues kv = new KeyValues("NightMode");
	bool section = kv.ImportFromFile(path) && kv.JumpToKey(map);
	bool layered = false;
	if (section && kv.JumpToKey("presets"))
	{
		layered = true;
		kv.GoBack();
	}
	if (args < 1)
	{
		char list[512];
		if (section && kv.JumpToKey(layered ? "presets" : "variants"))
		{
			if (kv.GotoFirstSubKey())
			{
				do
				{
					kv.GetSectionName(opt, sizeof(opt));
					Format(list, sizeof(list), "%s %s(%d)", list, opt, VariantWeight(kv));
				}
				while (kv.GotoNextKey());
				kv.GoBack();
			}
			kv.GoBack();
		}
		if (layered)
		{
			ReplyToCommand(client, "[nightmode] %s is %s; presets:%s", map, g_sCombo, list[0] ? list : " none");
			if (kv.JumpToKey("layers"))
			{
				for (int i = 0; i < sizeof(LAYERS); i++)
				{
					list[0] = '\0';
					if (kv.JumpToKey(LAYERS[i]))
					{
						if (kv.GotoFirstSubKey())
						{
							do
							{
								kv.GetSectionName(opt, sizeof(opt));
								Format(list, sizeof(list), "%s %s(%d)", list, opt, VariantWeight(kv));
							}
							while (kv.GotoNextKey());
							kv.GoBack();
						}
						kv.GoBack();
					}
					ReplyToCommand(client, "  %s:%s", LAYERS[i], list[0] ? list : " none");
				}
				kv.GoBack();
			}
			ReplyToCommand(client, "  sm_nightmode_variant <preset> | time=..,weather=..,moon=..,event=..,power=.. (any subset) | <preset> <spec> | roll");
		}
		else
			ReplyToCommand(client, "[nightmode] %s is \"%s\"; variants:%s", map, g_sVariant, list[0] ? list : " none");
		delete kv;
		return Plugin_Handled;
	}
	GetCmdArgString(name, sizeof(name));
	StripQuotes(name);
	TrimString(name);
	// a last word "now" reloads even under the live lock
	bool now = false;
	int last = FindCharInString(name, ' ', true);
	if (last > 0 && StrEqual(name[last + 1], "now", false))
	{
		now = true;
		name[last] = '\0';
		TrimString(name);
	}
	int humans = now ? 0 : LiveLocked();
	if (!StrEqual(name, "roll"))
	{
		bool found = false;
		if (layered)
		{
			// a preset name and/or a layer spec; check what we can, the load logs the rest
			char preset[32], spec[5][32];
			if (ParseForce(name, preset, sizeof(preset), spec))
			{
				found = true;
				if (preset[0] && !StrEqual(preset, "custom", false))
				{
					kv.JumpToKey("presets");
					found = SubSection(kv, preset, opt, sizeof(opt));
					kv.GoBack();
				}
				if (found && kv.JumpToKey("layers"))
				{
					for (int i = 0; i < sizeof(LAYERS); i++)
					{
						if (!spec[i][0])
							continue;
						bool has = false;
						if (kv.JumpToKey(LAYERS[i]))
						{
							has = SubSection(kv, spec[i], opt, sizeof(opt));
							kv.GoBack();
						}
						if (!has)
							ReplyToCommand(client, "[nightmode] %s has no %s option \"%s\" (ignored)", map, LAYERS[i], spec[i]);
					}
					kv.GoBack();
				}
			}
		}
		else
			found = section && kv.JumpToKey("variants") && kv.JumpToKey(name);
		if (!found)
		{
			delete kv;
			ReplyToCommand(client, "[nightmode] %s has no %s \"%s\" (sm_nightmode_variant lists them)", map, layered ? "preset" : "variant", name);
			return Plugin_Handled;
		}
		SetForce(name);
	}
	else
	{
		g_bRollFresh = true;   // "roll": the arc is skipped once too (same chapter would hand the arc look back)
		if (humans)
			SetForce("");   // "roll" for the next map: drop any stored pick
	}
	delete kv;
	LogMessage("%L: sm_nightmode_variant \"%s\" on %s (%s)", client, name, map, humans ? "stored for the next map, live lock" : "reloading now");
	if (humans)
	{
		PrintToChatAll("[nightmode] %N: %s set for the next map", client, name);
		ReplyToCommand(client, "[nightmode] %s set for the next map (%d players on, live lock); add 'now' to reload at once", name, humans);
		return Plugin_Handled;
	}
	ReplyToCommand(client, "[nightmode] reloading %s as %s", map, name);
	ForceChangeLevel(map, "night mode variant");
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Screenshot tours: spots worth a camera, with the sky rays seen from 64 units
// above each (a standing eye).

Action Cmd_Spots(int client, int args)
{
	static const char CLASSES[][] = { "env_soundscape", "env_soundscape_proxy", "env_soundscape_triggerable", "info_survivor_position", "info_player_start" };
	char name[64];
	float pos[3], end[3];
	for (int c = 0; c < sizeof(CLASSES); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, CLASSES[c])) != -1)
		{
			GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
			name[0] = '\0';
			if (c < 3)
				GetEntPropString(ent, Prop_Data, "m_soundscapeName", name, sizeof(name));
			pos[2] += 8.0;
			// drop to the floor below so the camera stands where a player would
			end = pos;
			end[2] -= 512.0;
			Handle tr = TR_TraceRayFilterEx(pos, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
			if (TR_DidHit(tr))
				TR_GetEndPosition(pos, tr);
			delete tr;
			float yaw, open = OpenestYaw(pos, yaw);
			ReplyToCommand(client, "spot %s %.0f %.0f %.0f %d %s %.0f %.0f", CLASSES[c], pos[0], pos[1], pos[2], SkyRaysAt(pos), name[0] ? name : "-", yaw, open);
		}
	}
	return Plugin_Handled;
}

int SkyRaysAt(const float feet[3])
{
	float eye[3], ang[3], dir[3], end[3];
	eye = feet;
	eye[2] += 64.0;
	int hits = 0;
	for (int r = 0; r < 5; r++)
	{
		ang[0] = r == 0 ? -90.0 : -55.0;
		ang[1] = r * 90.0;
		GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
		ScaleVector(dir, 8192.0);
		AddVectors(eye, dir, end);
		Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
		if (TR_DidHit(tr) && (TR_GetSurfaceFlags(tr) & SURF_SKY))
			hits++;
		delete tr;
	}
	return hits;
}

// The direction (of 16) with the longest clear view from a standing eye.
float OpenestYaw(const float feet[3], float &best)
{
	float eye[3], ang[3], dir[3], end[3], hit[3], most = -1.0;
	eye = feet;
	eye[2] += 64.0;
	for (int r = 0; r < 16; r++)
	{
		ang[0] = 0.0;
		ang[1] = r * 22.5;
		GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
		ScaleVector(dir, 4096.0);
		AddVectors(eye, dir, end);
		Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID, RayType_EndPoint, WorldOnly);
		TR_GetEndPosition(hit, tr);
		delete tr;
		float d = GetVectorDistance(eye, hit);
		if (d > most)
		{
			most = d;
			best = ang[1];
		}
	}
	return most;
}

// ---------------------------------------------------------------------------
// Lamps: the day maps' street lights and wall lamps are unlit models, so the
// night reads flat. Each gets a light_dynamic (a downward sodium cone under a
// street lamp head, a small warm light off a wall fixture, a white flood) and
// a glow sprite on the bulb. Round restarts wipe them, so this re-checks every
// second like the rest.

bool LampsWanted()
{
	return g_bActive && g_bLamps && g_cvLamps.BoolValue && g_hLamps.Length > 0;
}

// a room fill: a baked-light fill (902, 903 once interior) or a survey fill (905, 906)
bool IsFillCode(float wall)
{
	return (wall > 901.5 && wall < 903.5) || (wall > 904.5 && wall < 906.5);
}

void EnsureLamps()
{
	if (!LampsWanted())
	{
		RemoveLamps();
		return;
	}
	if (FindByName("prop_dynamic", "nightmode_lamp_props") == -1 && g_hLampProps.Length)
		SpawnLampProps();

	// where the people are: every human, survivors, infected and ghosts, so a
	// Hunter across the map sees the lamps near him too. Bots do not count:
	// wandering test bots kept reshuffling the lit set (owner saw lamps pop).
	float eyes[MAXPLAYERS + 1][3];
	int n = 0;
	for (int c = 1; c <= MaxClients; c++)
	{
		if (IsClientInGame(c) && !IsFakeClient(c))
			GetClientEyePosition(c, eyes[n++]);
	}

	int count = g_hLamps.Length > MAX_LAMPS ? MAX_LAMPS : g_hLamps.Length;
	int max = g_iLampMaxVariant > 0 ? g_iLampMaxVariant : g_cvLampMax.IntValue;
	float dist[MAX_LAMPS], lamp[8];
	int order[MAX_LAMPS], k = 0;
	for (int i = 0; i < count; i++)
	{
		g_hLamps.GetArray(i, lamp);
		float best = 999999.0;
		for (int e = 0; e < n; e++)
		{
			float d = SquareRoot(Pow(lamp[0] - eyes[e][0], 2.0) + Pow(lamp[1] - eyes[e][1], 2.0) + Pow(lamp[2] - eyes[e][2], 2.0));
			if (d < best)
				best = d;
		}
		if (((lamp[4] > 901.5 && lamp[4] < 902.5) || (lamp[4] > 904.5 && lamp[4] < 905.5)) && !g_bLampOff[i])
		{
			// a baked-light fill (yaw 902): interiors only, decided once per map. A survey
			// fill (905) was placed where the survey camera saw no sky and is always kept:
			// its own sky rays escaped through the mall bathroom door into the skylit
			// atrium and dropped it (2026-10-03).
			float at[3];
			at[0] = lamp[0]; at[1] = lamp[1]; at[2] = lamp[2];
			if (lamp[4] < 904.5 && LampOpenness(at) > 0.0)
				g_bLampOff[i] = true;
			else
			{
				lamp[4] = lamp[4] > 904.5 ? 906.0 : 903.0;   // an interior fill: hangs like 900, but no bulb sprite (906: survey fill)
				g_hLamps.SetArray(i, lamp);
			}
		}
		if (g_bLampOff[i] || RoundToNearest(lamp[3]) % 10 == 8)
			best = 999999.0;   // removed with !unlight (or a baked fill that sees sky), or a glow-only bulb
		if (g_iLampMode == 2 && !IsFillCode(lamp[4]))
			best = 999999.0;   // blackout: only the room fills stay on
		// a lamp nobody can see (behind a wall, or back down the street) ranks as
		// twice as far, so it gives its slot to one in view (owner: free them as we
		// walk away so the next ones come on sooner)
		if (best < LAMP_RANGE && !LampSeen(lamp, eyes, n))
			best *= 2.0;
		// a lit lamp holds on a little past its switch-on distance; the fade
		// covers the rest (was 0.7 before lights faded)
		dist[i] = g_bLampOn[i] && !g_bFadeOut[i] ? best * 0.85 : best;
		if (dist[i] < LAMP_RANGE)
			order[k++] = i;
	}
	// nearest first (a simple insertion sort: a few dozen candidates)
	for (int x = 1; x < k; x++)
	{
		int v = order[x], y = x - 1;
		while (y >= 0 && dist[order[y]] > dist[v])
		{
			order[y + 1] = order[y];
			y--;
		}
		order[y + 1] = v;
	}
	bool want[MAX_LAMPS];
	for (int x = 0; x < k && x < max; x++)
		want[order[x]] = true;

	// bulbs (sprites, flames, hums) have no engine cap: every lamp within
	// GLOW_RANGE keeps its bulb lit, so walking along only the pools change
	bool wantGlow[MAX_LAMPS];
	int gorder[MAX_LAMPS], gk = 0, gmax = g_cvGlowMax.IntValue;
	float gdist[MAX_LAMPS];
	for (int i = 0; i < count; i++)
	{
		if (g_bLampOff[i])
			continue;
		g_hLamps.GetArray(i, lamp);
		if (g_iLampMode == 2 && !IsFillCode(lamp[4]))
			continue;   // blackout: no bulb glows either
		float best = 999999.0;
		for (int e = 0; e < n; e++)
		{
			float d = SquareRoot(Pow(lamp[0] - eyes[e][0], 2.0) + Pow(lamp[1] - eyes[e][1], 2.0) + Pow(lamp[2] - eyes[e][2], 2.0));
			if (d < best)
				best = d;
		}
		gdist[i] = g_bGlowOn[i] ? best * 0.85 : best;
		if (gdist[i] < GLOW_RANGE)
			gorder[gk++] = i;
	}
	for (int x = 1; x < gk; x++)
	{
		int v = gorder[x], y = x - 1;
		while (y >= 0 && gdist[gorder[y]] > gdist[v])
		{
			gorder[y + 1] = gorder[y];
			y--;
		}
		gorder[y + 1] = v;
	}
	for (int x = 0; x < gk && x < gmax; x++)
		wantGlow[gorder[x]] = true;

	char name[32];
	for (int i = 0; i < count; i++)
	{
		if (wantGlow[i] && !g_bGlowOn[i])
		{
			// riverside1 (audit C4): SpawnLamp builds nothing while the edict guard holds, so
			// only flag the glow on when it was built; otherwise the next pass tries again
			if (!EdictsLow())
			{
				SpawnLampPart(i, false, true);
				g_bGlowOn[i] = true;
			}
		}
		else if (!wantGlow[i] && g_bGlowOn[i])
		{
			FormatEx(name, sizeof(name), "nightmode_glow_%d", i);
			RemoveNamed(name, true);
			g_bGlowOn[i] = false;
		}

		bool alive = g_bLampOn[i] && EntRefToEntIndex(g_iLampRef[i]) != INVALID_ENT_REFERENCE;
		if (want[i])
		{
			if (!alive)
			{
				FormatEx(name, sizeof(name), "nightmode_lamp_%d", i);
				RemoveNamed(name, true);   // anything a round restart left half-built
				SpawnLampPart(i, true, false);
				g_bLampOn[i] = true;
				g_fLevel[i] = 0.0;
				int ent = EntRefToEntIndex(g_iLampRef[i]);
				char cls[24];
				if (ent > 0 && GetEntityClassname(ent, cls, sizeof(cls)) && StrEqual(cls, "light_dynamic"))
				{
					g_iFullExp[i] = GetEntProp(ent, Prop_Send, "m_Exponent");
					g_fFullSpot[i] = GetEntPropFloat(ent, Prop_Send, "m_SpotRadius");
					ApplyLampLevel(i);
				}
				else
					g_fLevel[i] = 1.0;
			}
			g_bFadeOut[i] = false;
		}
		else if (g_bLampOn[i])
			g_bFadeOut[i] = true;   // Timer_LampFade dims it, then removes it
	}
}

// spawns one lamp's light (named nightmode_lamp_<i>) and/or its bulb pieces
// (nightmode_glow_<i>); the half not wanted is built under a scratch name and
// removed at once, so SpawnLamp keeps one code path
void SpawnLampPart(int i, bool light, bool glow)
{
	float lamp[8];
	g_hLamps.GetArray(i, lamp);
	if (lamp[3] >= 10.0)
		lamp[3] -= 10.0;   // the "placed by a mark" flag, not part of the kind
	if (light)
		FormatEx(g_sLampName, sizeof(g_sLampName), "nightmode_lamp_%d", i);
	else
		strcopy(g_sLampName, sizeof(g_sLampName), "nightmode_scratch");
	if (glow)
		FormatEx(g_sGlowName, sizeof(g_sGlowName), "nightmode_glow_%d", i);
	else
		strcopy(g_sGlowName, sizeof(g_sGlowName), "nightmode_scratch");
	SpawnLamp(lamp);
	if (light)
		g_iLampRef[i] = FirstNamed(g_sLampName);
	RemoveNamed("nightmode_scratch", true);
	strcopy(g_sLampName, sizeof(g_sLampName), "nightmode_lamp");
	strcopy(g_sGlowName, sizeof(g_sGlowName), "nightmode_glow");
}

// brightness is an exponent, so the fade steps it (each step halves) while the
// pool grows: at level 0 a lamp is about 1/32 of itself with a quarter-size pool
void ApplyLampLevel(int i)
{
	int ent = EntRefToEntIndex(g_iLampRef[i]);
	if (ent <= 0)
		return;
	float lv = g_fLevel[i] < 0.03125 ? 0.03125 : g_fLevel[i];
	SetEntProp(ent, Prop_Send, "m_Exponent", g_iFullExp[i] + RoundToNearest(Logarithm(lv, 2.0)));
	SetEntPropFloat(ent, Prop_Send, "m_SpotRadius", g_fFullSpot[i] * (0.25 + 0.75 * g_fLevel[i]));
}

Action Timer_LampFade(Handle timer)
{
	// a second lamp pick between Timer_Enforce's, so the set follows the
	// player every half second
	static int tick;
	if (++tick % 10 == 5 && g_bActive)
		EnsureLamps();
	for (int i = 0; i < MAX_LAMPS; i++)
	{
		if (!g_bLampOn[i])
			continue;
		if (g_bFadeOut[i])
		{
			g_fLevel[i] -= 0.1 / FADE_OUT;
			if (g_fLevel[i] <= 0.0)
			{
				char name[32];
				FormatEx(name, sizeof(name), "nightmode_lamp_%d", i);
				RemoveNamed(name, true);
				g_bLampOn[i] = false;
				g_bFadeOut[i] = false;
				g_iLampRef[i] = INVALID_ENT_REFERENCE;
				g_fLevel[i] = 0.0;
				continue;
			}
		}
		else if (g_fLevel[i] < 1.0)
			g_fLevel[i] = g_fLevel[i] + 0.1 / FADE_IN > 1.0 ? 1.0 : g_fLevel[i] + 0.1 / FADE_IN;
		else
			continue;
		ApplyLampLevel(i);
	}
	return Plugin_Continue;
}

// any human eye with a clear line to the lamp (world brushes only; props do not block)
bool LampSeen(const float lamp[8], const float eyes[MAXPLAYERS + 1][3], int n)
{
	float at[3];
	for (int e = 0; e < n; e++)
	{
		// stop a few units short so the lamp's own wall does not count as a block
		float d = SquareRoot(Pow(lamp[0] - eyes[e][0], 2.0) + Pow(lamp[1] - eyes[e][1], 2.0) + Pow(lamp[2] - eyes[e][2], 2.0));
		if (d > LAMP_RANGE)
			continue;
		float f = d > 12.0 ? (d - 12.0) / d : 0.0;
		for (int k = 0; k < 3; k++)
			at[k] = eyes[e][k] + (lamp[k] - eyes[e][k]) * f;
		Handle tr = TR_TraceRayFilterEx(eyes[e], at, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
		bool hit = TR_DidHit(tr);
		delete tr;
		if (!hit)
			return true;
	}
	return false;
}

// any entity of ours with this name (the light, sprite or sound of one lamp)
int FirstNamed(const char[] name)
{
	static const char CLASSES[][] = { "light_dynamic", "env_sprite", "ambient_generic" };
	for (int c = 0; c < sizeof(CLASSES); c++)
	{
		int ent = FindByName(CLASSES[c], name);
		if (ent != -1)
			return EntIndexToEntRef(ent);
	}
	return INVALID_ENT_REFERENCE;
}

void RemoveLamp(int i)
{
	char name[32];
	FormatEx(name, sizeof(name), "nightmode_lamp_%d", i);
	RemoveNamed(name, true);
	FormatEx(name, sizeof(name), "nightmode_glow_%d", i);
	RemoveNamed(name, true);
	g_bLampOn[i] = false;
	g_bGlowOn[i] = false;
	g_bFadeOut[i] = false;
	g_iLampRef[i] = INVALID_ENT_REFERENCE;
}

// removes our entities whose name is `name` (exact) or starts with it (prefix)
void RemoveNamed(const char[] name, bool exact)
{
	static const char CLASSES[][] = { "light_dynamic", "env_sprite", "prop_dynamic", "ambient_generic" };
	char tname[32];
	int len = strlen(name);
	for (int c = 0; c < sizeof(CLASSES); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, CLASSES[c])) != -1)
		{
			GetEntPropString(ent, Prop_Data, "m_iName", tname, sizeof(tname));
			if (exact ? !StrEqual(tname, name) : strncmp(tname, name, len) != 0)
				continue;
			if (c == 3)
				AcceptEntityInput(ent, "StopSound");   // a looping hum would play on
			RemoveEntity(ent);
		}
	}
}

void RemoveLamps()
{
	RemoveNamed("nightmode_lamp", false);
	RemoveNamed("nightmode_glow", false);
	for (int i = 0; i < MAX_LAMPS; i++)
	{
		g_bGlowOn[i] = false;
		g_bFadeOut[i] = false;
		g_bLampOn[i] = false;
		g_iLampRef[i] = INVALID_ENT_REFERENCE;
	}
}

// fixtures the map lacks (owner marks): non-solid lamp models, up whenever
// lamps are on at all (they are the physical lamp, cheap, no light of their own)
void SpawnLampProps()
{
	char line[160], part[7][PLATFORM_MAX_PATH];
	for (int i = 0; i < g_hLampProps.Length; i++)
	{
		g_hLampProps.GetString(i, line, sizeof(line));
		if (ExplodeString(line, " ", part, 7, PLATFORM_MAX_PATH) != 7)
			continue;
		int prop = CreateEntityByName("prop_dynamic");
		if (prop == -1)
			continue;
		float o[3], ang[3];
		for (int k = 0; k < 3; k++)
		{
			o[k] = StringToFloat(part[1 + k]);
			ang[k] = StringToFloat(part[4 + k]);
		}
		DispatchKeyValue(prop, "targetname", "nightmode_lamp_props");
		DispatchKeyValue(prop, "model", part[0]);
		DispatchKeyValue(prop, "solid", "0");
		DispatchKeyValue(prop, "disableshadows", "1");
		TeleportEntity(prop, o, ang, NULL_VECTOR);
		DispatchSpawn(prop);
	}
}

// Edict guard (owed since the c2m2 ED_Alloc crash 2026-10-03 00:33): the engine has 2048 edicts and
// a Sys_Error when they run out; freed ones stay unusable for about a second. Nothing of ours is
// spawned once the map is this full; a lamp that misses its turn is picked again on the next pass.
#define EDICT_GUARD 1900
bool EdictsLow()
{
	if (GetEntityCount() < EDICT_GUARD)
		return false;
	static float lastLog;
	if (GetGameTime() - lastLog > 30.0)
	{
		lastLog = GetGameTime();
		LogMessage("%s: %d entities, lamp spawns held (edict guard %d)", g_sLoadedMap, GetEntityCount(), EDICT_GUARD);
	}
	return true;
}

void SpawnLamp(const float lamp[8])
{
	if (EdictsLow())
		return;
	int kind = RoundToNearest(lamp[3]);
	if (kind == 5 || kind == 6)
	{
		SpawnFireLamp(lamp, kind == 5);
		return;
	}
	if (kind == 8)
	{
		SpawnBulbGlow(lamp);
		return;
	}
	bool tower = kind == 4;
	bool ceiling = kind == 7;
	if (ceiling)
		kind = 1;   // lights like a wall lamp, then reshaped below
	if (tower)
	{
		// a light tower lights like a flood (aimed out the way its panels
		// face, see below), and its generator hums
		SpawnHum(lamp);
		kind = 2;
	}
	float pos[3];
	pos[0] = lamp[0];
	pos[1] = lamp[1];
	pos[2] = lamp[2];

	int light = CreateEntityByName("light_dynamic");
	if (light == -1)
		return;
	float down[3];
	char bright[8], reach[12];
	int b = g_cvLampBright.IntValue + RoundToNearest(lamp[5]) + ExposureSteps(pos);
	float r = g_cvLampReach.FloatValue;
	// dynamic lights have no shadows: an indoor lamp's reach runs through the
	// wall into the next room (owner: a bathroom lit by the one next door)
	if (g_cvIndoorReach.FloatValue < 1.0 && LampOpenness(pos) == 0.0)
		r *= g_cvIndoorReach.FloatValue;
	// a survey fill (905/906: a soft light under the ceiling of a room with no baked
	// light) aims at the floor ~130 under it; with the indoor reach (144) the pool
	// faded by (1 - 130/144)^2 to nothing (owner: the mall bathrooms "still very
	// dark" with a fill in them, 2026-10-03). Its own reach puts the floor early
	// on the aim line.
	if (lamp[4] >= 904.5 && lamp[4] < 906.5)
	{
		r = 700.0;
		b -= 1;   // the bare floor pool at full step read hot on the mall tiles (probe 2026-10-03 08:19)
	}
	// per-lamp variety (owner: "not all just blasting"): a fixed tint, some
	// dimmer bulbs, a few flickers, picked from the lamp's position so a lamp
	// looks the same every round. Lamps the owner tuned keep what he gave them.
	// a survey fill (905/906, fills.py) is a deliberate room light: no random dim, flicker or pool cut
	bool fill = lamp[4] >= 904.5 && lamp[4] < 906.5;
	bool tuned = lamp[5] != 0.0 || lamp[6] != 0.0 || fill;
	int hash = LampHash(lamp);
	char tint[16];
	LampTint(hash, kind, ceiling, lamp[4] >= 900.0 && lamp[4] < 1000.0, tint, sizeof(tint));
	int fx = RoundToNearest(lamp[6]);
	if (!tuned)
	{
		b -= DimSteps(hash);
		int fl = (hash / 10000) % 100;
		fx = fl < (ceiling ? 8 : 6) ? 2 : fl < (ceiling ? 11 : 8) ? 1 : 0;   // 2 gentle, 1 failing
	}
	DispatchKeyValue(light, "targetname", g_sLampName);
	if (kind == 0 || kind == 3)
	{
		// street lamp: sodium orange; parking-lot light: neutral white
		DispatchKeyValue(light, "_light", kind == 0 ? "255 160 80 255" : "235 228 210 255");
		if (kind == 3)
		{
			// 45 degrees landed the pool a pole-height away, so it aims nearly straight
			// down now; the shorter path made it "super bright" at b+1 (owner, in game)
			b -= 1;
			r *= 1.3;
		}
		IntToString(b, bright, sizeof(bright));
		FloatToString(r, reach, sizeof(reach));
		DispatchKeyValue(light, "brightness", bright);
		DispatchKeyValue(light, "distance", reach);
		// parking-lot heads throw a tighter pool than street lamps (owner, in game)
		char cone[8], inner[8];
		float lot = g_cvLotCone.FloatValue;
		FloatToString(kind == 3 ? lot : 75.0, cone, sizeof(cone));
		FloatToString(kind == 3 ? lot * 0.5 : 40.0, inner, sizeof(inner));
		DispatchKeyValue(light, "_inner_cone", inner);
		DispatchKeyValue(light, "_cone", cone);
		DispatchKeyValue(light, "spotlight_radius", kind == 3 ? "600" : "420");
		down[0] = kind == 3 ? g_cvLotPitch.FloatValue : g_cvLampPitch.FloatValue;
	}
	else if (kind == 1)
	{
		DispatchKeyValue(light, "_light", "255 185 120 255");
		// two steps down was a quarter of a street lamp and read as nothing (owner, in game)
		IntToString(b, bright, sizeof(bright));
		FloatToString(r * 0.6, reach, sizeof(reach));
		DispatchKeyValue(light, "brightness", bright);
		DispatchKeyValue(light, "distance", reach);
	}
	else
	{
		DispatchKeyValue(light, "_light", "215 225 255 255");
		IntToString(b, bright, sizeof(bright));
		FloatToString(r * 1.2, reach, sizeof(reach));
		DispatchKeyValue(light, "brightness", bright);
		DispatchKeyValue(light, "distance", reach);
	}
	if (kind == 1 || kind == 2)
	{
		// light_dynamic lights the WORLD only through a second light where its
		// aim line lands, sized by spotlight_radius (cone 0 and an unset radius
		// lit nothing in game). A wall lamp aims down and back into its own
		// wall so that pool sits on the wall under it; a flood aims straight down.
		char wc[8];
		FloatToString(g_cvWallCone.FloatValue, wc, sizeof(wc));
		DispatchKeyValue(light, "_cone", wc);
		FloatToString(g_cvWallCone.FloatValue * 0.6, wc, sizeof(wc));
		DispatchKeyValue(light, "_inner_cone", wc);
		DispatchKeyValue(light, "spotlight_radius", kind == 1 ? "200" : "380");
		down[0] = kind == 1 ? 55.0 : 90.0;
		down[1] = kind == 1 ? lamp[4] : 0.0;
		if (kind == 1 && lamp[4] >= 900.5 && lamp[4] < 901.5)
		{
			// wall yaw 901 = a lamp standing on a table or counter: the pool landed a
			// few units under the bulb and burnt the counter white (Plank Country)
			DispatchKeyValue(light, "spotlight_radius", "220");
			IntToString(b - 3, bright, sizeof(bright));
			DispatchKeyValue(light, "brightness", bright);
			down[0] = 90.0;
			down[1] = 0.0;
		}
		else if (kind == 1 && lamp[4] >= 3000.0)
		{
			// wall yaw 3000 + yaw = a sconce that also lights the floor in front of it
			// (owner, Dead Center 1 hall: the halo-only sconces left it black, "try 1"):
			// the same big bulb glow and dark wall, plus a soft pool on the carpet.
			// A longer distance so the floor is early on the aim line: the client dims
			// the pool by (1 - fraction)^2 and at 144 the carpet got 6%.
			DispatchKeyValue(light, "spotlight_radius", "120");
			IntToString(b + g_cvSconceFloor.IntValue, bright, sizeof(bright));
			DispatchKeyValue(light, "brightness", bright);
			DispatchKeyValue(light, "distance", "260");
			down[0] = 62.0;
			down[1] = lamp[4] - 3000.0 + 180.0;
		}
		else if (kind == 1 && lamp[4] >= 2000.0)
		{
			// wall yaw 2000 + yaw = a wall sconce: no direction, a small dim halo
			// on the wall around the fixture (owner: "shouldn't point down or
			// anywhere, just light up around it slightly")
			// (owner, hallway: "a little more glow just around them but not on the
			// wall behind"): the light angles down and out with a small dim pool,
			// and the bulb sprite does the glowing (bigger, see below)
			DispatchKeyValue(light, "spotlight_radius", "60");
			IntToString(b - 2, bright, sizeof(bright));
			DispatchKeyValue(light, "brightness", bright);
			down[0] = 60.0;
			down[1] = lamp[4] - 2000.0 + 180.0;
		}
		else if (kind == 1 && lamp[4] >= 1000.0)
		{
			IntToString(b + 1, bright, sizeof(bright));   // owner: "slightly brighter" (vanities)
			DispatchKeyValue(light, "brightness", bright);
			// wall yaw 1000 + yaw = a light on a thin wall (hotel vanities): it aims down
			// and out onto the sink with a small pool, because a pool on the wall
			// shone through into the bedroom behind it (owner, Dead Center 1)
			DispatchKeyValue(light, "spotlight_radius", "60");
			down[0] = 60.0;
			down[1] = lamp[4] - 1000.0 + 180.0;
		}
		else if (kind == 1 && lamp[4] >= 900.0)
		{
			// wall yaw 900+ = a lantern that hangs: straight down with a wide soft
			// pool that reaches the wall behind it and the ground below (owner: aimed
			// out it left the wall dark and a hard patch at the curb)
			// wall yaw 904 = the same in a small room: a 160 pool lights the sink and
			// fades up the wall instead of washing it flat (owner, Dead Center 1 vanity)
			char hr[12];
			FloatToString(lamp[4] > 903.5 && lamp[4] < 904.5 ? 160.0 : g_cvHangRadius.FloatValue, hr, sizeof(hr));
			DispatchKeyValue(light, "spotlight_radius", hr);
			down[0] = 90.0;
			down[1] = 0.0;
		}
		if (kind == 2 && !tower && !ceiling)
		{
			// a wall flood throws light OUT across the area, not down its own wall
			// (owner: "the light doesn't travel at all"); lamp[4] is into the wall
			DispatchKeyValue(light, "_cone", "60");
			DispatchKeyValue(light, "_inner_cone", "35");
			DispatchKeyValue(light, "spotlight_radius", "400");
			FloatToString(r * 1.5, reach, sizeof(reach));
			DispatchKeyValue(light, "distance", reach);
			// 35 down landed the pool far out across the alley (owner, in game)
			down[0] = 50.0;
			down[1] = lamp[4] + 180.0;
		}
		if (ceiling)
		{
			// a hanging fluorescent: cool white, wide, straight down, two steps
			// soft with a broad pool (owner: the floor hit was too strong)
			DispatchKeyValue(light, "_light", "215 228 240 255");
			DispatchKeyValue(light, "_cone", "85");
			DispatchKeyValue(light, "_inner_cone", "40");
			DispatchKeyValue(light, "spotlight_radius", "380");
			down[0] = 90.0;
			down[1] = 0.0;
			IntToString(b - 2, bright, sizeof(bright));
			DispatchKeyValue(light, "brightness", bright);
		}
		if (tower)
		{
			// out the way the panels face, steeply down so the pool lands in
			// front of the tower, at street-lamp brightness (owner: +1, +2 too bright)
			DispatchKeyValue(light, "_cone", "80");
			DispatchKeyValue(light, "_inner_cone", "50");
			DispatchKeyValue(light, "spotlight_radius", "700");
			down[0] = 60.0;
			down[1] = lamp[4];
			IntToString(b, bright, sizeof(bright));
			DispatchKeyValue(light, "brightness", bright);
		}
	}
	// light style 6 is the engine's second flicker pattern, deeper dips than 1
	// (owner: 10, the failing fluorescent, was too fast; 1 a little too subtle)
	if (!tuned)
	{
		char col[24];
		FormatEx(col, sizeof(col), "%s 255", tint);
		DispatchKeyValue(light, "_light", col);
	}
	DispatchKeyValue(light, "style", fx == 1 ? "6" : fx == 2 ? "1" : "0");
	// an indoor pool is a point light at the aim's end and has no shadows, so a
	// big one lights the room next door through the wall (owner, Dead Center 1
	// bathrooms): indoors the pool is capped
	if (g_cvIndoorPool.FloatValue > 0.0 && !fill && LampOpenness(pos) == 0.0)   // a fill is the room's light: full pool
	{
		char sr[12];
		float cur = GetEntPropFloat(light, Prop_Send, "m_SpotRadius");
		if (cur <= 0.0 || cur > g_cvIndoorPool.FloatValue)
		{
			FloatToString(g_cvIndoorPool.FloatValue, sr, sizeof(sr));
			DispatchKeyValue(light, "spotlight_radius", sr);
		}
	}
	// The client puts the pool where the aim line (length = distance) first
	// hits the world and scales its colour by (1 - fraction)^2, centred ON the
	// surface: a lamp a few units from a wall or sink burns a white hot spot
	// (owner: the wall behind the vanity, the bathroom by Louis). Untuned lamps
	// step down until that factor is at most l4d_nightmode_pool_close.
	float cap = g_cvPoolClose.FloatValue;
	if (cap > 0.0 && !tuned)
	{
		float frac = PoolFraction(pos, down, GetEntPropFloat(light, Prop_Send, "m_Radius"));
		float fall = (1.0 - frac) * (1.0 - frac);
		if (frac < 1.0 && fall > cap)
		{
			int cut = RoundToNearest(Logarithm(fall / cap, 2.0));
			if (cut > 0)
			{
				IntToString(GetEntProp(light, Prop_Send, "m_Exponent") - cut, bright, sizeof(bright));
				DispatchKeyValue(light, "brightness", bright);
			}
		}
	}
	// The pool is a sphere with no shadows: on a roof, floor or thin wall it
	// lights the room on the other side (!light who, Dead Center 1: two roof
	// floods lit a bathroom through its ceiling). Measure how thick the surface
	// is under the pool and keep the radius inside it.
	if (g_cvPoolThin.BoolValue)
	{
		float spot = GetEntPropFloat(light, Prop_Send, "m_SpotRadius");
		if (spot > 0.0)
		{
			float nz;
			float thick = SurfaceDepth(pos, down, GetEntPropFloat(light, Prop_Send, "m_Radius"), spot, nz);
			// only where the bleed shows: an outdoor lamp (roof floods into the
			// rooms below) or a pool on a wall (the room next door). An indoor
			// pendant's pool on its floor keeps its size: shrunk to the slab it
			// was a 35-unit dot, and the bleed only lights the ceiling below.
			// Hanging lamps (wall yaw 900-904) are left alone: their aim often stops
			// on their own fixture, so the pool sits at the bulb, which is the look
			// the owner tuned on The Parish 2.
			bool hangs = kind == 1 && lamp[4] >= 899.5 && lamp[4] < 904.5;
			if (!hangs && thick > 0.0 && thick < spot && (FloatAbs(nz) < 0.5 || LampOpenness(pos) > 0.0))
			{
				char sr[12];
				FloatToString(thick < 24.0 ? 24.0 : thick, sr, sizeof(sr));
				DispatchKeyValue(light, "spotlight_radius", sr);
				if (g_bThinLog)
				{
					char tp[PLATFORM_MAX_PATH];
					BuildPath(Path_SM, tp, sizeof(tp), "logs/nightmode_thin.log");
					LogToFileEx(tp, "THIN at=%.0f,%.0f,%.0f kind=%d yaw=%.0f spot %.0f -> %s", pos[0], pos[1], pos[2], kind, lamp[4], spot, sr);
				}
			}
		}
	}
	// models take a dynamic light at full strength with no cone, so a lamp at
	// arm's length turned the player's gun white (owner): 0 = lamps light the
	// world only, 1 = models too, 2 = models only for lamps with sky above
	int lm = g_cvLightModels.IntValue;
	if (lm == 0 || (lm == 2 && LampOpenness(pos) == 0.0))
		DispatchKeyValue(light, "spawnflags", "2");
	TeleportEntity(light, pos, down, NULL_VECTOR);
	DispatchSpawn(light);
	AcceptEntityInput(light, "TurnOn");

	if (ceiling)
	{
		// a row of small glows along the tube (about 66 long, lamp[4] is its
		// axis) so it reads as a lit fluorescent, not a dot (owner)
		float ax[3], dir[3], at[3];
		ax[1] = lamp[4];
		GetAngleVectors(ax, dir, NULL_VECTOR, NULL_VECTOR);
		// nine small overlapping glows read as one line (five big ones read as dots: owner)
		for (int g = -4; g <= 4; g++)
		{
			at[0] = pos[0] + dir[0] * 6.5 * g;
			at[1] = pos[1] + dir[1] * 6.5 * g;
			at[2] = pos[2] + 4.0;   // up inside the tube
			int tube = CreateEntityByName("env_sprite");
			if (tube == -1)
				break;
			DispatchKeyValue(tube, "targetname", g_sGlowName);
			DispatchKeyValue(tube, "model", LAMP_GLOW);
			DispatchKeyValue(tube, "rendermode", "9");
			int tsteps = RoundToNearest(lamp[5]) - (tuned ? 0 : DimSteps(hash));
			char tamt[8];
			IntToString(tsteps >= 0 ? 120 : RoundToNearest(120.0 * Pow(0.65, float(-tsteps))), tamt, sizeof(tamt));
			DispatchKeyValue(tube, "renderamt", tamt);
			DispatchKeyValue(tube, "rendercolor", tuned ? "220 235 255" : GlowOf(tint));
			char tscale[12];
			FloatToString(0.07 * (lamp[7] > 0.0 ? lamp[7] : 1.0), tscale, sizeof(tscale));
			DispatchKeyValue(tube, "scale", tscale);
			DispatchKeyValue(tube, "GlowProxySize", "6");
			DispatchKeyValue(tube, "spawnflags", "1");
			TeleportEntity(tube, at, NULL_VECTOR, NULL_VECTOR);
			DispatchSpawn(tube);
			AcceptEntityInput(tube, "ShowSprite");
		}
		return;
	}

	if (lamp[4] >= 902.5 && lamp[4] < 1000.0)
		return;   // a baked-light fill has no fixture, so no bulb to glow (owner: "what is this")
	int glow = CreateEntityByName("env_sprite");
	if (glow == -1)
		return;
	DispatchKeyValue(glow, "targetname", g_sGlowName);
	DispatchKeyValue(glow, "model", LAMP_GLOW);
	// The fixture models have baked lighting that dynamic lights never touch,
	// so the glow is what makes a globe read as lit. Its visibility probe has
	// to be about the globe's size: a 4-unit probe sat inside the globe and the
	// globe hid its own glow (owner, in game).
	DispatchKeyValue(glow, "rendermode", "9");
	// the bulb dims with the lamp: each step down takes about a third off the
	// sprite (owner: a vanity four steps down still glared off the wall)
	char amt[8];
	int steps = RoundToNearest(lamp[5]) - (tuned ? 0 : DimSteps(hash));
	IntToString(steps >= 0 ? 255 : RoundToNearest(255.0 * Pow(0.65, float(-steps))), amt, sizeof(amt));
	DispatchKeyValue(glow, "renderamt", amt);
	DispatchKeyValue(glow, "rendercolor", !tuned ? GlowOf(tint) : ceiling ? "220 235 255" : kind == 2 || kind == 3 ? "230 235 250" : "255 210 160");
	char gscale[12];
	bool sconce = lamp[4] >= 2000.0;
	FloatToString((kind == 0 || kind == 3 ? 0.6 : sconce ? 0.5 : 0.3) * (lamp[7] > 0.0 ? lamp[7] : 1.0), gscale, sizeof(gscale));
	DispatchKeyValue(glow, "scale", gscale);
	DispatchKeyValue(glow, "GlowProxySize", sconce ? "4" : kind == 1 ? "12" : "24");
	if (fx > 0)
		DispatchKeyValue(glow, "renderfx", "12");   // slow flicker, with the light's

	DispatchKeyValue(glow, "spawnflags", "1");
	TeleportEntity(glow, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(glow);
	AcceptEntityInput(glow, "ShowSprite");
}

void OnLampsCvar(ConVar cv, const char[] oldv, const char[] newv)
{
	EnsureLamps();
}

// a setting baked in at spawn: rebuild every lit lamp
void OnLampsRebuild(ConVar cv, const char[] oldv, const char[] newv)
{
	RemoveLamps();
	EnsureLamps();
}

Action Cmd_Lamps(int client, int args)
{
	if (args > 0)
		g_cvLamps.SetBool(GetCmdArgInt(1) != 0);
	EnsureLamps();
	ReplyToCommand(client, "[nightmode] lamps %s (%d spots on this map, variant %s them, cap %d)", g_cvLamps.BoolValue ? "on" : "off",
		g_hLamps.Length, g_iLampMode == 2 ? "lights only the fills of" : g_bLamps ? "lights" : "does not light", g_iLampMaxVariant > 0 ? g_iLampMaxVariant : g_cvLampMax.IntValue);
	return Plugin_Handled;
}

// !light in chat (admins): quick in-game comparison of the lamps.
// how far along a lamp's aim line (as a fraction of its distance) the client's
// pool trace stops: world and static props, like the client's MASK_NPCWORLDSTATIC
float PoolFraction(const float pos[3], const float ang[3], float reach, float end[3] = NULL_VECTOR)
{
	float dir[3], to[3];
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, reach);
	AddVectors(pos, dir, to);
	Handle tr = TR_TraceRayFilterEx(pos, to, MASK_NPCWORLDSTATIC, RayType_EndPoint, WorldOnly);
	float f = TR_DidHit(tr) ? TR_GetFraction(tr) : 1.0;
	TR_GetEndPosition(end, tr);
	delete tr;
	return f;
}

// how deep the solid is behind the point a lamp's pool lands on, stepping in
// along the surface normal: the open space on the other side starts there.
// 0 = no hit, not a world brush, or solid all the way past `limit`.
float SurfaceDepth(const float pos[3], const float ang[3], float reach, float limit, float &nz = 0.0)
{
	float dir[3], to[3], end[3], n[3], p[3];
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, reach);
	AddVectors(pos, dir, to);
	Handle tr = TR_TraceRayFilterEx(pos, to, MASK_NPCWORLDSTATIC, RayType_EndPoint, WorldOnly);
	bool hit = TR_DidHit(tr);
	TR_GetEndPosition(end, tr);
	TR_GetPlaneNormal(tr, n);
	delete tr;
	nz = n[2];
	if (!hit)
		return 0.0;
	// a static prop (the fixture's own mount, a roof unit) is not solid to
	// point contents, so each line steps through it to the brush, then out the
	// far side. Straight in is not enough: a pool on top of an outer wall goes
	// down the wall for ever while the ceiling slab beside it is 32 thick
	// (Dead Center 1 roof flood), so eight lines tilted 45 degrees count too,
	// each exit scaled by cos 45 to a depth straight in.
	float t1[3], t2[3], best = 0.0;
	GetVectorVectors(n, t1, t2);
	for (int line = 0; line < 9; line++)
	{
		float dir[3], scale = 1.0;
		for (int k = 0; k < 3; k++)
			dir[k] = -n[k];
		if (line > 0)
		{
			float a = (line - 1) * 0.785398;
			for (int k = 0; k < 3; k++)
				dir[k] = (-n[k] + Cosine(a) * t1[k] + Sine(a) * t2[k]) * 0.707107;
			scale = 0.707107;
		}
		bool inside = false;
		for (float d = 2.0; d <= limit / scale; d += 4.0)
		{
			for (int k = 0; k < 3; k++)
				p[k] = end[k] + dir[k] * d;
			bool solid = (TR_GetPointContents(p) & CONTENTS_SOLID) != 0;
			if (solid)
				inside = true;
			else if (inside)
			{
				if (best == 0.0 || d * scale < best)
					best = d * scale;
				break;
			}
		}
	}
	return best;
}

// ---------------------------------------------------------------------------
// Owner menus (2026-10-03): !tod picks a time of day for the current map, !todmap
// picks campaign, map and time of day and changes level. Both go through the
// same one-shot force as sm_nightmode_variant.

static const char CAMPAIGNS[][][] = {
	{ "c1m", "Dead Center" }, { "c2m", "Dark Carnival" }, { "c3m", "Swamp Fever" }, { "c4m", "Hard Rain" },
	{ "c5m", "The Parish" }, { "c6m", "Passifice (The Passing)" }, { "l4d_river", "Passifice (Sacrifice)" },
	{ "l4d_vs_hospital", "No Mercy" }, { "l4d_vs_smalltown", "Death Toll" }, { "l4d_vs_airport", "Dead Air" }, { "l4d_vs_farm", "Blood Harvest" }
};

void VariantTitle(KeyValues kv, const char[] name, char[] out, int len)
{
	kv.GetString("title", out, len, "");
	if (!out[0])
		strcopy(out, len, name);
	int w = VariantWeight(kv);
	if (w == 0)
		Format(out, len, "%s (not rolled)", out);
}

// a menu of MAP's variants; item info = "map|variant"
Menu VariantMenu(const char[] map, const char[] heading)
{
	char path[PLATFORM_MAX_PATH], name[32], title[64], info[128];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);
	KeyValues kv = new KeyValues("NightMode");
	Menu menu = new Menu(TodMenuHandler);
	menu.SetTitle("%s", heading);
	if (kv.ImportFromFile(path) && kv.JumpToKey(map))
	{
		// layered maps list their presets, then "Custom..." (pick each layer)
		bool layered = kv.JumpToKey("presets");
		if (layered || kv.JumpToKey("variants"))
		{
			if (layered)
			{
				FormatEx(info, sizeof(info), "%s|#custom", map);   // owner: Custom on top
				menu.AddItem(info, "Custom...");
			}
			if (kv.GotoFirstSubKey())
			{
				do
				{
					kv.GetSectionName(name, sizeof(name));
					// the "custom" preset is the Custom... entry below; out-of-season presets
					// (weight 0, e.g. Hallow's Eve outside October) stay out of the menu
					if (layered && (StrEqual(name, "custom", false) || VariantWeight(kv) <= 0))
						continue;
					VariantTitle(kv, name, title, sizeof(title));
					FormatEx(info, sizeof(info), "%s|%s", map, name);
					menu.AddItem(info, title);
				}
				while (kv.GotoNextKey());
			}
		}
	}
	delete kv;
	return menu;
}

Action Cmd_Tod(int client, int args)
{
	if (client <= 0)
	{
		ReplyToCommand(client, "[nightmode] !tod is a menu: use it in game (sm_nightmode_variant <name> from the console)");
		return Plugin_Handled;
	}
	char map[64], heading[128];
	GetCurrentMap(map, sizeof(map));
	if (g_bLayered)
		FormatEx(heading, sizeof(heading), "Time of day: %s\n(now \"%s\": %s)", map, g_sVariant, g_sTitle);
	else
		FormatEx(heading, sizeof(heading), "Time of day: %s\n(now \"%s\")", map, g_sVariant[0] ? g_sVariant : "stock");
	Menu menu = VariantMenu(map, heading);
	if (menu.ItemCount == 0)
	{
		delete menu;
		PrintToChat(client, "[nightmode] %s has no night mode section", map);
		return Plugin_Handled;
	}
	menu.Display(client, MENU_TIME_FOREVER);
	return Plugin_Handled;
}

int TodMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[128], map[64], name[32], title[64];
		menu.GetItem(item, info, sizeof(info), _, title, sizeof(title));
		int bar = FindCharInString(info, '|');
		if (bar > 0)
		{
			strcopy(map, sizeof(map), info);
			map[bar] = '\0';
			strcopy(name, sizeof(name), info[bar + 1]);
			if (StrEqual(name, "#custom"))
			{
				strcopy(g_sCustomMap[client], sizeof(g_sCustomMap[]), map);
				g_sCustomSpec[client][0] = g_sCustomTime[client][0] = '\0';
				g_iCustomStep[client] = 0;
				ShowCustomStep(client);
				return 0;
			}
			int humans = LiveLocked();
			if (humans)
			{
				LockedPick(client, map, name, title, humans);
				return 0;
			}
			SetForce(name);
			LogMessage("%L: reloading %s as \"%s\" (!tod)", client, map, name);
			PrintToChatAll("[nightmode] %N: %s as %s", client, map, name);
			ForceChangeLevel(map, "night mode: time of day");
		}
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

// !tod "Custom...": one menu per layer in merge order, "(roll)" first; the
// last pick reloads the map once as that spec. A time option with no_moon
// skips the moon and event menus.
void ShowCustomStep(int client)
{
	char path[PLATFORM_MAX_PATH], name[32], title[64];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);
	KeyValues kv = new KeyValues("NightMode");
	bool ok = kv.ImportFromFile(path) && kv.JumpToKey(g_sCustomMap[client]) && kv.JumpToKey("layers");
	bool noMoon = false;
	if (ok && g_sCustomTime[client][0] && kv.JumpToKey("time"))
	{
		if (kv.JumpToKey(g_sCustomTime[client]))
		{
			noMoon = kv.GetNum("no_moon", 0) != 0;
			kv.GoBack();
		}
		kv.GoBack();
	}
	Menu menu;
	while (ok && g_iCustomStep[client] < sizeof(LAYERS))
	{
		int step = g_iCustomStep[client];
		if (!(noMoon && (step == 2 || step == 3)) && kv.JumpToKey(LAYERS[step]))
		{
			menu = new Menu(CustomMenuHandler);
			menu.SetTitle("Custom %s: %s\n%s", g_sCustomMap[client], LAYERS[step], g_sCustomSpec[client][0] ? g_sCustomSpec[client] : "(all rolled so far)");
			menu.AddItem("#roll", "(roll)");
			if (kv.GotoFirstSubKey())
			{
				do
				{
					kv.GetSectionName(name, sizeof(name));
					VariantTitle(kv, name, title, sizeof(title));
					menu.AddItem(name, title);
				}
				while (kv.GotoNextKey());
			}
			break;
		}
		g_iCustomStep[client]++;   // no such layer here (or no_moon): nothing to pick
	}
	delete kv;
	if (menu != null)
	{
		menu.Display(client, MENU_TIME_FOREVER);
		return;
	}
	if (!ok)
	{
		PrintToChat(client, "[nightmode] %s has no layers", g_sCustomMap[client]);
		return;
	}
	char force[sizeof(g_sForceOnce)];
	FormatEx(force, sizeof(force), "custom %s", g_sCustomSpec[client]);
	int humans = LiveLocked();
	if (humans)
	{
		LockedPick(client, g_sCustomMap[client], force, force, humans);
		return;
	}
	SetForce(force);
	LogMessage("%L: reloading %s as \"%s\" (!tod custom)", client, g_sCustomMap[client], force);
	PrintToChatAll("[nightmode] %N: %s as custom %s", client, g_sCustomMap[client], g_sCustomSpec[client][0] ? g_sCustomSpec[client] : "(all rolled)");
	ForceChangeLevel(g_sCustomMap[client], "night mode: time of day");
}

int CustomMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[32];
		menu.GetItem(item, info, sizeof(info));
		int step = g_iCustomStep[client];
		if (!StrEqual(info, "#roll") && step < sizeof(LAYERS))
		{
			Format(g_sCustomSpec[client], sizeof(g_sCustomSpec[]), "%s%s%s=%s", g_sCustomSpec[client], g_sCustomSpec[client][0] ? "," : "", LAYERS[step], info);
			if (step == 0)
				strcopy(g_sCustomTime[client], sizeof(g_sCustomTime[]), info);
		}
		g_iCustomStep[client] = step + 1;
		ShowCustomStep(client);
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

// !todr (owner 2026-10-04): the randomizer test. Same map, a fresh weighted roll exactly as the
// rotation would make it online (presets by weight, "custom" = five layers rolled, the time's
// no_moon rule and the merge rules apply), the campaign arc skipped once so a same-map reload
// cannot hand back the chapter's arc look.
Action Cmd_TodR(int client, int args)
{
	char map[64], arg[16];
	GetCurrentMap(map, sizeof(map));
	int humans = LiveLocked();
	g_bRollFresh = true;
	// every layer rolled on its own (the "custom" preset: time, weather, moon, event, power each by
	// their option weights); "flat" = every option at equal odds, for seeing the whole space quickly
	if (args > 0)
		GetCmdArg(1, arg, sizeof(arg));
	else
		arg[0] = '\0';
	g_bRollFlat = StrEqual(arg, "flat", false);
	// "live": the rotation's own dice (presets by weight, exactly what a map load rolls online)
	bool live = StrEqual(arg, "live", false);
	SetForce(live ? "" : "custom");
	LogMessage("%L: !todr %s on %s (%s)", client, arg[0] ? arg : "custom", map, humans ? "the next map rolls fresh, live lock" : "reloading now");
	if (humans)
	{
		PrintToChatAll("[nightmode] %N: the next map rolls fresh", client);
		ReplyToCommand(client, "[nightmode] next map rolls fresh (%d players on, live lock); sm_nightmode_variant roll now reloads at once", humans);
		return Plugin_Handled;
	}
	if (client)
		PrintToChatAll("[nightmode] %N rolls %s on %s%s", client, live ? "the live dice (presets by weight)" : "every layer", map, g_bRollFlat ? " (flat odds)" : "");
	ForceChangeLevel(map, "night mode: random roll");
	return Plugin_Handled;
}

Action Cmd_TodMap(int client, int args)
{
	if (client <= 0)
	{
		ReplyToCommand(client, "[nightmode] !todmap is a menu: use it in game");
		return Plugin_Handled;
	}
	Menu menu = new Menu(CampaignMenuHandler);
	menu.SetTitle("Campaign");
	for (int i = 0; i < sizeof(CAMPAIGNS); i++)
		menu.AddItem(CAMPAIGNS[i][0], CAMPAIGNS[i][1]);
	menu.Display(client, MENU_TIME_FOREVER);
	return Plugin_Handled;
}

int CampaignMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char prefix[32], map[64], path[PLATFORM_MAX_PATH];
		menu.GetItem(item, prefix, sizeof(prefix));
		BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);
		KeyValues kv = new KeyValues("NightMode");
		Menu maps = new Menu(MapMenuHandler);
		maps.SetTitle("Map");
		if (kv.ImportFromFile(path) && kv.GotoFirstSubKey())
		{
			do
			{
				kv.GetSectionName(map, sizeof(map));
				if (strncmp(map, prefix, strlen(prefix)) == 0)
					maps.AddItem(map, map);
			}
			while (kv.GotoNextKey());
		}
		delete kv;
		maps.ExitBackButton = true;
		maps.Display(client, MENU_TIME_FOREVER);
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

int MapMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char map[64], heading[128];
		menu.GetItem(item, map, sizeof(map));
		FormatEx(heading, sizeof(heading), "Time of day: %s", map);
		Menu v = VariantMenu(map, heading);
		v.ExitBackButton = true;
		v.Display(client, MENU_TIME_FOREVER);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
		Cmd_TodMap(client, 0);
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

Action Cmd_LampDump(int client, int args)
{
	float p[3], range = 400.0;
	char s[16];
	for (int k = 0; k < 3; k++) { GetCmdArg(k + 1, s, sizeof(s)); p[k] = StringToFloat(s); }
	if (args >= 4) { GetCmdArg(4, s, sizeof(s)); range = StringToFloat(s); }
	float lamp[8];
	int n = 0;
	for (int i = 0; i < g_hLamps.Length && i < MAX_LAMPS; i++)
	{
		g_hLamps.GetArray(i, lamp);
		float d = SquareRoot(Pow(lamp[0] - p[0], 2.0) + Pow(lamp[1] - p[1], 2.0) + Pow(lamp[2] - p[2], 2.0));
		if (d > range)
			continue;
		int ent = EntRefToEntIndex(g_iLampRef[i]);
		ReplyToCommand(client, "[lampdump] #%d at %.0f %.0f %.0f kind %.0f yaw %.0f step %.0f fx %.0f dist %.0f off %d on %d ent %d fade %d level %.2f",
			i, lamp[0], lamp[1], lamp[2], lamp[3], lamp[4], lamp[5], lamp[6], d, g_bLampOff[i], g_bLampOn[i], ent, g_bFadeOut[i], g_fLevel[i]);
		n++;
	}
	ReplyToCommand(client, "[lampdump] %d of %d lamps within %.0f", n, g_hLamps.Length, range);
	return Plugin_Handled;
}

Action Cmd_Probe(int client, int args)
{
	float p[3], d[3] = {0.0, 0.0, -1.0};
	char s[16];
	for (int k = 0; k < 3; k++) { GetCmdArg(k + 1, s, sizeof(s)); p[k] = StringToFloat(s); }
	if (args >= 6)
		for (int k = 0; k < 3; k++) { GetCmdArg(k + 4, s, sizeof(s)); d[k] = StringToFloat(s); }
	char line[256];
	line[0] = '\0';
	for (int i = 0; i < 40; i++)
	{
		float q[3];
		for (int k = 0; k < 3; k++) q[k] = p[k] + d[k] * 4.0 * i;
		Format(line, sizeof(line), "%s%s", line, (TR_GetPointContents(q) & CONTENTS_SOLID) ? "#" : ".");
	}
	ReplyToCommand(client, "[probe] %s", line);
	return Plugin_Handled;
}

// !light who: which lit lamps light the spot under the crosshair, measured the
// way the client does it (dynamic lights have no shadows, so the answer is often
// a lamp in the next room). Pool = world light, model = the light on players
// and guns. Also logged to nightmode_marks.log as WHO lines.
void LampsWho(int client)
{
	if (client <= 0 || !IsClientInGame(client))
		return;
	float eye[3], ang[3], hit[3], me[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetClientAbsOrigin(client, me);
	me[2] += 36.0;
	Handle tr = TR_TraceRayFilterEx(eye, ang, MASK_SHOT, RayType_Infinite, NotPlayers, client);
	TR_GetEndPosition(hit, tr);
	float normal[3];
	TR_GetPlaneNormal(tr, normal);
	delete tr;
	// a point just off the surface, so traces to it do not start inside the wall
	float probe[3];
	probe = hit;
	for (int k = 0; k < 3; k++)
		probe[k] += normal[k] * 2.0;

	char map[64], path[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	BuildPath(Path_SM, path, sizeof(path), "logs/nightmode_marks.log");
	LogToFileEx(path, "WHO %s variant=%s hit=%.0f,%.0f,%.0f eye=%.0f,%.0f,%.0f", map, g_sVariant, hit[0], hit[1], hit[2], eye[0], eye[1], eye[2]);

	int idx[MAX_LAMPS], n = 0;
	float power[MAX_LAMPS];
	bool model[MAX_LAMPS];
	float lamp[8], pos[3], la[3], end[3];
	int count = g_hLamps.Length > MAX_LAMPS ? MAX_LAMPS : g_hLamps.Length;
	for (int i = 0; i < count; i++)
	{
		int ent = g_bLampOn[i] ? EntRefToEntIndex(g_iLampRef[i]) : -1;
		if (ent <= 0)
			continue;
		char cls[24];
		if (!GetEntityClassname(ent, cls, sizeof(cls)) || !StrEqual(cls, "light_dynamic"))
			continue;
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		GetEntPropVector(ent, Prop_Send, "m_angRotation", la);
		float reach = GetEntPropFloat(ent, Prop_Send, "m_Radius");
		float spot = GetEntPropFloat(ent, Prop_Send, "m_SpotRadius");
		int ex = GetEntProp(ent, Prop_Send, "m_Exponent");
		int flags = GetEntProp(ent, Prop_Send, "m_Flags");
		float p = 0.0;
		// the pool (world light)
		float frac = PoolFraction(pos, la, reach, end);
		float dp = GetVectorDistance(end, hit);
		if (frac < 1.0 && spot > 0.0 && dp < spot)
		{
			float s = 1.0 - (dp / spot) * (dp / spot);
			p = Pow(2.0, float(ex)) * (1.0 - frac) * (1.0 - frac) * s;
		}
		// the main light on a player standing where the caller is
		bool m = !(flags & 2) && GetVectorDistance(pos, me) < reach;
		if (p <= 0.0 && !m)
			continue;
		idx[n] = i;
		power[n] = p;
		model[n] = m;
		n++;
	}
	// strongest pool first
	for (int x = 1; x < n; x++)
	{
		int vi = idx[x]; float vp = power[x]; bool vm = model[x];
		int y = x - 1;
		while (y >= 0 && power[y] < vp)
		{
			idx[y + 1] = idx[y]; power[y + 1] = power[y]; model[y + 1] = model[y];
			y--;
		}
		idx[y + 1] = vi; power[y + 1] = vp; model[y + 1] = vm;
	}
	float total = 0.0;
	for (int x = 0; x < n; x++)
		total += power[x];
	int shown = 0;
	for (int x = 0; x < n; x++)
	{
		int i = idx[x];
		int ent = EntRefToEntIndex(g_iLampRef[i]);
		g_hLamps.GetArray(i, lamp);
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		GetEntPropVector(ent, Prop_Send, "m_angRotation", la);
		float frac = PoolFraction(pos, la, GetEntPropFloat(ent, Prop_Send, "m_Radius"), end);
		// a wall between the pool and the spot = it lights through the wall
		Handle wt = TR_TraceRayFilterEx(end, probe, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
		bool wall = TR_DidHit(wt) && TR_GetFraction(wt) < 0.97 && power[x] > 0.0;
		delete wt;
		int share = total > 0.0 ? RoundToNearest(100.0 * power[x] / total) : 0;
		char kinds[] = "pwfltxycg?";
		int kind = RoundToNearest(lamp[3]) % 10;
		LogToFileEx(path, "WHO   lamp=%d at=%.0f,%.0f,%.0f kind=%c yaw=%.0f pool=%d%% frac=%.2f exp=%d spot=%.0f pooldist=%.0f wall=%d model=%d depth=%.0f end=%.0f,%.0f,%.0f",
			i, lamp[0], lamp[1], lamp[2], kinds[kind], lamp[4], share, frac, GetEntProp(ent, Prop_Send, "m_Exponent"), GetEntPropFloat(ent, Prop_Send, "m_SpotRadius"), GetVectorDistance(end, hit), wall, model[x], SurfaceDepth(pos, la, GetEntPropFloat(ent, Prop_Send, "m_Radius"), 2000.0), end[0], end[1], end[2]);
		if (shown < 6)
		{
			PrintToChat(client, "[who] #%d %c %.0f away: pool %d%%%s%s", i, kinds[kind], GetVectorDistance(eye, pos), share,
				wall ? " THROUGH A WALL" : "", model[x] ? ", lights you" : "");
			shown++;
		}
		// mark the top three lamps with a short coloured glow: red, amber, blue
		if (x < 3 && power[x] > 0.0)
		{
			int g = CreateEntityByName("env_sprite");
			if (g != -1)
			{
				DispatchKeyValue(g, "targetname", "nightmode_mark");
				DispatchKeyValue(g, "model", LAMP_GLOW);
				DispatchKeyValue(g, "rendermode", "9");
				DispatchKeyValue(g, "renderamt", "255");
				DispatchKeyValue(g, "rendercolor", x == 0 ? "255 40 40" : x == 1 ? "255 190 40" : "60 140 255");
				DispatchKeyValue(g, "scale", "0.6");
				DispatchKeyValue(g, "spawnflags", "1");
				TeleportEntity(g, pos, NULL_VECTOR, NULL_VECTOR);
				DispatchSpawn(g);
				AcceptEntityInput(g, "ShowSprite");
				CreateTimer(8.0, Timer_FlashOff, EntIndexToEntRef(g), TIMER_FLAG_NO_MAPCHANGE);
			}
		}
	}
	if (!n)
		PrintToChat(client, "[who] no lit lamp reaches that spot (it is the map's own light)");
	else
		PrintToChat(client, "[who] %d lamps; glows: red = most, amber, blue. !ul #<n> switches one off", n);
}

Action Cmd_Light(int client, int args)
{
	char a[16], b[16];
	GetCmdArg(1, a, sizeof(a));
	GetCmdArg(2, b, sizeof(b));
	if (StrEqual(a, "off"))
		g_cvLamps.SetBool(false);
	else if (StrEqual(a, "on") || !a[0])
		g_cvLamps.SetBool(true);
	else if (StrEqual(a, "reach") && b[0])
		g_cvLampReach.SetFloat(StringToFloat(b));
	else if (StrEqual(a, "cone") && b[0])
		g_cvLotCone.SetFloat(StringToFloat(b));
	else if (StrEqual(a, "pitch") && b[0])
		g_cvLotPitch.SetFloat(StringToFloat(b));
	else if (StrEqual(a, "streetpitch") && b[0])
		g_cvLampPitch.SetFloat(StringToFloat(b));
	else if (StrEqual(a, "hud"))
	{
		if (client > 0)
			g_bLightHud[client] = !g_bLightHud[client];
		ReplyToCommand(client, "[light] counter %s", client > 0 && g_bLightHud[client] ? "on" : "off");
		return Plugin_Handled;
	}
	else if (StrEqual(a, "near"))
	{
		float at[3];
		char s[16];
		for (int k = 0; k < 3; k++) { GetCmdArg(k + 2, s, sizeof(s)); at[k] = StringToFloat(s); }
		GetCmdArg(5, s, sizeof(s));
		LampsNear(client, at, s[0] ? StringToFloat(s) : 600.0);
		return Plugin_Handled;
	}
	else if (StrEqual(a, "who"))
	{
		LampsWho(client);
		return Plugin_Handled;
	}
	else if (StrEqual(a, "sconce") && b[0])
	{
		g_cvSconceFloor.SetInt(StringToInt(b));
		ReplyToCommand(client, "[light] floor-pool sconces at %d steps", g_cvSconceFloor.IntValue);
		return Plugin_Handled;
	}
	else if (StrEqual(a, "thin") && b[0])
	{
		g_cvPoolThin.SetBool(StringToInt(b) != 0);
		ReplyToCommand(client, "[light] pools kept inside thin surfaces: %s", g_cvPoolThin.BoolValue ? "on" : "off");
		return Plugin_Handled;
	}
	else if (StrEqual(a, "close") && b[0])
	{
		g_cvPoolClose.SetFloat(StringToFloat(b));   // the change hook rebuilds the lamps
		ReplyToCommand(client, "[light] pool close cap %.2f (0 = off)", g_cvPoolClose.FloatValue);
		return Plugin_Handled;
	}
	else if (StrEqual(a, "wallcone") && b[0])
		g_cvWallCone.SetFloat(StringToFloat(b));
	else if (StrEqual(a, "max") && b[0])
		g_cvLampMax.SetInt(StringToInt(b));
	else if (StringToInt(a) > 0 || StrEqual(a, "0"))
		g_cvLampBright.SetInt(StringToInt(a));
	else
	{
		ReplyToCommand(client, "[light] !light on | off | who | sconce <steps> | close <0-1> | thin 0|1 | <brightness> | reach <units> | cone <deg> | pitch <deg> (parking-lot) | streetpitch <deg> | max <count>");
		return Plugin_Handled;
	}
	// respawn so a new brightness, reach or cap applies at once
	RemoveLamps();
	EnsureLamps();
	ReplyToCommand(client, "[light] lamps %s, brightness %d, reach %.0f, lot cone %.0f, lot pitch %.0f, street pitch %.0f, max %d (%d fixtures here%s)",
		g_cvLamps.BoolValue ? "on" : "off", g_cvLampBright.IntValue, g_cvLampReach.FloatValue, g_cvLotCone.FloatValue, g_cvLotPitch.FloatValue, g_cvLampPitch.FloatValue, g_cvLampMax.IntValue,
		g_hLamps.Length, g_bLamps ? "" : ", this variant has none lit");
	return Plugin_Handled;
}

// !mark <note>: logs the player's spot, the point their crosshair hits and
// what it hit, so a tuning session can point at things ("this lamp", "too
// dark here"). Log: addons/sourcemod/logs/nightmode_marks.log
int g_iMarks;

bool NotPlayers(int entity, int mask, int self)
{
	if (entity == self || (entity > 0 && entity <= MaxClients))
		return false;
	// look through invisible walls (env_player_blocker, func_*clip)
	if (entity > MaxClients && IsValidEntity(entity))
	{
		char cls[64];
		GetEntityClassname(entity, cls, sizeof(cls));
		if (StrContains(cls, "blocker") != -1 || StrContains(cls, "clip") != -1)
			return false;
	}
	return true;
}

Action Cmd_Mark(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;
	char note[192], map[64], cls[64], model[PLATFORM_MAX_PATH], tex[64], path[PLATFORM_MAX_PATH];
	GetCmdArgString(note, sizeof(note));
	GetCurrentMap(map, sizeof(map));
	float eye[3], ang[3], hit[3], feet[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetClientAbsOrigin(client, feet);
	Handle tr = TR_TraceRayFilterEx(eye, ang, MASK_SHOT, RayType_Infinite, NotPlayers, client);
	TR_GetEndPosition(hit, tr);
	float normal[3];
	TR_GetPlaneNormal(tr, normal);
	int ent = TR_GetEntityIndex(tr);
	TR_GetSurfaceName(tr, tex, sizeof(tex));
	delete tr;
	cls = "world";
	model[0] = '\0';
	if (ent > 0 && IsValidEntity(ent))
	{
		GetEntityClassname(ent, cls, sizeof(cls));
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
	}
	g_iMarks++;
	BuildPath(Path_SM, path, sizeof(path), "logs/nightmode_marks.log");
	LogToFileEx(path, "#%d %s variant=%s feet=%.0f,%.0f,%.0f eye=%.0f,%.0f,%.0f ang=%.0f,%.0f hit=%.0f,%.0f,%.0f normal=%.2f,%.2f,%.2f dist=%.0f ent=%s %s surface=%s sky=%d note=%s",
		g_iMarks, map, g_sVariant, feet[0], feet[1], feet[2], eye[0], eye[1], eye[2], ang[0], ang[1], hit[0], hit[1], hit[2], normal[0], normal[1], normal[2],
		GetVectorDistance(eye, hit), cls, model, tex, SkyRays(client), note);

	// a brief glow on the spot so the player sees the mark landed
	int glow = CreateEntityByName("env_sprite");
	if (glow != -1)
	{
		DispatchKeyValue(glow, "targetname", "nightmode_mark");
		DispatchKeyValue(glow, "model", LAMP_GLOW);
		DispatchKeyValue(glow, "rendermode", "9");
		DispatchKeyValue(glow, "renderamt", "255");
		DispatchKeyValue(glow, "rendercolor", "80 255 120");
		DispatchKeyValue(glow, "scale", "0.4");
		DispatchKeyValue(glow, "spawnflags", "1");
		TeleportEntity(glow, hit, NULL_VECTOR, NULL_VECTOR);
		DispatchSpawn(glow);
		AcceptEntityInput(glow, "ShowSprite");
		CreateTimer(8.0, Timer_FlashOff, EntIndexToEntRef(glow), TIMER_FLAG_NO_MAPCHANGE);
	}
	ReplyToCommand(client, "[mark] #%d saved (%s%s%s)", g_iMarks, cls, model[0] ? " " : "", model);
	return Plugin_Handled;
}

// !light near: every lamp light within 600 units of the caller, with what the
// client is told (radius, exponent, cone, aim), to debug a lamp that shows nothing.
void LampsNear(int client, const float at[3] = NULL_VECTOR, float range = 600.0)
{
	float me[3], pos[3], ang[3];
	if (client > 0 && IsClientInGame(client))
		GetClientAbsOrigin(client, me);
	else
		me = at;   // from the server console: sm_light near x y z [range]
	char name[32];
	int ent = -1, n = 0;
	while ((ent = FindEntityByClassname(ent, "light_dynamic")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
		if (strncmp(name, "nightmode_lamp_", 15) != 0)
			continue;
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		float d = GetVectorDistance(me, pos);
		if (d > range)
			continue;
		GetEntPropVector(ent, Prop_Send, "m_angRotation", ang);
		ReplyToCommand(client, "[light] %s %.0f away at %.0f %.0f %.0f: radius %.0f spot %.0f exp %d cone %.0f/%.0f aim %.0f %.0f color %08x",
			name, d, pos[0], pos[1], pos[2], GetEntPropFloat(ent, Prop_Send, "m_Radius"), GetEntPropFloat(ent, Prop_Send, "m_SpotRadius"), GetEntProp(ent, Prop_Send, "m_Exponent"),
			GetEntPropFloat(ent, Prop_Send, "m_InnerAngle"), GetEntPropFloat(ent, Prop_Send, "m_OuterAngle"), ang[0], ang[1],
			GetEntProp(ent, Prop_Send, "m_clrRender"));
		n++;
	}
	ReplyToCommand(client, "[light] %d lamp lights within %.0f units", n, range);
}

// The generator under a light tower: a looping hum at the trailer, found by
// tracing down from the lamp head to the ground.
void SpawnHum(const float lamp[8])
{
	SpawnLoop(lamp, GENERATOR_HUM, "8", "900", -40.0, true);
}

// A looping sound for a fixture: at the ground under it (trace down from
// `drop` below the lamp) or right at the lamp, one per spot.
void SpawnLoop(const float lamp[8], const char[] sound, const char[] volume, const char[] radius, float drop, bool ground)
{
	float top[3], end[3], at[3];
	top[0] = lamp[0];
	top[1] = lamp[1];
	top[2] = lamp[2] + drop;   // below the panels for a tower
	at = top;
	if (ground)
	{
		end = top;
		end[2] -= 600.0;
		Handle tr = TR_TraceRayFilterEx(top, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
		TR_GetEndPosition(at, tr);
		delete tr;
		at[2] += 40.0;
	}
	// one hum per tower (each tower has two heads)
	int other = -1;
	char name[32];
	float pos[3];
	while ((other = FindEntityByClassname(other, "ambient_generic")) != -1)
	{
		GetEntPropString(other, Prop_Data, "m_iName", name, sizeof(name));
		GetEntPropVector(other, Prop_Send, "m_vecOrigin", pos);
		if (strncmp(name, "nightmode_glow_", 15) == 0 && GetVectorDistance(pos, at) < 150.0)
			return;
	}
	int hum = CreateEntityByName("ambient_generic");
	if (hum == -1)
		return;
	DispatchKeyValue(hum, "targetname", g_sGlowName);
	DispatchKeyValue(hum, "message", sound);
	DispatchKeyValue(hum, "health", volume);   // 0-10; the generator is 8 (owner: a bit louder than 6)
	DispatchKeyValue(hum, "radius", radius);   // heard within about this many units
	DispatchKeyValue(hum, "pitch", "100");
	DispatchKeyValue(hum, "spawnflags", "0");
	TeleportEntity(hum, at, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(hum);
	ActivateEntity(hum);
	AcceptEntityInput(hum, "PlaySound");
}

// A fire lamp (owner's idea: a brazier on a pillar): an animated flame sprite,
// a flickering orange light pooling down around it, and a quiet crackle.
// full = flame sprite and crackle too; false = only the flickering light, for
// something already burning (a fire barrel) that should light its surroundings
void SpawnFireLamp(const float lamp[8], bool full = true)
{
	if (EdictsLow())
		return;
	float pos[3], down[3] = { 90.0, 0.0, 0.0 };
	pos[0] = lamp[0];
	pos[1] = lamp[1];
	pos[2] = lamp[2];

	int flame = full ? CreateEntityByName("env_sprite") : -1;
	if (flame != -1)
	{
		float f[3];
		f = pos;
		f[2] -= 6.0;    // low in the lantern glass
		DispatchKeyValue(flame, "targetname", g_sGlowName);
		DispatchKeyValue(flame, "model", FIRE_SPRITE);
		DispatchKeyValue(flame, "rendermode", "5");
		DispatchKeyValue(flame, "renderamt", "255");
		DispatchKeyValue(flame, "rendercolor", "255 255 255");
		DispatchKeyValue(flame, "scale", "0.35");
		DispatchKeyValue(flame, "framerate", "0");
		DispatchKeyValue(flame, "spawnflags", "1");
		TeleportEntity(flame, f, NULL_VECTOR, NULL_VECTOR);
		DispatchSpawn(flame);
		AcceptEntityInput(flame, "ShowSprite");
		// the engine did not step the frames in game, so OnGameFrame does
		if (g_hFlames == null)
			g_hFlames = new ArrayList();
		g_hFlames.Push(EntIndexToEntRef(flame));
	}

	int light = CreateEntityByName("light_dynamic");
	if (light != -1)
	{
		char bright[8], reach[12];
		// a step under the street lamps: a brazier, not a floodlight (owner)
		float at[3];
		at[0] = lamp[0]; at[1] = lamp[1]; at[2] = lamp[2];
		IntToString(g_cvLampBright.IntValue - 1 + RoundToNearest(lamp[5]) + ExposureSteps(at), bright, sizeof(bright));
		FloatToString(g_cvLampReach.FloatValue * 0.8, reach, sizeof(reach));
		DispatchKeyValue(light, "targetname", g_sLampName);
		DispatchKeyValue(light, "_light", "255 130 45 255");
		DispatchKeyValue(light, "brightness", bright);
		DispatchKeyValue(light, "distance", reach);
		DispatchKeyValue(light, "_inner_cone", "60");
		DispatchKeyValue(light, "_cone", "85");
		DispatchKeyValue(light, "spotlight_radius", "380");
		DispatchKeyValue(light, "style", "6");      // flicker
		// same rule as the lamps: a fire at arm's length turned the owner's hands white (Parish midnight)
		int lm = g_cvLightModels.IntValue;
		if (lm == 0 || (lm == 2 && LampOpenness(at) == 0.0))
			DispatchKeyValue(light, "spawnflags", "2");
		TeleportEntity(light, pos, down, NULL_VECTOR);
		DispatchSpawn(light);
		AcceptEntityInput(light, "TurnOn");
	}

	if (full)
	{
		// a soft warm glow on the flame so it reads as a light source
		int glow = CreateEntityByName("env_sprite");
		if (glow != -1)
		{
			float g[3];
			g = pos;
			g[2] -= 4.0;
			DispatchKeyValue(glow, "targetname", g_sGlowName);
			DispatchKeyValue(glow, "model", LAMP_GLOW);
			DispatchKeyValue(glow, "rendermode", "9");
			DispatchKeyValue(glow, "renderamt", "170");
			DispatchKeyValue(glow, "rendercolor", "255 150 60");
			DispatchKeyValue(glow, "scale", "0.1");   // 0.3 read as an oversized flame (owner)
			DispatchKeyValue(glow, "GlowProxySize", "16");
			DispatchKeyValue(glow, "spawnflags", "1");
			TeleportEntity(glow, g, NULL_VECTOR, NULL_VECTOR);
			DispatchSpawn(glow);
			AcceptEntityInput(glow, "ShowSprite");
		}
		SpawnLoop(lamp, FIRE_CRACKLE, "4", "500", 0.0, false);
	}
}


// Every tick (a SourceMod timer only runs about ten times a second, which
// looked choppy): about 20 flame frames a second.
public void OnGameFrame()
{
	if (g_hFlames == null || !g_hFlames.Length)
		return;
	float step = 14.0 * GetTickInterval();
	for (int i = g_hFlames.Length - 1; i >= 0; i--)
	{
		int ent = EntRefToEntIndex(g_hFlames.Get(i));
		if (ent == INVALID_ENT_REFERENCE)
		{
			g_hFlames.Erase(i);
			continue;
		}
		float f = GetEntPropFloat(ent, Prop_Send, "m_flFrame") + step;
		SetEntPropFloat(ent, Prop_Send, "m_flFrame", f >= FLAME_FRAMES ? f - FLAME_FRAMES : f);
	}
}

Action Cmd_Sprites(int client, int args)
{
	float at[3], pos[3];
	at[0] = GetCmdArgFloat(1); at[1] = GetCmdArgFloat(2); at[2] = GetCmdArgFloat(3);
	float radius = args >= 4 ? GetCmdArgFloat(4) : 200.0;
	char name[32], model[PLATFORM_MAX_PATH];
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "env_sprite")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		if (GetVectorDistance(pos, at) > radius)
			continue;
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		ReplyToCommand(client, "sprite #%d %s %s at %.0f %.0f %.0f scale %.3f mode %d frame %.1f", ent, name, model,
			pos[0], pos[1], pos[2], GetEntPropFloat(ent, Prop_Send, "m_flSpriteScale"), GetEntProp(ent, Prop_Send, "m_nRenderMode"),
			GetEntPropFloat(ent, Prop_Send, "m_flFrame"));
	}
	return Plugin_Handled;
}

// The counter: lamps lit (the client draws about 16), how many this player has
// a clear line of sight to, and the nearest lit one.
void LightHud()
{
	int lit = 0;
	for (int i = 0; i < MAX_LAMPS; i++)
		if (g_bLampOn[i])
			lit++;
	float lamp[8], eye[3], at[3];
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!g_bLightHud[c] || !IsClientInGame(c))
			continue;
		GetClientEyePosition(c, eye);
		int seen = 0;
		float nearest = -1.0;
		for (int i = 0; i < g_hLamps.Length && i < MAX_LAMPS; i++)
		{
			if (!g_bLampOn[i])
				continue;
			g_hLamps.GetArray(i, lamp);
			at[0] = lamp[0]; at[1] = lamp[1]; at[2] = lamp[2];
			float d = GetVectorDistance(eye, at);
			if (nearest < 0.0 || d < nearest)
				nearest = d;
			Handle tr = TR_TraceRayFilterEx(eye, at, MASK_SOLID_BRUSHONLY, RayType_EndPoint, WorldOnly);
			if (TR_GetFraction(tr) > 0.97)
				seen++;
			delete tr;
		}
		PrintCenterText(c, "lamps lit %d / %d   in sight %d   nearest %.0f", lit, g_cvLampMax.IntValue, seen, nearest);
	}
}

Action Cmd_Unlight(int client, int args)
{
	char a[16], path[PLATFORM_MAX_PATH], map[64];
	GetCmdArg(1, a, sizeof(a));
	GetCurrentMap(map, sizeof(map));
	BuildPath(Path_SM, path, sizeof(path), "logs/nightmode_marks.log");
	float lamp[8];
	if (StrEqual(a, "undo"))
	{
		if (g_iLastUnlit < 0)
		{
			ReplyToCommand(client, "[light] nothing to undo");
			return Plugin_Handled;
		}
		g_bLampOff[g_iLastUnlit] = false;
		g_hLamps.GetArray(g_iLastUnlit, lamp);
		LogToFileEx(path, "UNDO-UNLIGHT %s lamp=%d at=%.0f,%.0f,%.0f", map, g_iLastUnlit, lamp[0], lamp[1], lamp[2]);
		ReplyToCommand(client, "[light] lamp #%d is back", g_iLastUnlit);
		g_iLastUnlit = -1;
		EnsureLamps();
		return Plugin_Handled;
	}
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;
	float eye[3], ang[3], hit[3], at[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	Handle tr = TR_TraceRayFilterEx(eye, ang, MASK_SHOT, RayType_Infinite, NotPlayers, client);
	TR_GetEndPosition(hit, tr);
	delete tr;
	int best = -1;
	float bestd = 96.0;
	if (a[0] == '#')
	{
		// !ul #<n>: by the number !light who printed
		best = StringToInt(a[1]);
		if (best < 0 || best >= g_hLamps.Length || best >= MAX_LAMPS || g_bLampOff[best])
		{
			ReplyToCommand(client, "[light] no lit lamp #%s", a[1]);
			return Plugin_Handled;
		}
		bestd = 0.0;
	}
	for (int i = 0; i < g_hLamps.Length && i < MAX_LAMPS && best < 0; i++)
	{
		if (g_bLampOff[i])
			continue;
		g_hLamps.GetArray(i, lamp);
		at[0] = lamp[0]; at[1] = lamp[1]; at[2] = lamp[2];
		float d = GetVectorDistance(hit, at);
		if (d < bestd)
		{
			bestd = d;
			best = i;
		}
	}
	if (best < 0)
	{
		// aiming at a glow in the air hits whatever is behind it, so fall back to
		// the lamp closest to the aim line itself (within 40 units of it)
		float fwd[3], to[3], reach = GetVectorDistance(eye, hit) + 64.0;
		GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
		bestd = 40.0;
		for (int i = 0; i < g_hLamps.Length && i < MAX_LAMPS; i++)
		{
			if (g_bLampOff[i])
				continue;
			g_hLamps.GetArray(i, lamp);
			at[0] = lamp[0]; at[1] = lamp[1]; at[2] = lamp[2];
			SubtractVectors(at, eye, to);
			float t = GetVectorDotProduct(to, fwd);
			if (t <= 0.0 || t > reach)
				continue;
			float perp = SquareRoot(GetVectorDotProduct(to, to) - t * t);
			if (perp < bestd)
			{
				bestd = perp;
				best = i;
			}
		}
	}
	if (best < 0)
	{
		ReplyToCommand(client, "[light] no lamp near your crosshair or along your aim");
		return Plugin_Handled;
	}
	g_hLamps.GetArray(best, lamp);
	g_bLampOff[best] = true;
	g_iLastUnlit = best;
	RemoveLamp(best);
	EnsureLamps();
	LogToFileEx(path, "UNLIGHT %s lamp=%d at=%.0f,%.0f,%.0f kind=%.0f hit=%.0f,%.0f,%.0f", map, best, lamp[0], lamp[1], lamp[2], lamp[3], hit[0], hit[1], hit[2]);
	ReplyToCommand(client, "[light] lamp #%d off (%.0f units from your crosshair); !unlight undo brings it back", best, bestd);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Lamp QA tour (owner, 2026-10-02): !next / !prev walk the lamp maps in order
Action Cmd_TourNext(int client, int args)
{
	TourStep(client, 1);
	return Plugin_Handled;
}

Action Cmd_TourPrev(int client, int args)
{
	TourStep(client, -1);
	return Plugin_Handled;
}

void TourStep(int client, int dir)
{
	char list[1024], maps[32][64], cur[64];
	g_cvTourMaps.GetString(list, sizeof(list));
	int n = ExplodeString(list, " ", maps, sizeof(maps), sizeof(maps[]));
	if (n <= 0)
		return;
	GetCurrentMap(cur, sizeof(cur));
	int at = -1;
	for (int i = 0; i < n; i++)
	{
		if (StrEqual(maps[i], cur, false))
			at = i;
	}
	// off the list: !next starts at the first map, !prev at the last
	int to = at < 0 ? (dir > 0 ? 0 : n - 1) : (at + dir + n) % n;
	PrintToChatAll("[light] %s (%d / %d) in 3 seconds", maps[to], to + 1, n);
	DataPack dp = new DataPack();
	dp.WriteString(maps[to]);
	CreateTimer(3.0, Timer_TourChange, dp, TIMER_DATA_HNDL_CLOSE);
	LogMessage("tour: %N -> %s", client, maps[to]);
}

Action Timer_TourChange(Handle timer, DataPack dp)
{
	char map[64];
	dp.Reset();
	dp.ReadString(map, sizeof(map));
	ForceChangeLevel(map, "night mode lamp tour");
	return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// Lamp variety: a stable hash of the lamp's position picks its tint, dimming
// and flicker (see SpawnLamp)
int LampHash(const float lamp[8])
{
	int h = RoundToFloor(lamp[0]) * 73856093 ^ RoundToFloor(lamp[1]) * 19349663 ^ RoundToFloor(lamp[2]) * 83492791;
	h ^= h >>> 13;
	h *= 1274126177;
	h ^= h >>> 16;
	return h & 0x7FFFFFFF;
}

// palettes per fixture family, weights in percent
void LampTint(int hash, int kind, bool ceiling, bool hanging, char[] out, int len)
{
	static const char POST[][] = { "255 160 80", "255 145 65", "250 180 115", "255 200 140" };
	static const int POST_W[] = { 50, 25, 15, 10 };
	static const char LOT[][] = { "235 228 210", "255 215 170", "215 228 250", "240 240 200" };
	static const int LOT_W[] = { 45, 25, 20, 10 };
	static const char WALL[][] = { "255 185 120", "255 165 95", "255 205 160", "235 230 215", "255 205 90" };
	static const int WALL_W[] = { 40, 25, 20, 12, 3 };
	static const char TUBE[][] = { "215 228 240", "235 240 230", "205 235 215", "200 215 255" };
	static const int TUBE_W[] = { 45, 25, 20, 10 };
	static const char FLOOD[][] = { "230 235 250", "250 240 220", "215 225 255" };
	static const int FLOOD_W[] = { 45, 30, 25 };
	int roll = hash % 100, acc = 0;
	if (ceiling)
	{
		for (int i = 0; i < sizeof(TUBE_W); i++) { acc += TUBE_W[i]; if (roll < acc) { strcopy(out, len, TUBE[i]); return; } }
	}
	else if (kind == 0)
	{
		for (int i = 0; i < sizeof(POST_W); i++) { acc += POST_W[i]; if (roll < acc) { strcopy(out, len, POST[i]); return; } }
	}
	else if (kind == 3)
	{
		for (int i = 0; i < sizeof(LOT_W); i++) { acc += LOT_W[i]; if (roll < acc) { strcopy(out, len, LOT[i]); return; } }
	}
	else if (kind == 1 || hanging)
	{
		for (int i = 0; i < sizeof(WALL_W); i++) { acc += WALL_W[i]; if (roll < acc) { strcopy(out, len, WALL[i]); return; } }
	}
	else
	{
		for (int i = 0; i < sizeof(FLOOD_W); i++) { acc += FLOOD_W[i]; if (roll < acc) { strcopy(out, len, FLOOD[i]); return; } }
	}
	strcopy(out, len, "255 200 150");
}

// the bulb sprite: the light's tint, halfway to white
char[] GlowOf(const char[] tint)
{
	char parts[3][8], out[16];
	ExplodeString(tint, " ", parts, 3, 8);
	FormatEx(out, sizeof(out), "%d %d %d", (StringToInt(parts[0]) + 255) / 2, (StringToInt(parts[1]) + 255) / 2, (StringToInt(parts[2]) + 255) / 2);
	return out;
}

// old or dirty bulbs: 8% two steps dim, 25% one step
int DimSteps(int hash)
{
	int dim = (hash / 100) % 100;
	return dim < 8 ? 2 : dim < 33 ? 1 : 0;
}

// kind g: one more bulb on a multi-bulb fixture (a vanity bar's four bulbs):
// a small warm glow and no light, so it costs none of the 16 dynamic lights
void SpawnBulbGlow(const float lamp[8])
{
	if (EdictsLow())
		return;
	int glow = CreateEntityByName("env_sprite");
	if (glow == -1)
		return;
	float pos[3];
	pos[0] = lamp[0];
	pos[1] = lamp[1];
	pos[2] = lamp[2];
	DispatchKeyValue(glow, "targetname", g_sGlowName);
	DispatchKeyValue(glow, "model", LAMP_GLOW);
	DispatchKeyValue(glow, "rendermode", "9");
	DispatchKeyValue(glow, "renderamt", "200");
	DispatchKeyValue(glow, "rendercolor", "255 225 185");
	char sc[12];
	FloatToString(0.12 * (lamp[7] > 0.0 ? lamp[7] : 1.0), sc, sizeof(sc));
	DispatchKeyValue(glow, "scale", sc);
	DispatchKeyValue(glow, "GlowProxySize", "4");
	if (lamp[6] > 0.0)
		DispatchKeyValue(glow, "renderfx", "12");
	DispatchKeyValue(glow, "spawnflags", "1");
	TeleportEntity(glow, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(glow);
	AcceptEntityInput(glow, "ShowSprite");
}

// Sight fog. CBaseCombatCharacter::IsAbleToSee calls IsHiddenByFog, which is
// GetFogObscuredRatio(range) >= 1: the viewer's fog controller, 1.0 at or past its end
// whatever the max density. The tank's rage only drains while it has seen no survivor
// (CheckEnemySightings feeds the combat timer UpdateZombieFrustration reads), so
// Midnight's near-black fog_end 1200 drained rage ~30 m out on maps that look clear
// (No Mercy 3, 2026-10-15). The detour answers with the controller's captured Valve
// values instead, unless the look is a storm or fog, whose fog is meant to blind.
// riverside2 (2026-10-16, server.so audit, l4d-source docs/annotated/fog/): the game judges every
// viewer by the CFogSystem master controller (first env_fog_controller, replaced by any later one
// with spawnflag 1), never by the player's own m_PlayerFog.m_hCtrl, which fog_volume brushes move
// and which only drives what the client draws. riverside1 used the player's controller, so a tank
// inside a fog_volume (Mercy 5 / Dead Air 2 interiors, the Blood Harvest 5 cornfield) lost sight
// sooner than stock, and on airport02/04, farm01/02 and hospital01 the first controller is not the
// master, so commons and the witch read the wrong one too.
void SetupSightFog()
{
	GameData conf = new GameData(GAMEDATA_FILE);
	if (conf == null)
	{
		LogError("gamedata/%s.txt missing: sight uses the look's fog", GAMEDATA_FILE);
		return;
	}
	DynamicDetour detour = DynamicDetour.FromConf(conf, "CBaseCombatCharacter::GetFogObscuredRatio");
	delete conf;
	if (detour == null || !detour.Enable(Hook_Pre, Detour_FogRatio))
		LogError("GetFogObscuredRatio detour failed: sight uses the look's fog");
}

void CaptureFog(int ent)
{
	int ref = EntIndexToEntRef(ent);
	if (g_iFogOrigRef[ent] == ref)
		return;
	g_iFogOrigRef[ent] = ref;
	g_bFogOrigOn[ent] = GetEntProp(ent, Prop_Send, "m_fog.enable") != 0;
	g_fFogOrigStart[ent] = GetEntPropFloat(ent, Prop_Send, "m_fog.start");
	g_fFogOrigEnd[ent] = GetEntPropFloat(ent, Prop_Send, "m_fog.end");
	g_fFogOrigDensity[ent] = GetEntPropFloat(ent, Prop_Send, "m_fog.maxdensity");
	// ApplyFog walks the controllers in entity order, as CFogSystem does
	if (EntRefToEntIndex(g_iFogMaster) == INVALID_ENT_REFERENCE || (GetEntProp(ent, Prop_Data, "m_spawnflags") & 1))
		g_iFogMaster = ref;
}

// storm and fog looks keep their fog for sight (layered maps: the weather layer)
bool LookBlindsSight()
{
	if (g_bLayered)
		return StrEqual(g_sLayer[1], "storm", false) || StrEqual(g_sLayer[1], "fog", false);
	return StrContains(g_sVariant, "storm", false) != -1 || StrContains(g_sVariant, "fog", false) != -1
		|| StrContains(g_sVariant, "mist", false) != -1;
}

public MRESReturn Detour_FogRatio(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (!g_cvSightFog.BoolValue || LookBlindsSight())
		return MRES_Ignored;
	int ctrl = EntRefToEntIndex(g_iFogMaster);
	if (ctrl <= MaxClients || ctrl >= sizeof(g_iFogOrigRef) || g_iFogOrigRef[ctrl] != EntIndexToEntRef(ctrl))
		return MRES_Ignored;   // never captured (no look fog on it, or a reload mid-map): leave it alone

	float range = hParams.Get(1), ratio;
	float start = g_fFogOrigStart[ctrl], end = g_fFogOrigEnd[ctrl];
	if (!g_bFogOrigOn[ctrl] || range <= start)
		ratio = 0.0;
	else if (range >= end)
		ratio = 1.0;
	else
	{
		ratio = (range - start) / (end - start);
		if (ratio > g_fFogOrigDensity[ctrl])
			ratio = g_fFogOrigDensity[ctrl];
	}
	hReturn.Value = ratio;
	return MRES_Supercede;
}
