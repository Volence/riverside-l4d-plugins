#pragma semicolon 1

#include <sourcemod>
#include <left4dhooks>
#include <multicolors>
#undef REQUIRE_PLUGIN
native Is_Ready_Plugin_On();

public Plugin:myinfo =
{
	name = "L4D1 Boss Flow Announce (Back to roots edition)",
	author = "ProdigySim, Jahze, Stabby, CircleSquared, CanadaRox, Visor, L4D1 port by harry",
	version = "1.6.3-riverside1",
	description = "Announce boss flow percents!",
	url = "https://github.com/ConfoglTeam/ProMod"
};

new iWitchPercent = 0;
new iTankPercent = 0;
new Float:WitchPercentFloat = 0.0;

new Handle:hCvarPrintToEveryone;
new Handle:hCvarTankPercent;
new Handle:hCvarWitchPercent;
new bool:InSecondHalfOfRound;
new Handle:g_hVsBossBuffer;

Handle g_forwardUpdateBosses;
public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{ 
	CreateNative("GetTankPercent",Native_GetTankPercent);
	CreateNative("GetWitchPercent",Native_GetWitchPercent);
	CreateNative("GetWitchPercentFloat",Native_GetWitchPercentFloat);
	CreateNative("PrintBossPercents",Native_PrintBossPercents);
	CreateNative("SaveBossPercents",Native_SaveBossPercents);
	MarkNativeAsOptional("Is_Ready_Plugin_On"); // riverside: l4dready may be reloading or absent

	g_forwardUpdateBosses = CreateGlobalForward("OnUpdateBosses", ET_Ignore, Param_Cell, Param_Cell);
	RegPluginLibrary("l4d_boss_percent");
	return APLRes_Success;
}

public Native_GetWitchPercentFloat(Handle:plugin, numParams) {
	return _:WitchPercentFloat;
}
public Native_GetTankPercent(Handle:plugin, numParams) {
  return iTankPercent;
}
public Native_GetWitchPercent(Handle:plugin, numParams) {
    return iWitchPercent;
}

public OnPluginStart()
{
	LoadTranslations("Roto2-AZ_mod.phrases");

	g_hVsBossBuffer = FindConVar("versus_boss_buffer");

	hCvarPrintToEveryone = CreateConVar("l4d_global_percent", "0", "Display boss percentages to entire team when using commands", FCVAR_NOTIFY);
	hCvarTankPercent = CreateConVar("l4d_tank_percent", "1", "Display Tank flow percentage in chat", FCVAR_NOTIFY);
	hCvarWitchPercent = CreateConVar("l4d_witch_percent", "1", "Display Witch flow percentage in chat", FCVAR_NOTIFY);

	RegConsoleCmd("sm_boss", BossCmd);
	RegConsoleCmd("sm_tank", BossCmd);
	RegConsoleCmd("sm_witch", BossCmd);
	RegConsoleCmd("sm_t", BossCmd);

	HookEvent("round_end", PD_ev_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", LeftStartAreaEvent, EventHookMode_PostNoCopy);
}
public LeftStartAreaEvent(Handle:event, String:name[], bool:dontBroadcast)
{
	if(!(GetFeatureStatus(FeatureType_Native, "Is_Ready_Plugin_On") == FeatureStatus_Available && Is_Ready_Plugin_On()))
		for (new client = 1; client <= MaxClients; client++)
			if (IsClientConnected(client) && IsClientInGame(client)&& !IsFakeClient(client))
				PrintBossPercents(client);
}
public OnMapStart()
{
	//LogMessage("this is OnMapStart and InSecondHalfOfRound is false");
	//每一關地圖載入後都會進入OnMapStart()
	InSecondHalfOfRound = false;
}
public Native_PrintBossPercents(Handle:plugin, numParams)
{
	for (new client = 1; client <= MaxClients; client++)
		if (IsClientConnected(client) && IsClientInGame(client)&& !IsFakeClient(client))
			PrintBossPercents(client);
}
public Native_SaveBossPercents(Handle:plugin, numParams)
{
	CreateTimer(0.1, SaveBossFlows);
}

public Action:PD_ev_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	//LogMessage("this is PD_ev_RoundEnd , InSecondHalfOfRound is true");
	if(!InSecondHalfOfRound)//第一回合結束
		InSecondHalfOfRound = true;
}

