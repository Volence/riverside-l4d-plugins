#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0"

/**
 * l4d_pillar_rubble_cleanup - the rubble from a tank-broken concrete pillar
 * goes away once the tank is dead.
 *
 * Match 7a31e950 (2026-10-29, No Mercy 2, half 2): the first tank spent ~40 s
 * in the pillar room before the witch and broke pillars there. The survivors
 * came through after it had passed and died, got caught on the rubble and
 * the witch got them.
 *
 * models/props_interiors/concretepillar01.mdl is "only_breakable_by" tank
 * (game_interactions). Its .phy break list spawns five SERVER-side gibs:
 *   concretepiller01_dm01      the stump with rebar, motiondisabled
 *   concretepiller01_dm01_1..4 loose chunks, debris 0 (they collide with
 *                              players), fadetime 0 (they never fade)
 * so the chunks stay solid on the floor for the rest of the round. The same
 * pillar is placed on No Mercy 2 (48 of them) and Milltown.
 *
 * Once no tank is alive (checked l4d_pillar_rubble_delay seconds after a
 * tank's death, so a pass to the next player does not count), every loose
 * chunk is deleted. The stump is kept so the room still shows the fight.
 * Each cleanup is logged to logs/pillar_rubble.log.
 */

#define TEAM_INFECTED 3
#define ZC_TANK 5
#define CHUNK_MODEL "models/props_interiors/concretepiller01_dm01_"

ConVar g_cvEnabled;
ConVar g_cvDelay;
char g_sLog[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
	name = "L4D Pillar Rubble Cleanup",
	author = "Malevolence",
	description = "Deletes the loose chunks of tank-broken concrete pillars once no tank is alive",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d_pillar_rubble_cleanup", "1", "Delete loose pillar chunks once no tank is alive (0 = off)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDelay = CreateConVar("l4d_pillar_rubble_delay", "2.0", "Seconds after a tank's death before checking that no tank is left", FCVAR_NONE, true, 0.1);
	CreateConVar("l4d_pillar_rubble_cleanup_version", PLUGIN_VERSION, "l4d_pillar_rubble_cleanup version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/pillar_rubble.log");

	HookEvent("player_death", Event_PlayerDeath);
	RegAdminCmd("sm_pillar_rubble_count", Cmd_Count, ADMFLAG_GENERIC, "Print how many loose pillar chunks exist");
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue)
		return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED)
		return;
	if (GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_TANK)
		return;
	CreateTimer(g_cvDelay.FloatValue, Timer_AfterTankDeath, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AfterTankDeath(Handle timer)
{
	if (!g_cvEnabled.BoolValue || IsTankAlive())
		return Plugin_Stop;

	int removed = RemoveChunks(true);
	if (removed > 0)
	{
		char map[64];
		GetCurrentMap(map, sizeof(map));
		LogToFileEx(g_sLog, "CLEANUP map=%s removed=%d", map, removed);
	}
	return Plugin_Stop;
}

public Action Cmd_Count(int client, int args)
{
	ReplyToCommand(client, "[pillar_rubble] %d loose pillar chunks, tank alive: %s", RemoveChunks(false), IsTankAlive() ? "yes" : "no");
	return Plugin_Handled;
}

bool IsTankAlive()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i)
			&& GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
			return true;
	}
	return false;
}

// Counts the loose chunks, deleting them when remove is true. Break gibs are
// prop_physics (prop_physics_multiplayer is matched too, to be safe).
int RemoveChunks(bool remove)
{
	int count = 0;
	char cls[64], model[PLATFORM_MAX_PATH];
	int maxEnts = GetMaxEntities();
	for (int ent = MaxClients + 1; ent < maxEnts; ent++)
	{
		if (!IsValidEntity(ent))
			continue;
		GetEntityClassname(ent, cls, sizeof(cls));
		if (strncmp(cls, "prop_physics", 12) != 0)
			continue;
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		// The .phy names the pieces with a backslash (props_interiors\...)
		ReplaceString(model, sizeof(model), "\\", "/");
		if (StrContains(model, CHUNK_MODEL, false) != 0)
			continue;
		count++;
		if (remove)
			RemoveEntity(ent);
	}
	return count;
}
