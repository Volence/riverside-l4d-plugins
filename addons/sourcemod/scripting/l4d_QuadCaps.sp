#include <sourcemod>
#include <sdktools>

#define PLUGIN_FILENAME		"l4d_QuadCaps"
#define DEBUG 0
#define ZC_TIMEROFFSET		0.8
#define TEAM_SPECTATORS		1
#define TEAM_SURVIVORS		2
#define TEAM_INFECTED		3
#define ZC_SMOKER		1
#define ZC_BOOMER		2
#define ZC_HUNTER		3
#define ZC_WITCH		4
#define ZC_TANK			5
#define TEAM_CLASS(%1)		(%1 == 1 ? "Smoker" : (%1 == 2 ? "Boomer" : (%1 == 3 ? "Hunter" :(%1 == 4 ? "Witch" : (%1 == 5 ? "Tank" : "None")))))
#define OnEnterGhostCheckDelay 0.1
#define KeepSITrackingCheckDelay 0.25
#define KEEPSICHECKDELAY 0.1

static bool:PluginDisable = false;
static bool:hasleftstartarea;
// riverside2: false from round_end to the next round_start
static bool:g_bRoundLive = true;
// riverside2: the boomer/smoker limits hold this plugin's temporary values
static bool:g_bLimitsOverridden = false;
// riverside3 (server.so audit, l4d-source docs/annotated/si-class-selection/):
// IsClassOverLimit reads z_versus_*_limit live at every ghost spawn, so the override must
// cover exactly the window it is meant for.
//  - g_bHalfLive: deaths count only once the half is live (l4dready's go-live calls
//    Keep_SI_Starting; without l4dready, the survivors leaving the start area). A boomer
//    killed in the ~0.25 s between round_start and ready-up turning on used to set the
//    override, which ready-up then carried into go-live: the fake "boomer_limit 0" patches.
//  - The limits are saved when the override is set and put back only if it is in place
//    (riverside2 restored a per-map snapshot at every round_end, undoing mid-map changes).
// riverside5 (owner ruling 2026-10-26): the next SI death lifts the ban at once, as upstream. riverside3/4 held it
// until the boomer's player had a new class, so a boomer that died BEFORE the last SI of its wave still banned
// him from boomer: match 834 x1m3, boomer died 3rd and smoker last, and the next wave came out 3 hunters + smoker.
// riverside6 (owner ruling 2026-10-28, forum thread "boomer die last"): smoker dies last = a dirty (hunters + exactly
// one boomer), never a quad. Stock picks each player's least-played class, so smoker-last gave 3H+1B only ~55% of the
// time and could give 4 hunters. A smoker death now bans smoker AND boomer (so stock deals hunters) until the next SI
// death, as the boomer ban does, and the smoker's own player is switched to boomer when he next becomes a ghost.
// If he leaves the team before that, the boomer limit goes back so stock can still deal one boomer.
static bool:g_bHalfLive = false;
static g_iSavedSmokerLimit, g_iSavedBoomerLimit;
static g_iDirtyUserid;	// riverside6: the smoker's player who is owed the boomer, 0 = none
new Handle:hCvarDirtyAfterSmoker;
// riverside7 (owner ruling 2026-10-28): hunter dies last = stock classes, but never a quad. Stock can still deal 3 hunters +
// smoker (or 4 hunters) there. Until the next SI death, each new ghost checks the team: once nobody is left waiting to
// respawn and the living team (ghosts included) still has no boomer, that last ghost is switched to boomer.
static bool:g_bNoQuadPending = false;
new Handle:hCvarNoQuadAfterHunter;
// riverside8 (2026-10-28, live report of two boomers): riverside6 fired on ANY smoker death, so a smoker dying while the
// last wave's boomer was still up switched his player to a second boomer. Dirty now needs no other living boomer, both
// at the smoker's death and again when his ghost is switched.
new Handle:HCVAR_Z_VS_SMOKER_LIMIT;
new Handle:HCVAR_Z_VS_BOOMER_LIMIT;
new Handle:HCVAR_Z_HUNTER_LIMIT;
new Handle:hCvar3HT1SProbability;
new CVAR_Z_VS_SMOKER_LIMIT_ORIGINAL = 1, CVAR_Z_VS_BOOMER_LIMIT_ORIGINAL = 1, CVAR_Z_HUNTER_LIMIT = 2, Cvar3HT1SProbability;
static Hunter_Starting_Line,Smoker_Starting_Line,Boomer_Starting_Line;
new Handle:g_hSetClass		= INVALID_HANDLE;
new Handle:g_hCreateAbility	= INVALID_HANDLE;
new g_oAbility			= 0;
int g_iRoundStart, g_iPlayerSpawn;
native IsInReady();
native Is_Ready_Plugin_On();

