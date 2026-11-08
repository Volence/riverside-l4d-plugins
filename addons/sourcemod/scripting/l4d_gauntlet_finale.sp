/*
 * l4d_gauntlet_finale: L4D2 gauntlet finales (run to the rescue through an endless horde) on L4D1.
 *
 * A converted gauntlet map keeps its trigger_finale at the start (Haunted Forest 4: the generator by the start
 * saferoom), and L4D1 has neither the gauntlet finale type nor its inputs (GauntletStopPanic, ForceTankSpawn).
 * As a plain L4D1 finale it went wrong three ways (match 075b0c79, 2026-11-03):
 *   - TerrorNavMesh::FindGoalArea takes the nav area at the trigger_finale as the flow goal, so flow peaked at
 *     the generator and the whole run to the boat counted as negative: full distance for pressing the button.
 *   - the holdout stages ran timed horde waves and two stage tanks under the run.
 *   - the map's own tank at the end of the tunnel never came (ForceTankSpawn does not exist).
 *
 * On a map with "gauntlet_finale" "1" in mapinfo:
 *   - "gauntlet_goal" "x y z" is the flow goal: FindGoalArea returns the nav area nearest it. Nav blockers are
 *     ignored while flow is computed: the run starts behind a door the finale opens (hf04: door_finale, a
 *     func_door, blocks its areas until the generator), which left the goal unreachable ("Cannot reach start
 *     area from end area. Flow is not valid.").
 *   - when the finale starts the director goes straight to its escape stage (stage set to FINALE_FINAL_BOSS
 *     with no tank up, so the director moves on to the escape with its own entry actions). The escape horde is
 *     the gauntlet's endless horde; no timed waves, no stage tanks.
 *   - every tank the director spawns is refused. The map's tank comes from "gauntlet_tank" (server command,
 *     fired by the map's stripper cfg at its tank trigger) at "gauntlet_tank_pos" "x y z", once per round,
 *     and is offered to the infected like a director tank (Director::TryOfferingTankBot).
 *   - while that tank is alive the horde stops; when it dies the horde comes back. "gauntlet_horde 0" (server
 *     command, from the stripper) stops the horde for the rest of the round. The escape stage's hordes come
 *     through ZombieManager::SpawnMob, refused in L4D_OnSpawnMob (director_no_mobs does not hold them).
 *   - while the horde is held the escape stage's panic events are refused too (Director::StartPanicEvent). The
 *     escape stage starts a one-wave panic whenever none runs, and each one plays the horde scream to everyone
 *     before its mob is refused: Carried Off 4 screamed every ~12 s under its tank (2026-11-06). gauntlet_tank
 *     also ends the running panic (Director::StopPanicEvent), as GauntletStopPanic does in L4D2.
 *   - "gauntlet_tank_wait" "1" is L4D2's GauntletStopPanic order (CDirectorScriptedEventManager stages
 *     GAUNTLET_BOSS_INCOMING and GAUNTLET_BOSS in the L4D2 server): the trigger stops the horde, the tank comes
 *     once no commons are left alive (or the survivors push KITE_DISTANCE of flow on, or TANK_WAIT_MAX passes: a
 *     common stuck out of reach would hold it forever; L4D2 has no cap, owner 2026-11-06), and the horde comes back
 *     when it dies or the survivors run KITE_DISTANCE past where it came. Without it the tank comes at once
 *     (Haunted Forest 4: ForceTankSpawn at its trigger).
 *   - survivors score their real distance. CTerrorGameRules::RecomputeTeamScores gives full distance to any
 *     started finale, which here is the whole run: a wipe at 20% scored full distance (match ee9dcee3,
 *     2026-11-05, cwm4). The director's finale flag is hidden from that one call until the finale is won, so
 *     the run is scored like a normal map and an escape still pays full distance.
 *
 *   - the rescue music (Music::OnFinaleFinalBattle, "Skin On Our Teeth") no longer plays when the escape stage
 *     starts at the button; the horde screams once when it starts and once when it comes back after the tank,
 *     not at every one-wave panic (about every 20 s), as L4D2's PanicForever gauntlet does.
 *   - "gauntlet_mob_window" "<behind> <ahead>": escape mobs only spawn on ground between <behind> flow behind the
 *     last human survivor and <ahead> past the first (L4D2: PreferredMobDirection SPAWN_IN_FRONT_OF_SURVIVORS).
 *     See StartWindow: stock picks mob areas by straight-line distance alone in a versus finale.
 *   - "gauntlet_discard_range" "<units>": z_discard_range for the escape, so commons stuck or run past in a tower
 *     are culled and respawn ahead (see SetDiscardRange).
 *
 * Needs, in the same mapinfo block: "short_finale" "0" and "no_final_first_tank" "0" (l4d_NoRescueFirstTank
 * would move the finale stage itself or kill the first tank after the finale starts). l4d_NoEscapeTank is
 * switched off while our tank lives (it refuses every tank offer and kicks every bot tank once the escape has
 * started).
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <left4dhooks>

#define PLUGIN_VERSION			"1.6"
#define TEAM_SURVIVOR			2
#define TEAM_INFECTED			3
#define ZC_TANK					5
// Director::m_finaleStage (server.so, Linux, read from Director::UpdateFinale), as in l4d_NoRescueFirstTank
#define DIRECTOR_FINALE_STAGE	0x16C
#define FINALE_STAGE_ATTACK_1	0
#define FINALE_STAGE_FINAL_BOSS	3
// Director::m_bFinale (OnFinaleStarted sets it) and the finale state, 3 = won (Director::IsFinaleWon)
#define DIRECTOR_FINALE			0x166
#define DIRECTOR_FINALE_STATE	0x198
#define FINALE_STATE_WON		3
#define GOAL_SEARCH_RANGE		1000.0
// director_gauntlet_tank_kite_distance (L4D2 default): flow the survivors cover before the horde comes back anyway
#define KITE_DISTANCE			3000.0
// longest the gauntlet_tank_wait tank waits for the commons (seconds)
#define TANK_WAIT_MAX			30.0
#define SPAWN_NO_MOBS			0x2000
// horde screams: the engine emits MegaMobIncoming from every player in one frame; one scream is that burst
#define SCREAM_SAMPLE			"mega_mob_incoming"
#define SCREAM_BURST			0.5
#define SCREAM_WAIT				3.0		// horde back and no scream of the engine's own by then: we play one
// mob window: fewest spawn-band areas it may hold, and how far back it widens per step until it holds them
#define WINDOW_MIN_AREAS		20
#define WINDOW_WIDEN			500.0

ConVar g_cvNoEscapeTank;
KeyValues g_hMIData;
Handle g_hStopPanicEvent;

DynamicDetour g_hIsBlocked;		// on only while ComputeFlowDistances runs on a gauntlet map
bool g_bIsBlockedOn;
bool g_bMap;					// this map has "gauntlet_finale" "1"
bool g_bHaveTankPos;
bool g_bTankWait;				// "gauntlet_tank_wait" "1": the tank waits for the commons to die
float g_vTankPos[3], g_fTankYaw;

bool g_bSpawning;				// inside our own SpawnTank: let it through
bool g_bTankSpawned;			// our tank came this round
bool g_bTankUp;					// ... and is still alive: horde held off
bool g_bHordeStopped;			// gauntlet_horde 0: no horde for the rest of the round
bool g_bTankPending;			// gauntlet_tank with gauntlet_tank_wait: horde held, tank not come yet
bool g_bKited;					// the survivors ran KITE_DISTANCE past the tank: horde back while it lives
float g_fHoldFlow;
float g_fWaitStart;				// game time gauntlet_tank started waiting				// furthest survivor flow when the horde stopped / when the tank came
int g_iRound;					// stale timers from an earlier round stop on their own
int g_iNoEscapeTankWas = -1;	// no_escape_tank before we switched it off for our offer
int g_iHiddenFinale = -1;		// m_bFinale while RecomputeTeamScores runs with it cleared

// "gauntlet_mob_window" "<behind> <ahead>": escape-horde mobs only on ground in that flow window (see header)
bool g_bWindow;
float g_fWindowBack, g_fWindowAhead;
bool g_bWindowOn;				// running this round (from finale start)
ArrayList g_aAreas;				// every nav area, from finale start
int g_iWindowOwned[65536 / 32];	// bit per g_aAreas index: we set its NO_MOBS
float g_fWindowMaxFlow;			// highest flow of an area mobs may use when the window started

// "gauntlet_discard_range" "<units>": z_discard_range for the escape (see SetDiscardRange)
float g_fDiscard;
ConVar g_cvDiscard;
ConVar g_cvSpawnSafety;
float g_fDiscardWas = -1.0;

float g_fScreamAt = -100.0;		// game time the last scream burst started
bool g_bEscape;					// the finale has started this round
bool g_bScreamed;				// this horde (finale start, or since it came back after the tank) has screamed
bool g_bOwnScream;				// our own EmitGameSound is running

public Plugin myinfo =
{
	name = "l4d_gauntlet_finale",
	author = "Malevolence",
	description = "L4D2 gauntlet finales on L4D1: flow goal at the rescue, escape-stage horde, one scripted tank",
	version = PLUGIN_VERSION,
	url = "https://github.com/Volence/riverside-l4d-plugins"
};

public void OnPluginStart()
{
	GameData gd = new GameData("l4d_gauntlet_finale");
	if (!gd) SetFailState("gamedata l4d_gauntlet_finale.txt");
	DynamicDetour d = DynamicDetour.FromConf(gd, "GF_FindGoalArea");
	if (!d || !d.Enable(Hook_Pre, FindGoalArea_Pre)) SetFailState("FindGoalArea detour");
	d = DynamicDetour.FromConf(gd, "GF_ComputeFlowDistances");
	if (!d || !d.Enable(Hook_Pre, ComputeFlow_Pre) || !d.Enable(Hook_Post, ComputeFlow_Post))
		SetFailState("ComputeFlowDistances detour");
	g_hIsBlocked = DynamicDetour.FromConf(gd, "GF_IsBlocked");
	if (!g_hIsBlocked) SetFailState("IsBlocked detour");
	d = DynamicDetour.FromConf(gd, "GF_RecomputeTeamScores");
	if (!d || !d.Enable(Hook_Pre, RecomputeScores_Pre) || !d.Enable(Hook_Post, RecomputeScores_Post))
		SetFailState("RecomputeTeamScores detour");
	d = DynamicDetour.FromConf(gd, "GF_StartPanicEvent");
	if (!d || !d.Enable(Hook_Pre, StartPanicEvent_Pre))
		SetFailState("StartPanicEvent detour");
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "Director::StopPanicEvent"))
		SetFailState("Director::StopPanicEvent signature");
	g_hStopPanicEvent = EndPrepSDKCall();
	d = DynamicDetour.FromConf(gd, "GF_OnFinaleFinalBattle");
	if (!d || !d.Enable(Hook_Pre, FinalBattle_Pre))
		SetFailState("Music::OnFinaleFinalBattle detour");
	delete gd;

	AddNormalSoundHook(OnNormalSound);
	CreateTimer(1.0, Timer_Window, _, TIMER_REPEAT);

	CreateConVar("l4d_gauntlet_finale_version", PLUGIN_VERSION, "l4d_gauntlet_finale version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegServerCmd("gauntlet_tank", Cmd_Tank, "Spawn this gauntlet map's tank (stripper, at the map's tank trigger)");
	RegServerCmd("gauntlet_horde", Cmd_Horde, "gauntlet_horde 0: stop the horde for the rest of the round (stripper)");

	HookEvent("finale_start", Event_FinaleStart, EventHookMode_PostNoCopy);
	HookEvent("finale_radio_start", Event_FinaleStart, EventHookMode_PostNoCopy);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("tank_spawn", Event_TankSpawn);
	HookEvent("player_death", Event_PlayerDeath);

	LoadMapInfo();
}

public void OnAllPluginsLoaded()
{
	g_cvNoEscapeTank = FindConVar("no_escape_tank");
	g_cvDiscard = FindConVar("z_discard_range");
	g_cvSpawnSafety = FindConVar("z_finale_spawn_safety_range");
}

public void OnMapStart()
{
	delete g_aAreas;  // the nav mesh is new: nothing of ours is in it
	g_bWindowOn = false;
	LoadMapInfo();
	ResetRound();
}

public void OnMapEnd()
{
	RestoreDiscardRange();
	RestoreNoEscapeTank();
}

void LoadMapInfo()
{
	delete g_hMIData;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/mapinfo.txt");
	g_hMIData = new KeyValues("MapInfo");
	if (!g_hMIData.ImportFromFile(path))
	{
		LogError("Couldn't load %s", path);
		delete g_hMIData;
	}

	char map[64];
	GetCurrentMap(map, sizeof(map));
	g_bMap = g_bHaveTankPos = g_bTankWait = g_bWindow = false;
	g_fDiscard = 0.0;
	if (!g_hMIData || !g_hMIData.JumpToKey(map))
		return;
	g_bMap = g_hMIData.GetNum("gauntlet_finale", 0) != 0;
	g_bTankWait = g_hMIData.GetNum("gauntlet_tank_wait", 0) != 0;
	g_bHaveTankPos = ReadVector("gauntlet_tank_pos", g_vTankPos);
	g_fTankYaw = g_hMIData.GetFloat("gauntlet_tank_yaw", 0.0);
	char s[64], parts[2][16];
	g_hMIData.GetString("gauntlet_mob_window", s, sizeof(s));
	g_bWindow = ExplodeString(s, " ", parts, 2, 16) == 2;
	if (g_bWindow)
	{
		g_fWindowBack = StringToFloat(parts[0]);
		g_fWindowAhead = StringToFloat(parts[1]);
	}
	g_fDiscard = g_hMIData.GetFloat("gauntlet_discard_range", 0.0);
	g_hMIData.Rewind();
}

bool ReadVector(const char[] key, float vec[3])
{
	char s[64], parts[3][16];
	g_hMIData.GetString(key, s, sizeof(s));
	if (ExplodeString(s, " ", parts, 3, 16) != 3)
		return false;
	for (int i = 0; i < 3; i++)
		vec[i] = StringToFloat(parts[i]);
	return true;
}

// This map's gauntlet_goal. The nav mesh computes flow while the map loads, before OnMapStart, so the map is
// looked up here rather than read from g_bMap.
bool MapGoal(float goal[3])
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	if (!g_hMIData || !g_hMIData.JumpToKey(map))
		return false;
	bool use = g_hMIData.GetNum("gauntlet_finale", 0) != 0 && ReadVector("gauntlet_goal", goal);
	g_hMIData.Rewind();
	return use;
}

MRESReturn ComputeFlow_Pre(Address pThis)
{
	float goal[3];
	if (MapGoal(goal) && !g_bIsBlockedOn)
		g_bIsBlockedOn = g_hIsBlocked.Enable(Hook_Pre, IsBlocked_Pre);
	return MRES_Ignored;
}

MRESReturn ComputeFlow_Post(Address pThis)
{
	if (g_bIsBlockedOn)
		g_bIsBlockedOn = !g_hIsBlocked.Disable(Hook_Pre, IsBlocked_Pre);
	return MRES_Ignored;
}

MRESReturn IsBlocked_Pre(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	hReturn.Value = false;
	return MRES_Supercede;
}

MRESReturn FindGoalArea_Pre(Address pThis, DHookReturn hReturn)
{
	float goal[3];
	if (!MapGoal(goal))
		return MRES_Ignored;
	char map[64];
	GetCurrentMap(map, sizeof(map));

	Address area = L4D_GetNearestNavArea(goal, GOAL_SEARCH_RANGE, true, false, false);
	if (area == Address_Null)
	{
		LogError("%s: no nav area within %.0f of gauntlet_goal %.0f %.0f %.0f, keeping the stock goal",
			map, GOAL_SEARCH_RANGE, goal[0], goal[1], goal[2]);
		return MRES_Ignored;
	}
	hReturn.Value = area;
	return MRES_Supercede;
}

// RecomputeTeamScores forces distance to 100 once m_bFinale is set; clear it for the call until the finale is won
MRESReturn RecomputeScores_Pre(Address pThis)
{
	g_iHiddenFinale = -1;
	if (!g_bMap)
		return MRES_Ignored;
	Address director = L4D_GetPointer(POINTER_DIRECTOR);
	if (director == Address_Null)
		return MRES_Ignored;
	int finale = LoadFromAddress(director + view_as<Address>(DIRECTOR_FINALE), NumberType_Int8);
	if (finale == 0
		|| LoadFromAddress(director + view_as<Address>(DIRECTOR_FINALE_STATE), NumberType_Int32) == FINALE_STATE_WON)
		return MRES_Ignored;
	StoreToAddress(director + view_as<Address>(DIRECTOR_FINALE), 0, NumberType_Int8, false);
	g_iHiddenFinale = finale;
	return MRES_Ignored;
}

MRESReturn RecomputeScores_Post(Address pThis)
{
	if (g_iHiddenFinale == -1)
		return MRES_Ignored;
	Address director = L4D_GetPointer(POINTER_DIRECTOR);
	StoreToAddress(director + view_as<Address>(DIRECTOR_FINALE), g_iHiddenFinale, NumberType_Int8, false);
	g_iHiddenFinale = -1;
	return MRES_Ignored;
}

void ResetRound()
{
	StopWindow();
	RestoreDiscardRange();
	g_bEscape = g_bScreamed = false;
	g_bSpawning = g_bTankSpawned = g_bTankUp = g_bHordeStopped = g_bTankPending = g_bKited = false;
	g_iRound++;
	RestoreNoEscapeTank();
}

bool HordeHeld()
{
	return g_bMap && (g_bHordeStopped || (!g_bKited && (g_bTankPending || g_bTankUp)));
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bMap)
		return;
	RequestFrame(Frame_SkipToEscape);
	if (!g_bEscape)
	{
		g_bEscape = true;
		g_bScreamed = false;  // a panic before the button (stall horde) does not count
		SetDiscardRange();
	}
	if (g_bWindow && !g_bWindowOn)
		StartWindow();
}

// FINAL_BOSS with no tank up: the director starts the escape on its next update, with its own panic and outputs
void Frame_SkipToEscape(any unused)
{
	Address director = L4D_GetPointer(POINTER_DIRECTOR);
	if (director == Address_Null)
		return;
	Address stage = director + view_as<Address>(DIRECTOR_FINALE_STAGE);
	if (LoadFromAddress(stage, NumberType_Int32) == FINALE_STAGE_ATTACK_1)
		StoreToAddress(stage, FINALE_STAGE_FINAL_BOSS, NumberType_Int32);
}

public Action L4D_OnSpawnTank(const float vecPos[3], const float vecAng[3])
{
	// the escape stage tries a tank every few seconds; on these maps the only tank is the map's own
	return (g_bMap && !g_bSpawning) ? Plugin_Handled : Plugin_Continue;
}

public Action L4D_OnSpawnMob(int &amount)
{
	return HordeHeld() ? Plugin_Handled : Plugin_Continue;
}

// The escape stage starts a panic whenever none runs, every tick; refused, none runs and it asks again
MRESReturn StartPanicEvent_Pre(Address pThis, DHookParam hParams)
{
	return HordeHeld() ? MRES_Supercede : MRES_Ignored;
}

void StopPanicEvent()
{
	Address director = L4D_GetPointer(POINTER_DIRECTOR);
	if (director != Address_Null)
		SDKCall(g_hStopPanicEvent, director);
}

Action Cmd_Tank(int args)
{
	if (!g_bMap || !g_bHaveTankPos || g_bTankSpawned || g_bTankPending)
		return Plugin_Handled;

	if (g_bTankWait)
	{
		g_bTankPending = true;
		g_fHoldFlow = FurthestSurvivorFlow();
		g_fWaitStart = GetGameTime();
		StopPanicEvent();
		LogMessage("gauntlet_tank: horde held, tank waits (flow %.0f, %d commons)", g_fHoldFlow, CountLiveCommons());
		CreateTimer(0.5, Timer_TankWait, g_iRound, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		PrintToChatAll("\x04[Horde]\x01 The horde stops. The tank comes when the infected are cleared.");
		return Plugin_Handled;
	}
	StopPanicEvent();
	LogMessage("gauntlet_tank: tank now (flow %.0f)", FurthestSurvivorFlow());
	SpawnGauntletTank();
	return Plugin_Handled;
}

Action Timer_TankWait(Handle timer, int round)
{
	if (round != g_iRound || !g_bTankPending)
		return Plugin_Stop;
	int commons = CountLiveCommons();
	float flow = FurthestSurvivorFlow();
	float waited = GetGameTime() - g_fWaitStart;
	if (commons > 0 && flow < g_fHoldFlow + KITE_DISTANCE && waited < TANK_WAIT_MAX)
		return Plugin_Continue;
	LogMessage("gauntlet_tank: tank comes (%d commons, flow %.0f, held at %.0f, waited %.0f s)", commons, flow,
		g_fHoldFlow, waited);
	g_bTankPending = false;
	SpawnGauntletTank();
	return Plugin_Stop;
}

void SpawnGauntletTank()
{
	// l4d_NoEscapeTank refuses every tank offer once the escape has started; let ours through
	if (g_cvNoEscapeTank && g_iNoEscapeTankWas == -1)
	{
		g_iNoEscapeTankWas = g_cvNoEscapeTank.IntValue;
		g_cvNoEscapeTank.IntValue = 0;
	}
	float ang[3];
	ang[1] = g_fTankYaw;
	// tank_spawn fires inside SpawnTank
	g_bSpawning = g_bTankSpawned = true;
	int tank = L4D2_SpawnTank(g_vTankPos, ang);
	g_bSpawning = false;
	if (tank <= 0)
	{
		g_bTankSpawned = false;
		LogError("gauntlet_tank: SpawnTank failed at %.0f %.0f %.0f", g_vTankPos[0], g_vTankPos[1], g_vTankPos[2]);
		RestoreNoEscapeTank();
		return;
	}
	// SpawnTank only makes the bot. The director offers its own tanks to the infected from its spawn path
	// (Director::TryOfferingTankBot, in stasis while the lottery runs), so ours never went to a player: match
	// ee9dcee3 (2026-11-05, cwm4) played against a bot tank stuck at its spawn.
	L4D2Direct_TryOfferingTankBot(tank, true);  // left4dhooks 1.168 returns false even when it ran
	// no_escape_tank stays off while our tank lives: a frustrated or dropped tank goes to a bot, which it would
	// kick. The director's own tanks are refused in L4D_OnSpawnTank anyway.
}

Action Cmd_Horde(int args)
{
	if (!g_bMap || GetCmdArgInt(1) != 0)
		return Plugin_Handled;
	g_bHordeStopped = true;
	LogMessage("gauntlet_horde 0: horde stopped for the round");
	return Plugin_Handled;
}

void RestoreNoEscapeTank()
{
	if (g_cvNoEscapeTank && g_iNoEscapeTankWas != -1)
		g_cvNoEscapeTank.IntValue = g_iNoEscapeTankWas;
	g_iNoEscapeTankWas = -1;
}

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bMap || !g_bTankSpawned || g_bTankUp)
		return;
	g_bTankUp = true;
	g_fHoldFlow = FurthestSurvivorFlow();
	LogMessage("tank up: horde held (flow %.0f)", g_fHoldFlow);
	CreateTimer(1.0, Timer_Kite, g_iRound, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	PrintToChatAll("\x04[Horde]\x01 Tank! The horde stops until the tank is dead.");
}

// L4D2 GAUNTLET_BOSS: survivors who run far enough past the tank get the horde back
Action Timer_Kite(Handle timer, int round)
{
	if (round != g_iRound || !g_bTankUp || g_bKited)
		return Plugin_Stop;
	if (FurthestSurvivorFlow() < g_fHoldFlow + KITE_DISTANCE)
		return Plugin_Continue;
	g_bKited = true;
	LogMessage("survivors %.0f past the tank: horde back", KITE_DISTANCE);
	HordeBack();
	if (!g_bHordeStopped)
		PrintToChatAll("\x04[Horde]\x01 You ran past the tank. The horde is back.");
	return Plugin_Stop;
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bTankUp)
		return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED
		&& GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK)
		CreateTimer(0.5, Timer_CheckResume, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
	// a tank kicked or dropped without a death event (a bot taking over fires tank_spawn again)
	if (g_bTankUp)
		CreateTimer(0.5, Timer_CheckResume, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_CheckResume(Handle timer)
{
	if (!g_bTankUp || CountLiveTanks() > 0)
		return Plugin_Stop;
	g_bTankUp = false;
	RestoreNoEscapeTank();
	LogMessage("tank dead: horde %s", g_bHordeStopped ? "stays stopped" : "back");
	if (!g_bKited)
		HordeBack();
	if (!g_bHordeStopped && !g_bKited)
		PrintToChatAll("\x04[Horde]\x01 The tank is dead. The horde is back.");
	return Plugin_Stop;
}

int CountLiveTanks()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i)
			&& GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
			n++;
	return n;
}

int CountLiveCommons()
{
	int n = 0, ent = -1;
	while ((ent = FindEntityByClassname(ent, "infected")) != -1)
		if (GetEntProp(ent, Prop_Data, "m_iHealth") > 0)
			n++;
	return n;
}

float FurthestSurvivorFlow()
{
	float best = 0.0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
		{
			float flow = L4D2Direct_GetFlowDistance(i);
			if (flow > best)
				best = flow;
		}
	return best;
}

// --- music ---

// Music::OnFinaleFinalBattle plays Event.FinalBattle ("Skin On Our Teeth", the rescue-is-coming track) to each
// survivor when the escape starts. Here the escape stage is the whole run from the button, so the rescue music
// played at the bottom of the building.
MRESReturn FinalBattle_Pre(Address pThis)
{
	return g_bMap ? MRES_Supercede : MRES_Ignored;
}

// --- horde screams ---

// The escape stage screams at every panic it starts: twice in the first seconds of the run (the finale's own panic
// and the escape stage's), then at every one-wave panic after (about every 20 s). L4D2 runs the gauntlet as one
// endless panic (PanicForever), so it screams when the horde starts and when it comes back after the tank: so do
// we. The burst the engine sends from every player in the same frame counts as one scream.
Action OnNormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity,
	int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (!g_bMap || !g_bEscape || StrContains(sample, SCREAM_SAMPLE, false) == -1)
		return Plugin_Continue;
	float now = GetGameTime();
	if (g_bOwnScream || now - g_fScreamAt <= SCREAM_BURST)
		return Plugin_Continue;
	if (g_bScreamed)
	{
		LogMessage("horde scream dropped (%.1f s after the last)", now - g_fScreamAt);
		return Plugin_Stop;
	}
	g_bScreamed = true;
	g_fScreamAt = now;
	LogMessage("horde scream");
	return Plugin_Continue;
}

// The horde comes back after the tank: let the next engine scream through, or play the engine's own scream (from
// every survivor, as Director::UpdatePanicEvents does) if there was none by SCREAM_WAIT.
void HordeBack()
{
	if (g_bHordeStopped)
		return;
	g_bScreamed = false;
	CreateTimer(SCREAM_WAIT, Timer_HordeBackScream, g_iRound, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_HordeBackScream(Handle timer, int round)
{
	if (round != g_iRound || g_bScreamed || g_bHordeStopped || g_bTankUp && !g_bKited)
		return Plugin_Stop;
	g_bScreamed = true;
	g_fScreamAt = GetGameTime();
	LogMessage("horde back: horde scream");
	g_bOwnScream = true;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			EmitGameSoundToAll("MegaMobIncoming", i);
	g_bOwnScream = false;
	return Plugin_Stop;
}

// --- mob window ---

// "gauntlet_mob_window" "<behind> <ahead>": from finale start, every second, nav areas outside the flow window
// [last survivor - behind, first survivor + ahead] get NO_MOBS (human survivors only when any is alive; areas with
// no flow too). In a versus finale ZombieManager::CollectSpawnAreas picks mob areas by straight-line distance only
// (MobLocationType 7: between z_finale_spawn_safety_range and twice that from the closest survivor, any
// direction), which in a tower means floors above and below that the commons need a long walk to leave: match
// fd4d95a3 map 4, 85% of commons spawned 600-1200 away, 95% on another floor, and only 31% ever came within 300 of
// a survivor. L4D2 runs this finale with PreferredMobDirection SPAWN_IN_FRONT_OF_SURVIVORS (cwm_finale.nut). Near
// the end, where the window would run past the last ground mobs may use, it slides back by the overflow, and it
// widens backwards wherever it holds too few areas in the spawn band.
void StartWindow()
{
	delete g_aAreas;
	g_aAreas = new ArrayList();
	L4D_GetAllNavAreas(g_aAreas);
	for (int i = 0; i < sizeof(g_iWindowOwned); i++)
		g_iWindowOwned[i] = 0;
	g_fWindowMaxFlow = 0.0;
	for (int i = 0; i < g_aAreas.Length; i++)
	{
		Address a = g_aAreas.Get(i);
		float f = L4D2Direct_GetTerrorNavAreaFlow(a);
		if (f > g_fWindowMaxFlow && !(L4D_GetNavArea_SpawnAttributes(a) & SPAWN_NO_MOBS))
			g_fWindowMaxFlow = f;
	}
	g_bWindowOn = true;
	LogMessage("mob window on: %.0f behind, %.0f ahead, last mob ground at flow %.0f (%d areas)", g_fWindowBack,
		g_fWindowAhead, g_fWindowMaxFlow, g_aAreas.Length);
}

void StopWindow()
{
	if (g_aAreas != null)
	{
		for (int i = 0; i < g_aAreas.Length; i++)
		{
			if (!WindowOwned(i))
				continue;
			Address a = g_aAreas.Get(i);
			L4D_SetNavArea_SpawnAttributes(a, L4D_GetNavArea_SpawnAttributes(a) & ~SPAWN_NO_MOBS);
		}
		delete g_aAreas;
	}
	for (int i = 0; i < sizeof(g_iWindowOwned); i++)
		g_iWindowOwned[i] = 0;
	g_bWindowOn = false;
}

bool WindowOwned(int i)
{
	return (g_iWindowOwned[i >> 5] & (1 << (i & 31))) != 0;
}

void SetWindowOwned(int i, bool owned)
{
	if (owned)
		g_iWindowOwned[i >> 5] |= (1 << (i & 31));
	else
		g_iWindowOwned[i >> 5] &= ~(1 << (i & 31));
}

Action Timer_Window(Handle timer)
{
	if (!g_bWindowOn || g_aAreas == null)
		return Plugin_Continue;
	bool humans = false;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i) && !IsFakeClient(i))
			humans = true;
	float first = -1.0, last = 1.0e9;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i) || (humans && IsFakeClient(i)))
			continue;
		float f = L4D2Direct_GetFlowDistance(i);
		if (f <= 0.0)
			continue;
		if (f > first) first = f;
		if (f < last) last = f;
	}
	if (first <= 0.0)
		return Plugin_Continue;
	float lo = last - g_fWindowBack, hi = first + g_fWindowAhead;
	if (hi > g_fWindowMaxFlow)
	{
		lo -= hi - g_fWindowMaxFlow;
		hi = g_fWindowMaxFlow;
	}
	// The engine only takes areas in the spawn band of the closest survivor (bots too). Where the window holds too
	// few of them (cwm4 roof: the last mob ground is right under the survivors, inside the band) no mob finds an area,
	// so widen it backwards until it does. Switching the window off there let the engine pick floors 11000-18000 flow
	// back that the commons never walked out of.
	float band = g_cvSpawnSafety ? g_cvSpawnSafety.FloatValue : 600.0;
	while (lo > 0.0 && CountBandAreas(lo, hi, band) < WINDOW_MIN_AREAS)
		lo -= WINDOW_WIDEN;
	for (int i = 0; i < g_aAreas.Length; i++)
	{
		Address a = g_aAreas.Get(i);
		float flow = L4D2Direct_GetTerrorNavAreaFlow(a);
		bool outside = flow < 0.0 || flow < lo || flow > hi;
		int attr = L4D_GetNavArea_SpawnAttributes(a);
		if (outside && !(attr & SPAWN_NO_MOBS))
		{
			L4D_SetNavArea_SpawnAttributes(a, attr | SPAWN_NO_MOBS);
			SetWindowOwned(i, true);
		}
		else if (!outside && WindowOwned(i))
		{
			L4D_SetNavArea_SpawnAttributes(a, attr & ~SPAWN_NO_MOBS);
			SetWindowOwned(i, false);
		}
	}
	return Plugin_Continue;
}

// Areas mobs may use with the window at [lo, hi]: not NO_MOBS by the map, and between band and twice that from the
// closest living survivor, as ZombieManager::CollectSpawnAreas takes them in a versus finale.
int CountBandAreas(float lo, float hi, float band)
{
	float pos[MAXPLAYERS + 1][3];
	int n;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			GetClientAbsOrigin(i, pos[n++]);
	int count;
	for (int i = 0; i < g_aAreas.Length; i++)
	{
		Address a = g_aAreas.Get(i);
		float flow = L4D2Direct_GetTerrorNavAreaFlow(a);
		if (flow < lo || flow > hi || !WindowOwned(i) && (L4D_GetNavArea_SpawnAttributes(a) & SPAWN_NO_MOBS))
			continue;
		float c[3], closest = 1.0e9;
		L4D_GetNavAreaCenter(a, c);
		for (int k = 0; k < n; k++)
		{
			float d = GetVectorDistance(c, pos[k]);
			if (d < closest) closest = d;
		}
		if (closest >= band && closest <= 2.0 * band)
			count++;
	}
	return count;
}

public void OnPluginEnd()
{
	StopWindow();
	RestoreDiscardRange();
	RestoreNoEscapeTank();
}

// --- discard range ---

// Infected::TryToCull removes a common that no survivor sees once the closest player is farther than
// z_discard_range (2500) and it has been alive long enough. A whole tower fits inside 2500, so commons left stuck
// on another floor or run past held their place in z_common_limit for the rest of the run. With a smaller range for
// the escape they go, and the next mob spawns in their place.
void SetDiscardRange()
{
	if (g_fDiscard <= 0.0 || !g_cvDiscard || g_fDiscardWas >= 0.0)
		return;
	g_fDiscardWas = g_cvDiscard.FloatValue;
	g_cvDiscard.FloatValue = g_fDiscard;
	LogMessage("z_discard_range %.0f for the escape (was %.0f)", g_fDiscard, g_fDiscardWas);
}

void RestoreDiscardRange()
{
	if (g_cvDiscard && g_fDiscardWas >= 0.0)
		g_cvDiscard.FloatValue = g_fDiscardWas;
	g_fDiscardWas = -1.0;
}
