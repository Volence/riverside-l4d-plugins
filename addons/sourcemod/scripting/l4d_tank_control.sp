#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <multicolors>
#include <left4dhooks>
#include <l4d_lib>

#define CVAR_FLAGS			FCVAR_NOTIFY

native Is_Ready_Plugin_On();
// pug-match 0.3.45+ (pug-tankplan.inc): the infected player whose SR rank slot
// tanks this map, or 0 for no plan. Optional, marked in AskPluginLoad2.
native int PUG_PlannedTank();

static	queuedTank, Handle:hTeamTanks, Handle:hTeamFinalTanks;
ConVar g_hCvarInfLimit, g_hCvarSurLimit;
static		bool:IsSecondTank,bool:IsFinal;	
static Handle:hPreviousMapTeamTanks;

// riverside2: where queuedTank came from, so a re-pick can be given back
enum
{
	QT_NONE = 0,
	QT_PLAN,	// pug-match tank order (SR rank slot)
	QT_RANDOM,	// upstream "everyone once" random pick
	QT_ADMIN	// sm_settankplayer
}
static int g_iQueuedSource;
// riverside2 (upstream 2.4's idea): Steam2 id of the half's first random pick, so a fallback pick who drops
// and comes back before the first tank gets it back. Cleared once the first tank is handed out.
static char g_sFirstPickSteamId[32];
// riverside2: hunter first. g_bHalfLive: l4dready's go-live (or leaving the start area without it).
// g_bFirstSpawned: the half's first SI or tank has materialized; nothing is swapped after that.
static bool g_bHalfLive, g_bFirstSpawned;
ConVar g_hCvarHunterFirst, g_hCvarHunterLimit, g_hCvarSmokerLimit, g_hCvarBoomerLimit;

// riverside3: pick the half's first tank during ready-up (owner, 2026-11-21, Discord thread "Getting rid of
// the ability to pass tanks": the hunter swap at go-live turned a boomer into a hunter as survivors left).
// Before riverside3 the half-2 swap always waited for go-live: no ghost entry reached the plan between the
// halves (Dallas 11-21: no PUG_PlannedTank call in any half-2 ready-up, swap logged the same second as go-live).
static Handle g_hPreRoundTimer;
static int g_iPreRoundSig;		// infected humans seen at the last pre-round ask (userid hash)
static char g_sLastSkip[192];	// hunter-first skip reason already logged this half

#define HUNTER_FIRST_DELAY	0.3	// after QuadCaps' 0.1 s ghost class checks (COLD_DOWN, KeepSIStarting)

public Plugin:myinfo = {
	name = "L4D Tank Control",
	author = "Jahze, vintik, raziEiL [disawar1], Harry Potter",
	version = "2.3-riverside3",
	description = "Forces each player to play the tank at least once before Map change. Riverside: PUG matches pick by SR rank slot (pug-match); the planned tank is given back if he returns; the map's first tank starts the half as a hunter, picked and swapped during ready-up."
};

static bool:g_bCvartankcontroldisable,Handle:hCvarFlags;
static String:previousmap[128];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();

	if( test != Engine_Left4Dead )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1.");
		return APLRes_SilentFailure;
	}

	MarkNativeAsOptional("PUG_PlannedTank");
	CreateNative("ChoseTankPrintWhoBecome", Native_ChoseTankPrintWhoBecome);
	CreateNative("WhoIsTank", Native_WhoIsTank);
	return APLRes_Success;
}

public Native_WhoIsTank(Handle:plugin, numParams)
{
	return queuedTank;
}

public Native_ChoseTankPrintWhoBecome(Handle:plugin, numParams)
{
	// riverside2: l4dready calls this from its go-live (RoundIsLive) only
	g_bHalfLive = true;
	if (IsPluginDisabled()) return;
	
	if(queuedTank > 0 && IsClientInGame(queuedTank) && GetClientTeam(queuedTank) == 3)
	{
		decl String:queuedTankName[128];
		GetClientName(queuedTank,queuedTankName,128);
		CPrintToChatAll("%t","player will be the tank", queuedTankName); 
		QueueHunterFirst(queuedTank);
	}
	else
		ChoseTankAndPrintWhoBecome();
}