public Plugin:myinfo = 
{
	name = "L4D Quad Caps Control",
	author = "Harry Potter",
	description = "As the name says, you dumb fuck",
	version = "1.5-riverside8",
	url = "http://steamcommunity.com/profiles/76561198026784913"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	EngineVersion test = GetEngineVersion();

	if( test != Engine_Left4Dead )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1.");
		return APLRes_SilentFailure;
	}

	CreateNative("Keep_SI_Starting", Native_KeepSIStarting);
	MarkNativeAsOptional("IsInReady");
	MarkNativeAsOptional("Is_Ready_Plugin_On");
	return APLRes_Success;
}

// riverside1: l4dready natives threw on every call while l4dready was paused or reloading (2341 errors seen locally);
// a missing or paused l4dready now reads as "not in ready" / "ready plugin off"
bool L4dReadyUsable()
{
	if (GetFeatureStatus(FeatureType_Native, "IsInReady") != FeatureStatus_Available
		|| GetFeatureStatus(FeatureType_Native, "Is_Ready_Plugin_On") != FeatureStatus_Available)
		return false;

	Handle hReady = FindPluginByFile("l4dready.smx");
	return hReady != INVALID_HANDLE && GetPluginStatus(hReady) == Plugin_Running;
}

bool SafeIsInReady()
{
	return L4dReadyUsable() && IsInReady();
}

bool SafeIsReadyPluginOn()
{
	return L4dReadyUsable() && Is_Ready_Plugin_On();
}

public Native_KeepSIStarting(Handle:plugin, numParams)
{
	// l4dready's go-live: the half starts now
	HalfGoesLive();
	CreateTimer(KEEPSICHECKDELAY,KeepSIStarting,_); // delay check
}

void HalfGoesLive()
{
	g_bHalfLive = true;
	if (g_bLimitsOverridden) RestoreLimits();
}

public OnPluginStart()
{
	Sub_HookGameData(PLUGIN_FILENAME);
	
	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("mission_lost", Event_RoundEnd);
	HookEvent("finale_win", Event_RoundEnd);
	HookEvent("player_death", Event_PlayerDeath,	EventHookMode_Post);	// riverside3: it reads userid, NoCopy only worked by luck
	HookEvent("player_left_start_area", LeftStartAreaEvent, EventHookMode_PostNoCopy);
	HookEvent("player_team", Event_PlayerTeam);
	
	HCVAR_Z_VS_SMOKER_LIMIT = FindConVar("z_versus_smoker_limit");
	HCVAR_Z_VS_BOOMER_LIMIT = FindConVar("z_versus_boomer_limit");
	HCVAR_Z_HUNTER_LIMIT = FindConVar("z_hunter_limit");
	hCvar3HT1SProbability = CreateConVar("sm_3ht1s_percent_chance", "90", "X% chance of 3+1 and 100-X% remaining chance of 4ht after Boomer dies", FCVAR_NOTIFY, true, 0.0,true, 100.0);
	hCvarDirtyAfterSmoker = CreateConVar("sm_dirty_after_smoker", "1", "1 = smoker dies last gives hunters + exactly one boomer (the smoker's player)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	hCvarNoQuadAfterHunter = CreateConVar("sm_noquad_after_hunter", "1", "1 = hunter dies last never gives a quad (the last ghost of the wave becomes the boomer if nobody else is one)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	
	CVAR_Z_VS_SMOKER_LIMIT_ORIGINAL = GetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT);
	CVAR_Z_VS_BOOMER_LIMIT_ORIGINAL = GetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT);
	CVAR_Z_HUNTER_LIMIT = GetConVarInt(HCVAR_Z_HUNTER_LIMIT);
	Cvar3HT1SProbability = GetConVarInt(hCvar3HT1SProbability);
	
	HookConVarChange(hCvar3HT1SProbability, ConVarChange_hCvar3HT1SProbability);
	
	PluginDisable = false;
}

