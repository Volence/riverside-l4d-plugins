#pragma semicolon 1

#include <sourcemod>
#include <left4dhooks>
#include <multicolors>

#define MAX(%0,%1) (((%0) > (%1)) ? (%0) : (%1))

new Handle:g_hVsBossBuffer;
new SurCurrent = 0;
native Is_Ready_Plugin_On();

public Plugin:myinfo =
{
    name = "L4D1 Survivor Progress",
    author = "CanadaRox, Visor, L4D1 port by harry",
    description = "Print survivor progress in flow percents ",
    version = "2.3-riverside2",
    url = "https://github.com/Attano/ProMod"
};

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("GetSurCurrent",Native_SurCurrent);
	CreateNative("GetSurCurrentFloat",Native_SurCurrentFloat);
	MarkNativeAsOptional("Is_Ready_Plugin_On"); // riverside2: l4dready may be reloading or absent
	return APLRes_Success;
}

public Native_SurCurrentFloat(Handle:plugin, numParams) {
	return _:GetBossProximity();
}
public Native_SurCurrent(Handle:plugin, numParams) {
	SurCurrent = RoundToNearest(GetMaxSurvivorCompletion() * 100.0);
	return SurCurrent;
}


public OnPluginStart()
{
	LoadTranslations("Roto2-AZ_mod.phrases");
	g_hVsBossBuffer = FindConVar("versus_boss_buffer");

	RegConsoleCmd("sm_cur", CurrentCmd);
	RegConsoleCmd("sm_current", CurrentCmd);
	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);
	HookEvent("player_left_start_area", LeftStartAreaEvent, EventHookMode_PostNoCopy);
}
public RoundStartEvent(Handle:event, const String:name[], bool:dontBroadcast)
{
	CreateTimer(5.0, SaveSurCurrent);
}

public Action:SaveSurCurrent(Handle:timer)
{
	SurCurrent = RoundToNearest(GetMaxSurvivorCompletion() * 100.0);
}

public LeftStartAreaEvent(Handle:event, String:name[], bool:dontBroadcast)
{
	if(!(GetFeatureStatus(FeatureType_Native, "Is_Ready_Plugin_On") == FeatureStatus_Available && Is_Ready_Plugin_On()))
		CPrintToChatAll("{default}[{olive}TS{default}] %t","l4d_current_survivor_progress", SurCurrent);
}

public Action:CurrentCmd(client, args)
{
	SurCurrent = RoundToNearest(GetMaxSurvivorCompletion() * 100.0);
	SurCurrent = SurCurrent>=100 ? 100 : SurCurrent;
	if (!client) // riverside: server console / rcon
	{
		ReplyToCommand(client, "[TS] Current: %d%%", SurCurrent);
		return Plugin_Handled;
	}
	CPrintToChat(client, "{default}[{olive}TS{default}] %T","l4d_current_survivor_progress",client, SurCurrent);
	
}

// ---------------------------------------------------------------------------
// Workstation patch (2026-08-25): !cur and the GetSurCurrent native now report
// the survivors' real map completion. Upstream added versus_boss_buffer to it
// ("boss proximity"), which is the director's internal comparison value, not
// progress -- it read 5-7% high right out of the saferoom and only matched the
// (also inflated) boss numbers. l4d_boss_percent now subtracts the buffer from
// the boss flows, so both sides are in true survivor flow.
//
// GetSurCurrentFloat is deliberately UNCHANGED: l4d_bossvote and
// l4d_versus_same_UnprohibitBosses compare it against the STORED boss flow to
// decide whether a boss point is already behind the team, and stored flows are
// buffered. Keep that comparison in the director's units.
// ---------------------------------------------------------------------------
stock Float:GetBossProximity()
{
	new Float:proximity = GetMaxSurvivorCompletion() + (GetConVarFloat(g_hVsBossBuffer) / L4D2Direct_GetMapMaxFlowDistance());
	return proximity;
}


float GetMaxSurvivorCompletion()
{
	float flow = 0.0, tmp_flow = 0.0;
	Address pNavArea;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
			pNavArea = L4D_GetLastKnownArea(i);
			if (pNavArea != Address_Null) {
				tmp_flow = L4D2Direct_GetTerrorNavAreaFlow(pNavArea);
				flow = (flow > tmp_flow) ? flow : tmp_flow;
			}
		}
	}

	return (flow / L4D2Direct_GetMapMaxFlowDistance());
}