public OnPluginStart()
{
	LoadTranslations("Roto2-AZ_mod.phrases");
	g_hCvarInfLimit = FindConVar("z_max_player_zombies");
	g_hCvarSurLimit = FindConVar("survivor_limit");
	
	hCvarFlags = CreateConVar("tank_control_disable", "0", "if set, no Forces each player to play the tank at once,1=disabled", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_bCvartankcontroldisable = GetConVarBool(hCvarFlags);
	HookConVarChange(hCvarFlags, OnCvarChange_tank_control_disable);
	g_hCvarHunterFirst = CreateConVar("tank_control_hunter_first", "1", "1 = the map's first tank starts the half as a hunter: before the half's first spawn his ghost class is swapped with a teammate's hunter ghost (class counts unchanged)", CVAR_FLAGS, true, 0.0, true, 1.0);
	g_hCvarHunterLimit = FindConVar("z_hunter_limit");
	g_hCvarSmokerLimit = FindConVar("z_versus_smoker_limit");
	g_hCvarBoomerLimit = FindConVar("z_versus_boomer_limit");

	HookEvent("player_team", TC_ev_OnTeamChange);
	HookEvent("player_left_start_area", TC_ev_LeftStartAreaEvent, EventHookMode_PostNoCopy);
	HookEvent("round_start", TC_ev_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", TC_ev_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", TC_ev_PlayerSpawn);
	
	RegConsoleCmd("sm_tank", Command_FindNexTank);
	RegConsoleCmd("sm_t", Command_FindNexTank);
	RegConsoleCmd("sm_boss", Command_FindNexTank);
	RegAdminCmd("sm_settankplayer", Command_SetTank, ADMFLAG_BAN, "sm_settank <player> - force this player will become the tank");
	RegAdminCmd("sm_clearteam", ClearTeam_Cmd, ADMFLAG_BAN, "clear who_has_been_tank_arraylist for both team, useful when map change.");
	
	hTeamTanks = CreateArray(64);
	hTeamFinalTanks = CreateArray(64);
	
	hPreviousMapTeamTanks = CreateArray(8);
	strcopy(previousmap, sizeof(previousmap), "");
	
	LoadTranslations("common.phrases");
}

public TC_ev_LeftStartAreaEvent(Handle:event, String:name[], bool:dontBroadcast)
{
	if(!Is_Ready_Plugin_On())
	{
		g_bHalfLive = true;
		ChoseTankAndPrintWhoBecome();
	}
}

public Action:Command_SetTank(client, args)
{
	if (args < 1 || args > 1)
	{
		ReplyToCommand(client, "[TS] Usage: sm_settankplayer <player> - %T","force this player will become the tank",client);
		return Plugin_Handled;
	}
	if(IsPluginDisabled())
	{
		ReplyToCommand(client, "[TS] %T","l4d_tank_control1",client);
		return Plugin_Handled;
	}

	char target_name[MAX_TARGET_LENGTH];
	int target_list[MAXPLAYERS], target_count;
	bool tn_is_ml;
	char arg[65];
	GetCmdArg(1, arg, sizeof(arg));
	if ((target_count = ProcessTargetString(
			arg,
			client,
			target_list,
			MAXPLAYERS,
			COMMAND_FILTER_NO_BOTS,
			target_name,
			sizeof(target_name),
			tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}

	int player_id = target_list[0];
	
	decl String:player_idName[128];
	GetClientName(player_id,player_idName,128);
	if(GetClientTeam(player_id) != 3)
	{
		ReplyToCommand(client, "[TS] %T","target is not in infected team",client,player_idName);
		return Plugin_Handled;
	}
	
	queuedTank = player_id;
	g_iQueuedSource = QT_ADMIN;
	decl String:queuedTankName[128];
	GetClientName(queuedTank,queuedTankName,128);
	CPrintToChatAll("%t","l4d_tank_control2", queuedTankName); 
	LogMessage("[tank_control] admin pick by %L: %L", client, queuedTank);
	QueueHunterFirst(queuedTank);
	
	return Plugin_Handled;	
}

public Action:Command_FindNexTank(client, args)
{
	if (client<=0 || IsPluginDisabled()) return Plugin_Handled;

	new iTeam = GetClientTeam(client);

	if(queuedTank== -2)
		ChooseTank();
	if(queuedTank== -1 && iTeam !=2){
		CPrintToChat(client, "%T","l4d_tank_control3",client); 
	}
	else if (queuedTank>0)
	{
		decl String:queuedTankName[128];
		GetClientName(queuedTank,queuedTankName,128);
		CPrintToChat(client, "%T","player will be the tank",client, queuedTankName); 
	}
	
	
	PrintTankOwners(client);
	return Plugin_Handled;
}

PrintTankOwners(client)//給玩家debug用,查看那些人已經當過tank
{
	new iMaxArray = GetArraySize(hTeamTanks);
	new iMaxArrayFinal = GetArraySize(hTeamFinalTanks);
	decl String:sTankSteamId[64], i;

	PrintToConsole(client, "The tanks were in control of:");
	
	for (new iIndex; iIndex < iMaxArray; iIndex++){

		GetArrayString(hTeamTanks, iIndex, sTankSteamId, sizeof(sTankSteamId));
		if ((i= GetPlayerBySteamId(sTankSteamId))){

			PrintToConsole(client, "0%d. %N [%s]", iIndex + 1, i, sTankSteamId);
		}
		else
			PrintToConsole(client, "0%d. (left the team) [%s]", iIndex + 1, sTankSteamId);
			
	}
	
	if(IsFinal){
		PrintToConsole(client, "The Final tanks were in control of:");
		
		for (new iIndex; iIndex < iMaxArrayFinal; iIndex++){

			GetArrayString(hTeamFinalTanks, iIndex, sTankSteamId, sizeof(sTankSteamId));
			if ((i= GetPlayerBySteamId(sTankSteamId))){

				PrintToConsole(client, "0%d. %N [%s]", iIndex + 1, i, sTankSteamId);
			}
			else
				PrintToConsole(client, "0%d. (left the team) [%s]", iIndex + 1, sTankSteamId);
				
		}
	}
}

public OnMapStart()//每個地圖的第一關載入時清除所有has been tank list
{
	if(L4D_IsFirstMapInScenario())
	{
		ClearArray(hTeamTanks);
		ClearArray(hTeamFinalTanks);
		ClearArray(hPreviousMapTeamTanks);
		GetCurrentMap(previousmap, sizeof(previousmap));
		return;
	}
	IsFinal = (L4D_IsMissionFinalMap())? true: false;
	
	decl String:currentmap[128];
	GetCurrentMap(currentmap, sizeof(currentmap));
	if(StrEqual(currentmap, previousmap))
	{
		new iMaxArray = GetArraySize(hPreviousMapTeamTanks);
		decl String:sTankSteamId[64], i;
		for (new iIndex; iIndex < iMaxArray; iIndex++)
		{
			GetArrayString(hPreviousMapTeamTanks, iIndex, sTankSteamId, sizeof(sTankSteamId));//前地圖當過坦克的玩家
			if( (i = FindStringInArray(hTeamTanks,sTankSteamId)) != -1)
				RemoveFromArray(hTeamTanks,i);
			if(IsFinal)
			{
				if( (i = FindStringInArray(hTeamFinalTanks,sTankSteamId)) != -1)
					RemoveFromArray(hTeamFinalTanks,i);
			}
		}		
	}
	strcopy(previousmap, sizeof(previousmap),currentmap);
	ClearArray(hPreviousMapTeamTanks);
}

public void TC_ev_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 3 && IsPlayerAlive(client) && IsPlayerTank(client))
	{
		queuedTank = 0;
		g_iQueuedSource = QT_NONE;
	}
	// riverside2: the half's first SI or tank is out, so hunter first stops. Humans are caught by
	// L4D_OnMaterializeFromGhost; bots (and a tank) never pass through a ghost.
	if (g_bHalfLive && client && IsClientInGame(client) && GetClientTeam(client) == 3 && IsPlayerAlive(client)
		&& (IsFakeClient(client) || IsPlayerTank(client)))
		g_bFirstSpawned = true;
}

public void L4D_OnMaterializeFromGhost(int client)
{
	if (g_bHalfLive) g_bFirstSpawned = true;
}

public Action:TC_ev_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	queuedTank = 0;
	g_iQueuedSource = QT_NONE;
	IsSecondTank = false;
	g_sFirstPickSteamId[0] = '\0';
	g_bHalfLive = false;
	g_bFirstSpawned = false;
	StartPreRound();
}