public OnConfigsExecuted()
{
	CVAR_Z_VS_SMOKER_LIMIT_ORIGINAL = GetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT);
	CVAR_Z_VS_BOOMER_LIMIT_ORIGINAL = GetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT);
	CVAR_Z_HUNTER_LIMIT = GetConVarInt(HCVAR_Z_HUNTER_LIMIT);
	
	if(CVAR_Z_VS_BOOMER_LIMIT_ORIGINAL == 0  && CVAR_Z_VS_SMOKER_LIMIT_ORIGINAL == 0) 
	{
		//LogMessage("detect \"Hunters Only\" mode, disable Quad Caps");
		PluginDisable = true;
	}
	else if(CVAR_Z_VS_BOOMER_LIMIT_ORIGINAL == 0)
	{
		//LogMessage("detect \"No Boomer\" mode, disable Quad Caps");
		PluginDisable = true;
	}
	else if(CVAR_Z_HUNTER_LIMIT < 2)
	{
		//LogMessage("detect \"z_hunter_limit < 2\", disable Quad Caps");
		PluginDisable = true;
	}
}

public OnPluginEnd()
{
	ResetConVar(HCVAR_Z_VS_SMOKER_LIMIT, true, true);
	ResetConVar(HCVAR_Z_VS_BOOMER_LIMIT, true, true);
	SetConvarDefault();
	ResetVariable();
	PluginDisable = false;
}

public void OnMapStart()
{	
	Hunter_Starting_Line = Smoker_Starting_Line = Boomer_Starting_Line = 0;
}

public OnMapEnd()
{
	g_bRoundLive = false;
	ResetConVar(HCVAR_Z_VS_SMOKER_LIMIT, true, true);
	ResetConVar(HCVAR_Z_VS_BOOMER_LIMIT, true, true);
	SetConvarDefault();
	ResetVariable();
	PluginDisable = false;
}

public Sub_HookGameData(String:GameDataFile[])
{
	new Handle:g_hGameConf = LoadGameConfigFile(GameDataFile);

	if (g_hGameConf != INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetFromConf(g_hGameConf, SDKConf_Signature, "SetClass");
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		g_hSetClass = EndPrepSDKCall();

		if (g_hSetClass == INVALID_HANDLE)
			SetFailState("Error: Unable to find SetClass signature.");

		StartPrepSDKCall(SDKCall_Static);
		PrepSDKCall_SetFromConf(g_hGameConf, SDKConf_Signature, "CreateAbility");
		PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
		PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
		g_hCreateAbility = EndPrepSDKCall();

		if (g_hCreateAbility == INVALID_HANDLE)
			SetFailState("Error: Unable to find CreateAbility signature.");

		g_oAbility = GameConfGetOffset(g_hGameConf, "oAbility");

		CloseHandle(g_hGameConf);
	}

	else
		SetFailState("Error: Unable to load gamedata file, exiting.");
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if( g_iPlayerSpawn == 1 && g_iRoundStart == 0 )
		CreateTimer(0.25, PluginStart);
	g_iRoundStart = 1;
	hasleftstartarea = false;
	// riverside2: a boomer killed after round_end (between the two halves, before
	// ready-up is on) used to leave z_versus_boomer_limit at 0 into the next half,
	// so its first spawn could not hold a boomer and go-live reported a fake
	// balance patch. Restore the config values before the half starts.
	g_bRoundLive = true;
	g_bHalfLive = false;
	if (g_bLimitsOverridden) RestoreLimits();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{ 
	if( g_iPlayerSpawn == 0 && g_iRoundStart == 1 )
		CreateTimer(0.25, PluginStart);
	g_iPlayerSpawn = 1;
}

public Action PluginStart(Handle timer)
{
	if(!InSecondHalfOfRound())
	{
		Sub_DebugPrint("Round 1");
		return Plugin_Continue;
	}

	Sub_DebugPrint("round start event");
	for(int i=1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == 3 && !IsFakeClient(i) && IsPlayerGhost(i))
		{
			CreateTimer(OnEnterGhostCheckDelay, COLD_DOWN, GetClientUserId(i) ); // delay check since team change event is before round start event
		}
	}

	return Plugin_Continue;
}

public Action:Event_RoundEnd(Handle:hEvent, const String:name[], bool:dontBroadcast)
{
	Sub_DebugPrint("round end event");
	g_bRoundLive = false;
	g_bHalfLive = false;
	if (g_bLimitsOverridden) RestoreLimits();
	ResetVariable();
}

