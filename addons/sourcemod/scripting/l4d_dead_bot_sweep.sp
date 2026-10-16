#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.1-riverside1"

/**
 * l4d_dead_bot_sweep - dead infected bots must not hold a slot the tank needs.
 *
 * Match 673 (2026-10-13, Death Toll 4, half 1) got no tank. During a pause an
 * infected player reconnected; the game put a Hunter bot in the slot and the
 * bot died at once. stew came back to Infected, so the team held 4 humans
 * plus that dead bot. The engine removes a dead bot when its death anim ends
 * ("kickid %d death anim finished"), but it counts game time and the pause
 * froze it. The tank came 7 s after the unpause, the stock join logic found
 * the infected team full and put the tank bot on Spectator, and
 * BossZombiePlayerBot::OnTeamChanged kicked it ("infected team is full").
 * The dead Hunter went one second later.
 *
 * The versus flow tank spawns through ZombieManager::SpawnTank(TerrorNavArea*),
 * which left4dhooks does not detour (L4D_OnSpawnTank is the Vector overload
 * only), so there is no "just before the tank" hook to clean up in. Instead:
 *
 *   1. When a human joins the infected team, every dead infected bot on it is
 *      kicked. That is the moment the team goes over its size.
 *   2. Once a second, a dead infected bot that has been dead for more than
 *      l4d_dead_bot_sweep_secs seconds of REAL time is kicked. Unpaused, the
 *      engine removes them about 8 s after death, so this only ever catches a
 *      bot a pause kept alive, within a second of the unpause.
 *
 * A dead bot tank is never touched (death anim plus l4d_tank_reconnect).
 * Every kick is logged to logs/dead_bot_sweep.log.
 */

#define TEAM_INFECTED 3
#define ZC_TANK 5

ConVar g_cvEnabled;
ConVar g_cvSecs;
char g_sLog[PLATFORM_MAX_PATH];
float g_fDiedAt[MAXPLAYERS + 1];   // engine time a fake infected died, 0 = alive / not tracked

public Plugin myinfo =
{
	name = "L4D Dead Bot Sweep",
	author = "Malevolence",
	description = "Kicks dead infected bots that would block the tank from joining",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d_dead_bot_sweep", "1", "Kick dead infected bots that hold a slot (0 = off)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvSecs = CreateConVar("l4d_dead_bot_sweep_secs", "10.0", "Real seconds a dead infected bot may linger before the sweep kicks it", FCVAR_NONE, true, 1.0);
	CreateConVar("l4d_dead_bot_sweep_version", PLUGIN_VERSION, "l4d_dead_bot_sweep version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/dead_bot_sweep.log");

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_team", Event_PlayerTeam);
	CreateTimer(1.0, Timer_Sweep, _, TIMER_REPEAT);
}

public void OnClientPutInServer(int client)
{
	g_fDiedAt[client] = 0.0;
}

public void OnClientDisconnect(int client)
{
	g_fDiedAt[client] = 0.0;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0)
		g_fDiedAt[client] = 0.0;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && IsClientInGame(client) && IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED)
		g_fDiedAt[client] = GetEngineTime();
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetInt("team") != TEAM_INFECTED || event.GetBool("isbot"))
		return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || IsFakeClient(client))
		return;
	// player_team fires before the move lands; look one frame later.
	RequestFrame(Frame_HumanJoined, event.GetInt("userid"));
}

public void Frame_HumanJoined(int userid)
{
	int human = GetClientOfUserId(userid);
	if (human <= 0 || !IsClientInGame(human) || GetClientTeam(human) != TEAM_INFECTED)
		return;
	char why[96];
	Format(why, sizeof(why), "human \"%N\" joined infected", human);
	Sweep(0.0, why);
}

public Action Timer_Sweep(Handle timer)
{
	Sweep(g_cvSecs.FloatValue, "dead too long");
	return Plugin_Continue;
}

// Kicks every dead, non-tank infected bot that has been dead at least minSecs
// (engine time). minSecs 0 kicks them all, seen dying or not (logged as dead -1.0).
void Sweep(float minSecs, const char[] why)
{
	if (!g_cvEnabled.BoolValue)
		return;
	float now = GetEngineTime();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsDeadInfectedBot(i))
			continue;
		// The timer only acts on deaths it saw: an unstamped dead bot may be one
		// the game created this frame and has not spawned yet.
		if (minSecs > 0.0 && g_fDiedAt[i] == 0.0)
			continue;
		float dead = g_fDiedAt[i] > 0.0 ? now - g_fDiedAt[i] : -1.0;
		if (dead < minSecs)
			continue;
		char map[64];
		GetCurrentMap(map, sizeof(map));
		LogToFileEx(g_sLog, "kick \"%N\" (userid %d) on %s: %s, dead %.1f s, infected team %d",
			i, GetClientUserId(i), map, why, dead, GetTeamClientCount(TEAM_INFECTED));
		g_fDiedAt[i] = 0.0;
		KickClient(i, "dead bot sweep");
	}
}

bool IsDeadInfectedBot(int client)
{
	return IsClientInGame(client) && IsFakeClient(client) && !IsClientSourceTV(client)
		&& GetClientTeam(client) == TEAM_INFECTED && !IsPlayerAlive(client)
		&& GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_TANK
		&& !IsClientInKickQueue(client);
}