// riverside3: the next half's ghosts can appear before its round_start; stale flags from the half that just
// ended must not block them (L4D_OnEnterGhostState returns on g_bFirstSpawned).
public void TC_ev_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bHalfLive = false;
	g_bFirstSpawned = false;
}

public void OnMapEnd()
{
	g_hPreRoundTimer = null;	// TIMER_FLAG_NO_MAPCHANGE already killed it
}

static void StartPreRound()
{
	g_iPreRoundSig = 0;
	g_sLastSkip[0] = '\0';
	delete g_hPreRoundTimer;
	g_hPreRoundTimer = CreateTimer(1.0, Timer_PreRound, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PreRound(Handle timer)
{
	if (g_bHalfLive || g_bFirstSpawned || IsSecondTank)
	{
		g_hPreRoundTimer = null;
		return Plugin_Stop;
	}
	if (!IsPluginDisabled()) PreRoundPick();
	return Plugin_Continue;
}

/**
 * riverside3: during ready-up (or before the survivors leave without l4dready) choose the half's first tank
 * as soon as the infected side can answer, announce it, and give him his hunter then, so nobody's class
 * changes at go-live. The plan (pug-match) is asked again only when the infected humans change, since every
 * PUG_PlannedTank call logs a line. With no answer from the plan, the random "everyone once" pick waits for a
 * full infected team so it cannot pick among the first players to load. Go-live keeps its own pick for
 * anything left open (Native_ChoseTankPrintWhoBecome).
 */
static void PreRoundPick()
{
	if (queuedTank > 0 && IsInfectedHuman(queuedTank))
	{
		HunterFirst(queuedTank);	// no-op once he is a hunter; waits for his and a partner's ghost
		return;
	}

	int sig = 0, humans = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsInfectedHuman(i)) continue;
		humans++;
		sig = sig * 31 + GetClientUserId(i);
	}
	if (humans == 0 || sig == g_iPreRoundSig) return;
	g_iPreRoundSig = sig;

	int was = queuedTank;
	if (!ChoosePlannedTank())
	{
		if (humans < g_hCvarInfLimit.IntValue) return;	// still loading: the plan or a full team will answer
		ChooseTank();
	}
	if (queuedTank > 0 && queuedTank != was)
	{
		LogMessage("[tank_control] pre-round pick (%s): %L", g_iQueuedSource == QT_PLAN ? "pug-match tank order" : "random", queuedTank);
		char name[128];
		GetClientName(queuedTank, name, sizeof(name));
		CPrintToChatAll("%t", "player will be the tank", name);
		QueueHunterFirst(queuedTank);
	}
}