public LeftStartAreaEvent(Handle:event, String:name[], bool:dontBroadcast)
{
	if(!SafeIsReadyPluginOn())
	{
		CreateTimer(KEEPSICHECKDELAY,KeepSIStarting,_); // delay check
		hasleftstartarea = true;
		HalfGoesLive();
	}
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if(SafeIsInReady()||IsPluginDisable()||!g_bRoundLive||!g_bHalfLive) return ;
	
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(!client || !IsClientInGame(client)) return;
	
	if(GetClientTeam(client) == TEAM_INFECTED)
	{
		new zombieclass = GetEntProp(client, Prop_Send, "m_zombieClass");
		g_bNoQuadPending = false;
		if(zombieclass == ZC_BOOMER)
		{
			if (!g_bLimitsOverridden)
			{
				g_iSavedSmokerLimit = GetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT);
				g_iSavedBoomerLimit = GetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT);
			}
			g_iDirtyUserid = 0;
			new random = GetRandomInt(1, 100)
			if (random <=Cvar3HT1SProbability)
			{
				SetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT, 1);
				SetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT, 0);
				g_bLimitsOverridden = true;
				Sub_DebugPrint("No Boomer");
			}
			else
			{
				SetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT, 0);
				SetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT, 0);
				g_bLimitsOverridden = true;
				Sub_DebugPrint("No Boomer and Smoker");
			}
		}
		else
		{
			if (g_bLimitsOverridden)
			{
				RestoreLimits();
				Sub_DebugPrint("Boomer and Smoker limit reset");
			}
			// riverside6: smoker dies last = dirty
			if (zombieclass == ZC_SMOKER && GetConVarBool(hCvarDirtyAfterSmoker) && !OtherBoomerAlive(client))
			{
				g_iSavedSmokerLimit = GetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT);
				g_iSavedBoomerLimit = GetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT);
				SetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT, 0);
				SetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT, 0);
				g_bLimitsOverridden = true;
				g_iDirtyUserid = GetClientUserId(client);
				Sub_DebugPrint("Dirty: %N is owed the boomer", client);
			}
			// riverside7: hunter dies last = no quad
			else if (zombieclass == ZC_HUNTER && GetConVarBool(hCvarNoQuadAfterHunter))
			{
				g_bNoQuadPending = true;
				Sub_DebugPrint("No quad: hunter died last");
			}
		}
	}
}

public L4D_OnEnterGhostState(client)
{
	if(g_iDirtyUserid && GetClientUserId(client) == g_iDirtyUserid)
		CreateTimer(OnEnterGhostCheckDelay, Timer_DirtyBoomer, g_iDirtyUserid); // after Spawn has picked his class
	if(g_bNoQuadPending)
		CreateTimer(OnEnterGhostCheckDelay, Timer_NoQuadCheck, GetClientUserId(client));

	if(!InSecondHalfOfRound())
	{
		Sub_DebugPrint("Round 1");
		return;
	}
	Sub_DebugPrint("%N: OnEnterGhostState %s",client,TEAM_CLASS(GetEntProp(client, Prop_Send, "m_zombieClass")));
	
	CreateTimer(OnEnterGhostCheckDelay,COLD_DOWN, GetClientUserId(client) ); // delay check since team change event is before round start event
}

// riverside6: the smoker's player becomes the wave's one boomer. The limits stay at 0 until the next SI death, so nobody
// else can be dealt a boomer meanwhile.
public Action Timer_DirtyBoomer(Handle timer, int userid)
{
	if(userid != g_iDirtyUserid) return Plugin_Continue;
	int client = GetClientOfUserId(userid);
	if(!client || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED || !IsPlayerGhost(client)) return Plugin_Continue;
	g_iDirtyUserid = 0;

	int zombieclass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if(zombieclass == ZC_BOOMER || zombieclass == ZC_TANK) return Plugin_Continue;
	if(OtherBoomerAlive(client)) return Plugin_Continue;	// riverside8: the wave already has its boomer

	// Spawn counted this life as zombieclass; count it as the boomer it is, so stock rotation stays fair
	SetEntProp(client, Prop_Send, "m_classSpawnCount", GetEntProp(client, Prop_Send, "m_classSpawnCount", 4, zombieclass) - 1, 4, zombieclass);
	SetEntProp(client, Prop_Send, "m_classSpawnCount", GetEntProp(client, Prop_Send, "m_classSpawnCount", 4, ZC_BOOMER) + 1, 4, ZC_BOOMER);
	ChangeGhostClass(client, ZC_BOOMER);
	Sub_DebugPrint("Dirty: %N changed to Boomer", client);
	return Plugin_Continue;
}