Action SaveBossFlows(Handle timer)
{
	if (!InSecondHalfOfRound)
	{
		iWitchPercent = 0;
		iTankPercent = 0;
		WitchPercentFloat = 0.0;
	
		if (L4D2Direct_GetVSWitchToSpawnThisRound(0))
		{
			WitchPercentFloat = GetWitchFlow(0);
			iWitchPercent = RoundToNearest(GetWitchFlow(0)*100.0);
		}
		if (L4D2Direct_GetVSTankToSpawnThisRound(0))
		{
			iTankPercent = RoundToNearest(GetTankFlow(0)*100.0);
		}
	}
	else
	{
		if (iWitchPercent != 0)
		{
			WitchPercentFloat = GetWitchFlow(1);
			iWitchPercent = RoundToNearest(GetWitchFlow(1)*100.0);
		}
		if (iTankPercent != 0)
		{
			iTankPercent = RoundToNearest(GetTankFlow(1)*100.0);
		}
	}

	ConVar l4d_multiwitch_enabled = FindConVar("l4d_multiwitch_enabled");
	if(l4d_multiwitch_enabled != null)
	{
		if(l4d_multiwitch_enabled.IntValue == 1)
			iWitchPercent = -2;
	}

	Call_StartForward(g_forwardUpdateBosses);
	Call_PushCell(iTankPercent);
	Call_PushCell(iWitchPercent);
	Call_Finish();

	return Plugin_Continue;
}

stock PrintBossPercents(client)
{
	if(GetConVarBool(hCvarTankPercent))
	{
		if (iTankPercent)
			CPrintToChat(client, "{default}[{olive}TS{default}] {red}%T{default}:{green} %d%%","Tank",client, iTankPercent);
		else
			CPrintToChat(client, "{default}[{olive}TS{default}] {red}%T{default}:{green} None","Tank",client);
	}

	if(GetConVarBool(hCvarWitchPercent))
	{
		if (iWitchPercent > 0)
			CPrintToChat(client, "{default}[{olive}TS{default}] {red}%T{default}:{green} %d%%","Witch",client, iWitchPercent);
		else if (iWitchPercent == -2)
			CPrintToChat(client, "{default}[{olive}TS{default}] {red}%T{default}:{green} Witch Party","Witch",client);
		else
			CPrintToChat(client, "{default}[{olive}TS{default}] {red}%T{default}:{green} None","Witch",client);
			
	}
}

public Action:BossCmd(client, args)
{
	// riverside: server console / rcon has no team or chat
	if (!client)
	{
		decl String:sWitch[16];
		if (iWitchPercent > 0) Format(sWitch, sizeof(sWitch), "%d%%", iWitchPercent);
		else strcopy(sWitch, sizeof(sWitch), (iWitchPercent == -2) ? "Witch Party" : "None");
		if (iTankPercent) ReplyToCommand(client, "[TS] Tank: %d%%, Witch: %s", iTankPercent, sWitch);
		else ReplyToCommand(client, "[TS] Tank: None, Witch: %s", sWitch);
		return Plugin_Handled;
	}

	new iTeam = GetClientTeam(client);

	if (GetConVarBool(hCvarPrintToEveryone))//打這指令的只有自己看到
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (IsClientConnected(i) && IsClientInGame(i)&& !IsFakeClient(i) && GetClientTeam(i) == iTeam)
				PrintBossPercents(i);
		}
	}
	else
	{
		PrintBossPercents(client);
	}

	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Workstation patch (2026-08-25): report TRUE survivor flow.
//
// The director stores a boss flow F but actually spawns the boss when the
// survivors reach F minus versus_boss_buffer (2200 units) converted to flow
// percent -- see the @note on L4D2Direct_SetVSTankFlowPercent in
// left4dhooks.inc. Upstream printed F itself, so "!tank 40" was routinely a
// spawn at ~35-37% of real progress, and the number never matched !cur.
//
// GetTankFlow / GetWitchFlow now return F minus the buffer, i.e. the survivor
// flow at which the boss really appears. GetTankPercent / GetWitchPercent
// natives (spechud, ready-up, tankrage) inherit the corrected value. Our
// patched l4d_bossvote already ADDS the buffer when storing a voted number, so
// "!voteboss 40" stores 40+buf and this displays 40 again -- consistent.
//
// The buffer is only subtracted from a live (non-zero) flow: 0 means "no boss",
// and RewriteBossFlows / PrintBossPercents both key off 0 for that.
// ---------------------------------------------------------------------------
stock Float:GetBossBufferFlow()
{
	if (g_hVsBossBuffer == INVALID_HANDLE) return 0.0;

	new Float:fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
	if (fMaxFlow <= 0.0) return 0.0;

	return GetConVarFloat(g_hVsBossBuffer) / fMaxFlow;
}

stock Float:TrueBossFlow(Float:stored)
{
	if (stored <= 0.0) return stored;

	new Float:flow = stored - GetBossBufferFlow();
	// A stored flow inside the buffer band spawns as soon as survivors leave the
	// saferoom; clamp so it never reads as "None".
	if (flow < 0.01) flow = 0.01;
	return flow;
}

stock Float:GetTankFlow(round)
{
	return TrueBossFlow(L4D2Direct_GetVSTankFlowPercent(round));
}

stock Float:GetWitchFlow(round)
{
	return TrueBossFlow(L4D2Direct_GetVSWitchFlowPercent(round));
}