public TC_ev_OnTeamChange(Handle:event, String:name[], bool:dontBroadcast)
{
	if (IsPluginDisabled()) return;

	// riverside2 (upstream 2.4): a userid, so the check one second later cannot hit a new client in the same slot
	CreateTimer(1.0, PlayerChangeTeamCheck, GetEventInt(event, "userid"));//延遲一秒檢查
}
public Action:PlayerChangeTeamCheck(Handle:timer, any:userid)
{
	if (IsPluginDisabled()) return Plugin_Continue;
	new client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Continue;	// a disconnect is OnClientDisconnect's
	if (GetClientTeam(client) == 3)
		TryRestoreFirstTank(client);
	else if (client == queuedTank)
		ChoseTankAndPrintWhoBecome();
	return Plugin_Continue;
}
public OnClientDisconnect(client)
{
	if (IsPluginDisabled() || !IsClientInGame(client) || IsFakeClient(client)) return;

	// riverside2: re-pick on the next frame, once he is gone. Still in game here, so pug-match's plan
	// would hand the slot straight back to him instead of to a sub.
	if (client && client == queuedTank)
		RequestFrame(Frame_RepickAfterLeave);
}

public void Frame_RepickAfterLeave(any unused)
{
	if (IsPluginDisabled() || queuedTank <= 0) return;
	if (IsClientInGame(queuedTank) && !IsFakeClient(queuedTank) && GetClientTeam(queuedTank) == 3) return;	// already replaced
	ChoseTankAndPrintWhoBecome();
}

ChoseTankAndPrintWhoBecome()
{
	if (IsPluginDisabled()) return;
	ChooseTank();
	if (queuedTank>0) {
		decl String:queuedTankName[128];
		GetClientName(queuedTank,queuedTankName,128);
		CPrintToChatAll("%t","player will be the tank", queuedTankName); 
		QueueHunterFirst(queuedTank);
	}
	else if (queuedTank==-1){
		CPrintToChatAll("%t","l4d_tank_control3"); 
	}
	else if (queuedTank==-2){
		CPrintToChatAll("%t","l4d_tank_control4");
	}
}