// riverside7: hunter died last. Waits until this ghost is the last of the wave, then makes sure it holds a boomer.
public Action Timer_NoQuadCheck(Handle timer, int userid)
{
	if(!g_bNoQuadPending) return Plugin_Continue;
	int client = GetClientOfUserId(userid);
	if(!client || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED || !IsPlayerGhost(client)) return Plugin_Continue;

	bool bBoomer = false;
	int iWaiting = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED) continue;
		if(IsPlayerAlive(i))
		{
			if(GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_BOOMER) bBoomer = true;
		}
		else if(!IsFakeClient(i))
			iWaiting++;	// dead and still to respawn
	}

	if(bBoomer)
	{
		g_bNoQuadPending = false;	// the wave already has its boomer
		return Plugin_Continue;
	}
	if(iWaiting > 0) return Plugin_Continue;	// a later ghost may still be dealt one

	g_bNoQuadPending = false;
	int zombieclass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if(zombieclass == ZC_TANK) return Plugin_Continue;

	SetEntProp(client, Prop_Send, "m_classSpawnCount", GetEntProp(client, Prop_Send, "m_classSpawnCount", 4, zombieclass) - 1, 4, zombieclass);
	SetEntProp(client, Prop_Send, "m_classSpawnCount", GetEntProp(client, Prop_Send, "m_classSpawnCount", 4, ZC_BOOMER) + 1, 4, ZC_BOOMER);
	ChangeGhostClass(client, ZC_BOOMER);
	Sub_DebugPrint("No quad: %N changed to Boomer", client);
	return Plugin_Continue;
}

// riverside8: a living infected boomer (ghosts included) other than except
bool OtherBoomerAlive(int except)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(i == except || !IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i)) continue;
		if(GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_BOOMER) return true;
	}
	return false;
}

// riverside6: the owed player left the infected team before his ghost, so let stock deal the boomer instead
void DirtyPlayerGone(int userid)
{
	if(!g_iDirtyUserid || userid != g_iDirtyUserid) return;
	g_iDirtyUserid = 0;
	SetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT, g_iSavedBoomerLimit);
}

public void OnClientDisconnect(int client)
{
	if(IsClientInGame(client)) DirtyPlayerGone(GetClientUserId(client));
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if(event.GetInt("team") != TEAM_INFECTED) DirtyPlayerGone(event.GetInt("userid"));
}

public Action COLD_DOWN(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if(!client || !IsClientInGame(client) || GetClientTeam(client)!=3)	return Plugin_Continue;

	if(!SafeIsReadyPluginOn() && !hasleftstartarea)
	{
		Sub_DebugPrint("Is in saferoom");
		Sub_DetermineClass(client);
		return Plugin_Continue;
	}

	if(SafeIsInReady())
	{
		Sub_DebugPrint("Is in Ready");
		Sub_DetermineClass(client);
		return Plugin_Continue;
	}

	return Plugin_Continue;
}

public void Sub_DetermineClass(int Client)
{
	if(IsPlayerGhost(Client))
	{
		decl zombieclass;
		new Hunter_Now_Line = 0, Smoker_Now_Line = 0, Boomer_Now_Line = 0, NeedChange = 0;
		for(new i=1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i) && GetClientTeam(i) == 3 && !IsFakeClient(i))
			{
				zombieclass = GetEntProp(i, Prop_Send, "m_zombieClass");
				switch(zombieclass)
				{
					case ZC_SMOKER:  
					{
						Smoker_Now_Line++;
					}
					case ZC_BOOMER:  
					{
						Boomer_Now_Line++;
					}
					case ZC_HUNTER:  
					{
						Hunter_Now_Line++;
					}			
				}
			}
		}

		zombieclass = GetEntProp(Client, Prop_Send, "m_zombieClass");
		if(Smoker_Now_Line<Smoker_Starting_Line)
		{
			if(zombieclass != ZC_SMOKER)
				NeedChange = ZC_SMOKER;
		}
		else if (Boomer_Now_Line<Boomer_Starting_Line)
		{
			if(zombieclass != ZC_BOOMER)
				NeedChange = ZC_BOOMER;
		}
		else if (Hunter_Now_Line<Hunter_Starting_Line)
		{
			if(zombieclass != ZC_HUNTER)
				NeedChange = ZC_HUNTER;
		}
		
		if(NeedChange > 0)
		{
			ChangeGhostClass(Client, NeedChange);
			Sub_DebugPrint("H: %d, S:%d, B:%d, %N has changed to %s",Hunter_Now_Line,Smoker_Now_Line,Boomer_Now_Line,Client,TEAM_CLASS(GetEntProp(Client, Prop_Send, "m_zombieClass")));
		}
	}
	return;
}