public Action L4D_OnTryOfferingTankBot(int tank_index, bool &enterStasis)
{
	if(IsPluginDisabled()) return Plugin_Continue;

	if(L4D2Direct_GetTankPassedCount() >= 2)
		return Plugin_Continue;	

	if (tank_index && IsClientInGame(tank_index) && !IsFakeClient(tank_index)){
		for (int i=1; i <= MaxClients; i++) {
			if (!IsClientInGame(i))
				continue;

			if (GetClientTeam(i) == 2)
				continue;
				
			static char tank_indexName[128];
			GetClientName(tank_index,tank_indexName,128);
			CPrintToChat(i, "%T","l4d_tank_control5",i, tank_indexName);
			if (GetClientTeam(i) == 1) continue;

			CPrintToChat(i, "%T","l4d_tank_control6",i);
		}
		SetTankFrustration(tank_index, 100);
		L4D2Direct_SetTankPassedCount(L4D2Direct_GetTankPassedCount() + 1);
		LogMessage("[tank_control] no pass: rage refilled for %L (passed count now %d)", tank_index, L4D2Direct_GetTankPassedCount());

		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void L4D_OnTryOfferingTankBot_Post(int tank_index, bool enterStasis)
{
	if (IsPluginDisabled()) 
		return;

	if(L4D2Direct_GetTankPassedCount() >= 1)
		return;	

	// riverside2: the map's first tank goes to the planned slot's owner if he is here right now
	if (!IsSecondTank) ReaskPlanBeforeFirstTank();

	if(IsSecondTank && queuedTank<=0)//第二隻克以後
	{
		ChooseTank();
		if(queuedTank == -1 && IsFinal) //最後一關所有人都當過另外重新輪盤 第二隻以後的克皆是不同的人當
			ChooseFinalTank();
	}
	else if (queuedTank == -2)//本來特感沒有人 現在克復活再選一次人
	{
		ChooseTank();
	}
	else if (queuedTank == -1)//自由搶第一隻克
	{
		CreateTimer(5.0, CheckForAITank, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	if (queuedTank>0){
		ForceTankPlayer(queuedTank);//強制該玩家當tank

		// riverside2 (upstream 2.4): skip the bookkeeping when the auth id cannot be read
		decl String:sTankSteamId[32];
		if (GetClientAuthId(queuedTank, AuthId_Steam2, sTankSteamId, sizeof(sTankSteamId)))
		{
			if(HasBeenTank(sTankSteamId) == false)
			{
				if(FindStringInArray(hTeamTanks, sTankSteamId) == -1)
					PushArrayString(hTeamTanks, sTankSteamId);
			}
			if(IsFinal)
			{
				if(FindStringInArray(hTeamFinalTanks, sTankSteamId) == -1)
					PushArrayString(hTeamFinalTanks, sTankSteamId);
			}
				
			if(FindStringInArray(hPreviousMapTeamTanks, sTankSteamId) == -1)
				PushArrayString(hPreviousMapTeamTanks, sTankSteamId);
		}
	}
	IsSecondTank = true;//已經第一隻Tank了
	g_sFirstPickSteamId[0] = '\0';
}

public Action:KickBot(Handle:timer, any:client)
{
	if ( client && IsClientInGame(client) && IsFakeClient(client))
	{
		KickClient(client);
	}
}

public Action:CheckForAITank(Handle:timer)
{

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 3 && GetEntProp(i, Prop_Send, "m_zombieClass") == 5)
		{
			if (!IsFakeClient(i))//Tank is not AI
			{
				decl String:SteamId[32];
				if (!GetClientAuthId(i, AuthId_Steam2, SteamId, sizeof(SteamId)))
					return Plugin_Handled;

				if(HasBeenTank(SteamId) == false)
				{
					// Riverside: upstream pushed tankSteamId (the last queued
					// tank) here, so a free-for-all tank was never recorded.
					if(FindStringInArray(hTeamTanks, SteamId) == -1)
						PushArrayString(hTeamTanks, SteamId);
				}
				if(IsFinal)
				{
					if(FindStringInArray(hTeamFinalTanks, SteamId) == -1)
						PushArrayString(hTeamFinalTanks, SteamId);
				}

			}
			return Plugin_Handled;
		}
	}
	return Plugin_Handled;
}

static ChooseFinalTank() {

	decl String:SteamId[32];
	new Handle:SteamIds = CreateArray(32);
	new infectedplayer = 0;

	for (new i = 1; i < MaxClients+1; i++) {
		if (!IsClientInGame(i) ||IsFakeClient(i)) {
			continue;
		}
		if(!IsInfected(i))
			continue;

		infectedplayer++;

		if (!GetClientAuthId(i, AuthId_Steam2, SteamId, sizeof(SteamId))) {
			continue;
		}

		if (HasBeenFinalTank(SteamId) || i == queuedTank) {
			continue;
		}

		if(FindStringInArray(SteamIds, SteamId) == -1)
			PushArrayString(SteamIds, SteamId);
	}

	if (GetArraySize(SteamIds) == 0) {//沒有人可以成為tank
		CloseHandle(SteamIds);	// riverside2: was leaked on every call
		g_iQueuedSource = QT_NONE;
		if(infectedplayer == 0)//1.SI沒有人
			queuedTank = -2;
		else//2.代表兩邊的隊伍都找過 特感這裡所有人都當過tank
			queuedTank = -1;
		return;
	}

	// Using "int random" to vary the output
	// Using "GetGameTickCount" to vary the output
	// Using "SetRandomSeed" to generate a truly random number
	// Without this, the server will always output the same random numbers in the same order over reboots
	int random = GetRandomInt(0, 2147483647);
	SetRandomSeed(GetGameTickCount() + random);
	int idx = GetRandomInt(0, GetArraySize(SteamIds)-1);
	decl String:sTankSteamId[32];
	GetArrayString(SteamIds, idx, sTankSteamId, sizeof(sTankSteamId));
	CloseHandle(SteamIds);
	queuedTank = GetInfectedPlayerBySteamId(sTankSteamId);
	g_iQueuedSource = (queuedTank > 0) ? QT_RANDOM : QT_NONE;
}

static bool:HasBeenFinalTank(const String:SteamId[])
{
	if(FindStringInArray(hTeamFinalTanks, SteamId) != -1)
		return true;
	else
		return false;
}

static bool:HasBeenTank(const String:SteamId[])
{
	if(FindStringInArray(hTeamTanks, SteamId) != -1)
		return true;
	else
		return false;
}

/**
 * Riverside: a PUG match with a tank order (pug-match's PUG_PlannedTank) picks
 * the map's first tank by SR rank slot, the same slot on both teams; the site
 * shuffles which slot tanks which map. Anything else (no plan, self-started,
 * the planned player gone with no sub) falls through to upstream's random
 * "everyone once" pick below. A second tank on the same map always does.
 */
static bool:ChoosePlannedTank()
{
	if (IsSecondTank) return false;
	if (GetFeatureStatus(FeatureType_Native, "PUG_PlannedTank") != FeatureStatus_Available) return false;
	new planned = PUG_PlannedTank();
	if (planned <= 0 || !IsClientInGame(planned) || GetClientTeam(planned) != 3) return false;
	queuedTank = planned;
	g_iQueuedSource = QT_PLAN;
	LogMessage("[tank_control] planned pick (pug-match tank order): %L", planned);
	return true;
}

static ChooseTank() {

	if (ChoosePlannedTank()) return;

	decl String:SteamId[32];
	new Handle:SteamIds = CreateArray(32);
	new infectedplayer = 0;

	for (new i = 1; i < MaxClients+1; i++) {
		if (!IsClientInGame(i) ||IsFakeClient(i)) {
			continue;
		}
		if(!IsInfected(i))
			continue;

		infectedplayer++;

		if (!GetClientAuthId(i, AuthId_Steam2, SteamId, sizeof(SteamId))) {
			continue;
		}

		if (HasBeenTank(SteamId) || i == queuedTank) {
			continue;
		}

		if(FindStringInArray(SteamIds, SteamId) == -1)
			PushArrayString(SteamIds, SteamId);
	}

	if (GetArraySize(SteamIds) == 0) {//沒有人可以成為tank
		CloseHandle(SteamIds);	// riverside2: was leaked on every call
		g_iQueuedSource = QT_NONE;
		if(infectedplayer == 0)//1.SI沒有人
			queuedTank = -2;
		else//2.代表兩邊的隊伍都找過 特感這裡所有人都當過tank
			queuedTank = -1;
		return;
	}

	// Using "int random" to vary the output
	// Using "GetGameTickCount" to vary the output
	// Using "SetRandomSeed" to generate a truly random number
	// Without this, the server will always output the same random numbers in the same order over reboots
	int random = GetRandomInt(0, 2147483647);
	SetRandomSeed(GetGameTickCount() + random);
	int idx = GetRandomInt(0, GetArraySize(SteamIds)-1);
	decl String:sTankSteamId[32];
	GetArrayString(SteamIds, idx, sTankSteamId, sizeof(sTankSteamId));
	queuedTank = GetInfectedPlayerBySteamId(sTankSteamId);
	g_iQueuedSource = (queuedTank > 0) ? QT_RANDOM : QT_NONE;
	if (queuedTank > 0)
	{
		LogMessage("[tank_control] random pick (not tanked yet, %d candidates): %L", GetArraySize(SteamIds), queuedTank);
		// riverside2: the half's first random pick gets it back if he drops and returns before the first tank
		if (!IsSecondTank && g_sFirstPickSteamId[0] == '\0')
			strcopy(g_sFirstPickSteamId, sizeof(g_sFirstPickSteamId), sTankSteamId);
	}
	CloseHandle(SteamIds);
}

static ForceTankPlayer(iTank) {
	for (new i = 1; i < MaxClients+1; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}

		if (IsInfected(i)) {
			if (iTank == i) {
				L4D2Direct_SetTankTickets(i, 1000);
			}
			else {
				L4D2Direct_SetTankTickets(i, 0);
			}
		}
	}
}

static GetInfectedPlayerBySteamId(const String:SteamId[]) {
	decl String:cmpSteamId[32];

	for (new i = 1; i < MaxClients+1; i++) {
		if (!IsInfected(i)) {
			continue;
		}

		if (!GetClientAuthId(i, AuthId_Steam2, cmpSteamId, sizeof(cmpSteamId))) {
			continue;
		}

		if (StrEqual(SteamId, cmpSteamId)) {
			return i;
		}
	}

	return 0;
}

static GetPlayerBySteamId(const String:SteamId[]) {
	decl String:cmpSteamId[32];

	for (new i = 1; i < MaxClients+1; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}

		if (!GetClientAuthId(i, AuthId_Steam2, cmpSteamId, sizeof(cmpSteamId))) {
			continue;
		}

		if (StrEqual(SteamId, cmpSteamId)) {
			return i;
		}
	}

	return 0;
}

/**
 * riverside2: keep the planned tank. Upstream re-picks at random when the queued tank leaves the infected
 * team (disconnect, crash, a spell in spectate) and never gives it back, so in a PUG a teammate of another
 * SR rank tanked the map while the other team's same-rank player still did. A player joining the infected
 * team before the map's first tank is handed out gets it back when he is the plan's pick (or, with no plan,
 * the half's first random pick).
 *
 * pug-match's PUG_PlannedTank() returns the slot's owner whenever he is on the infected side, else a random
 * unslotted player (a sub). A tank the plan already chose who is still on the team is only replaced by the
 * player who just joined, so two subs cannot keep trading the slot on every team change.
 */
static bool PlanAvailable()
{
	return GetFeatureStatus(FeatureType_Native, "PUG_PlannedTank") == FeatureStatus_Available;
}

static bool IsInfectedHuman(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 3;
}

static void TryRestoreFirstTank(int joined)
{
	if (IsSecondTank || queuedTank == 0) return;	// 0: nobody chosen yet this half, go-live will ask the plan
	if (g_iQueuedSource == QT_ADMIN && IsInfectedHuman(queuedTank)) return;

	int want = 0;
	char why[48];
	if (PlanAvailable())
	{
		int planned = PUG_PlannedTank();
		if (planned > 0)
		{
			if (planned == queuedTank || !IsInfectedHuman(planned)) return;
			if (g_iQueuedSource == QT_PLAN && IsInfectedHuman(queuedTank) && planned != joined) return;
			want = planned;
			strcopy(why, sizeof(why), "pug-match tank order");
		}
	}
	if (want == 0 && g_sFirstPickSteamId[0] != '\0' && joined != queuedTank)
	{
		char sid[32];
		if (GetClientAuthId(joined, AuthId_Steam2, sid, sizeof(sid)) && StrEqual(sid, g_sFirstPickSteamId))
		{
			want = joined;
			strcopy(why, sizeof(why), "first random pick returned");
		}
	}
	if (want == 0) return;

	if (queuedTank > 0 && IsClientInGame(queuedTank))
		LogMessage("[tank_control] restore (%s): %L, was %L", why, want, queuedTank);
	else
		LogMessage("[tank_control] restore (%s): %L, was none (%d)", why, want, queuedTank);
	queuedTank = want;
	g_iQueuedSource = StrEqual(why, "pug-match tank order") ? QT_PLAN : QT_RANDOM;
	char name[128];
	GetClientName(want, name, sizeof(name));
	CPrintToChatAll("%t", "player will be the tank", name);
	QueueHunterFirst(want);
}