void ChangeGhostClass(int Client, int NewClass)
{
	decl WeaponIndex;
	while ((WeaponIndex = GetPlayerWeaponSlot(Client, 0)) != -1)
	{
		RemovePlayerItem(Client, WeaponIndex);
		RemoveEdict(WeaponIndex);
	}
	SDKCall(g_hSetClass, Client, NewClass);
	AcceptEntityInput(MakeCompatEntRef(GetEntProp(Client, Prop_Send, "m_customAbility")), "Kill");
	SetEntProp(Client, Prop_Send, "m_customAbility", GetEntData(SDKCall(g_hCreateAbility, Client), g_oAbility));
}

public Action:KeepSIStarting(Handle:timer,any:client)
{
	if(!InSecondHalfOfRound())
	{
		Sub_DebugPrint("Keep it");
		Hunter_Starting_Line = Smoker_Starting_Line = Boomer_Starting_Line = 0;
		new zombieclass;
		for(new i=1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i) && GetClientTeam(i) == 3 && !IsFakeClient(i) && IsPlayerGhost(i))
			{
				zombieclass = GetEntProp(i, Prop_Send, "m_zombieClass")
				switch(zombieclass)
				{
					case ZC_SMOKER:  
					{
						Smoker_Starting_Line++;
					}
					case ZC_BOOMER:  
					{
						Boomer_Starting_Line++;
					}
					case ZC_HUNTER:  
					{
						Hunter_Starting_Line++;
					}			
				}
			}
		}
		Sub_DebugPrint("H: %d, S: %d, B: %d",Hunter_Starting_Line,Smoker_Starting_Line,Boomer_Starting_Line);
		if(Smoker_Starting_Line + Boomer_Starting_Line + Hunter_Starting_Line > GetConVarInt(FindConVar("z_max_player_zombies")))	
		{
			Sub_DebugPrint("Error! infected players more than z_max_player_zombies");
			CreateTimer(KeepSITrackingCheckDelay,KeepSIStarting,_); // keep checking
		}
	}
}

public ConVarChange_hCvar3HT1SProbability(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (!StrEqual(oldValue, newValue))
	{
		Cvar3HT1SProbability = GetConVarInt(hCvar3HT1SProbability);
		LogMessage("If Boomer dies last -> %d%% 3+1, %d%% 4ht",Cvar3HT1SProbability,100-Cvar3HT1SProbability)
	}
}

public Sub_DebugPrint(const String:Message[], any:...)
{
	#if DEBUG
		decl String:DebugBuff[128];
		VFormat(DebugBuff, sizeof(DebugBuff), Message, 2);
		PrintToChatAll("%s",DebugBuff);
	#endif
}

SetConvarDefault()
{
	SetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT, CVAR_Z_VS_SMOKER_LIMIT_ORIGINAL);
	SetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT, CVAR_Z_VS_BOOMER_LIMIT_ORIGINAL);
	g_bLimitsOverridden = false;
	g_iDirtyUserid = 0;
	g_bNoQuadPending = false;
}

// riverside3: put back the values the override replaced
void RestoreLimits()
{
	SetConVarInt(HCVAR_Z_VS_SMOKER_LIMIT, g_iSavedSmokerLimit);
	SetConVarInt(HCVAR_Z_VS_BOOMER_LIMIT, g_iSavedBoomerLimit);
	g_bLimitsOverridden = false;
	g_iDirtyUserid = 0;
	g_bNoQuadPending = false;
}

bool:InSecondHalfOfRound()
{
	return bool:GameRules_GetProp("m_bInSecondHalfOfRound");
}

bool:IsPluginDisable()
{
	return PluginDisable;
}

public bool:IsPlayerGhost(client)
{
	return bool:GetEntProp(client, Prop_Send, "m_isGhost");
}

void ResetVariable()
{
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;
}