/** The first tank is being offered: last chance for the slot owner who is here now. */
static void ReaskPlanBeforeFirstTank()
{
	if (!PlanAvailable()) return;
	if (g_iQueuedSource == QT_ADMIN && IsInfectedHuman(queuedTank)) return;
	if (g_iQueuedSource == QT_PLAN && IsInfectedHuman(queuedTank)) return;	// already the plan's (owner or sub)
	int planned = PUG_PlannedTank();
	if (planned <= 0 || planned == queuedTank || !IsInfectedHuman(planned)) return;
	if (queuedTank > 0 && IsClientInGame(queuedTank))
		LogMessage("[tank_control] restore (plan re-asked at first tank): %L, was %L", planned, queuedTank);
	else
		LogMessage("[tank_control] restore (plan re-asked at first tank): %L, was none (%d)", planned, queuedTank);
	queuedTank = planned;
	g_iQueuedSource = QT_PLAN;
}

/**
 * riverside2: hunter first (owner request 2026-11-18). The map's first tank starts the half as a hunter, so
 * the team's smoker or boomer is not the one who turns into the tank. The first attack keeps its stock
 * composition: his ghost class is SWAPPED with a teammate ghost holding a hunter, never added. Each swap
 * moves m_classSpawnCount the way QuadCaps' Timer_DirtyBoomer does (the dealt class -1, the new one +1), so
 * stock rotation stays fair. Only ghosts, only before the half's first SI or tank is out, never a tank.
 *
 * QuadCaps: a swap leaves the team's class counts as they were, so its go-live snapshot (KeepSIStarting) and
 * its half-two ready-up count enforcement (Sub_DetermineClass) read the same numbers; its dirty boomer and
 * no-quad rules start from SI deaths in a live half, and none has happened before the first spawn.
 */
static void QueueHunterFirst(int client)
{
	if (client > 0 && IsClientInGame(client))
		CreateTimer(HUNTER_FIRST_DELAY, Timer_HunterFirst, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_HunterFirst(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && client == queuedTank)	// still the queued tank 0.3 s later
		HunterFirst(client);
	return Plugin_Continue;
}

public void L4D_OnEnterGhostState(int client)
{
	if (IsPluginDisabled() || !g_hCvarHunterFirst.BoolValue || IsSecondTank || g_bFirstSpawned) return;
	if (!IsInfectedHuman(client)) return;
	CreateTimer(HUNTER_FIRST_DELAY, Timer_GhostHunterFirst, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_GhostHunterFirst(Handle timer, any userid)
{
	if (IsPluginDisabled() || IsSecondTank || g_bFirstSpawned) return Plugin_Continue;
	if (!GetClientOfUserId(userid)) return Plugin_Continue;
	int tank = queuedTank;
	// ready-up: the tank is chosen at go-live, but with a plan the players can see their real class now
	if (tank <= 0 && !g_bHalfLive && PlanAvailable())
		tank = PUG_PlannedTank();
	if (tank > 0) HunterFirst(tank);
	return Plugin_Continue;
}

static bool IsHumanGhost(int client)
{
	return IsInfectedHuman(client) && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_isGhost") == 1;
}

static int ZClass(int client)
{
	return GetEntProp(client, Prop_Send, "m_zombieClass");
}

static void ClassName(int zclass, char[] buf, int len)
{
	switch (zclass)
	{
		case ZC_SMOKER: strcopy(buf, len, "Smoker");
		case ZC_BOOMER: strcopy(buf, len, "Boomer");
		case ZC_HUNTER: strcopy(buf, len, "Hunter");
		case ZC_TANK:   strcopy(buf, len, "Tank");
		default:        FormatEx(buf, len, "class %d", zclass);
	}
}

/** Move this life's spawn count from the dealt class to the new one, then change the ghost's class. */
static void SetGhostClass(int client, int from, int to)
{
	int n = GetEntProp(client, Prop_Send, "m_classSpawnCount", 4, from);
	if (n > 0) SetEntProp(client, Prop_Send, "m_classSpawnCount", n - 1, 4, from);
	SetEntProp(client, Prop_Send, "m_classSpawnCount", GetEntProp(client, Prop_Send, "m_classSpawnCount", 4, to) + 1, 4, to);
	L4D_SetClass(client, to);
}

static void HunterFirst(int tank)
{
	if (IsPluginDisabled() || !g_hCvarHunterFirst.BoolValue || IsSecondTank || g_bFirstSpawned) return;
	if (!IsHumanGhost(tank)) return;	// not a ghost yet (or spawned): his own ghost entry comes back here
	int tankClass = ZClass(tank);
	if (tankClass == ZC_HUNTER || tankClass == ZC_TANK) return;
	if (tankClass != ZC_SMOKER && tankClass != ZC_BOOMER) return;

	int partners[MAXPLAYERS + 1], nPartners = 0, hunters = 0, sameClass = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 3 || !IsPlayerAlive(i)) continue;
		int zc = ZClass(i);
		if (zc == ZC_HUNTER)
		{
			hunters++;
			if (i != tank && IsHumanGhost(i)) partners[nPartners++] = i;
		}
		else if (zc == tankClass && i != tank) sameClass++;	// other players of his class
	}

	char tankName[MAX_NAME_LENGTH], oldClass[16];
	GetClientName(tank, tankName, sizeof(tankName));
	ClassName(tankClass, oldClass, sizeof(oldClass));

	if (nPartners > 0)
	{
		int partner = partners[GetRandomInt(0, nPartners - 1)];
		char partnerName[MAX_NAME_LENGTH];
		GetClientName(partner, partnerName, sizeof(partnerName));
		SetGhostClass(tank, tankClass, ZC_HUNTER);
		SetGhostClass(partner, ZC_HUNTER, tankClass);
		LogMessage("[tank_control] hunter first: %L (was %s) <-> %L (was Hunter)", tank, oldClass, partner);
		PrintToChat(tank, "[Tank] You will be the tank this map, so you start as Hunter; you swapped classes with %s (now %s).", partnerName, oldClass);
		PrintToChat(partner, "[Tank] %s will be the tank this map and starts as Hunter; you swapped classes with them (you are now %s).", tankName, oldClass);
		return;
	}

	// no teammate ghost holds a hunter: change him alone only if the hunter limit allows it and his class
	// is not the team's only smoker / boomer under a limit of 1
	int hunterLimit = (g_hCvarHunterLimit != null) ? g_hCvarHunterLimit.IntValue : 0;
	ConVar classLimitCvar = (tankClass == ZC_SMOKER) ? g_hCvarSmokerLimit : g_hCvarBoomerLimit;
	int classLimit = (classLimitCvar != null) ? classLimitCvar.IntValue : 0;
	if (hunters >= hunterLimit)
	{
		LogSkipOnce("[tank_control] hunter first skipped: %L is %s, no hunter ghost to swap with and the team has %d of z_hunter_limit %d hunters", tank, oldClass, hunters, hunterLimit);
		return;
	}
	if (classLimit == 1 && sameClass == 0)
	{
		LogSkipOnce("[tank_control] hunter first skipped: %L is the team's only %s (limit 1) and no hunter ghost to swap with", tank, oldClass);
		return;
	}
	SetGhostClass(tank, tankClass, ZC_HUNTER);
	LogMessage("[tank_control] hunter first: %L (was %s) -> Hunter, no hunter ghost to swap with (%d of z_hunter_limit %d hunters)", tank, oldClass, hunters, hunterLimit);
	PrintToChat(tank, "[Tank] You will be the tank this map, so you start as Hunter (was %s).", oldClass);
}

/** riverside3: the pre-round poll retries every second; log each skip reason once per half. */
static void LogSkipOnce(const char[] fmt, any ...)
{
	char msg[192];
	VFormat(msg, sizeof(msg), fmt, 2);
	if (StrEqual(msg, g_sLastSkip)) return;
	strcopy(g_sLastSkip, sizeof(g_sLastSkip), msg);
	LogMessage("%s", msg);
}

bool:IsPluginDisabled()
{
	if(g_bCvartankcontroldisable)
		return true;
	return (g_hCvarInfLimit.IntValue == 1 || g_hCvarSurLimit.IntValue == 1);
}


public OnCvarChange_tank_control_disable(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (!StrEqual(oldValue, newValue))
		g_bCvartankcontroldisable = GetConVarBool(convar);	
}

public Action:ClearTeam_Cmd(client, args)
{
	if(IsPluginDisabled())
		return;
	ClearArray(hTeamTanks);
	ClearArray(hTeamFinalTanks);
	ClearArray(hPreviousMapTeamTanks);	
	
	ReplyToCommand(client,"[TS] %T","Tank Control has been clear and reset!",client);
}