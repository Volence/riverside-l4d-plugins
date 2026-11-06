#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "0.2-riverside1"

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
 * Three sweeps:
 *
 *   1. When a human joins the infected team, every dead infected bot on it is
 *      kicked. That is the moment the team goes over its size.
 *   2. Once a second, a dead infected bot that has been dead for more than
 *      l4d_dead_bot_sweep_secs seconds of REAL time is kicked. Unpaused, the
 *      engine removes them about 8 s after death, so this only ever catches a
 *      bot a pause kept alive, within a second of the unpause.
 *   3. (0.2) Just before a tank spawns (L4D_OnSpawnTank). left4dhooks 1.175
 *      detours the versus flow tank's ZombieManager::SpawnTank(TerrorNavArea*)
 *      on L4D1 Linux; earlier versions only had the Vector overload, which is
 *      why 1 and 2 exist. Dead bots are kicked with KickClient, which lands a
 *      frame later, so when they fill the infected team that attempt is refused:
 *      the director tries again on the next tick (rig 2026-11-06: refused at
 *      74.30, spawned at 74.31) and the slot is free by then. Only the
 *      director's own path is refused (its pre-forward position is a null
 *      vector); a plugin's L4D2_SpawnTank (Vector overload, gauntlet_finale)
 *      does not retry, so it only gets the kick. Refusals stop after
 *      REFUSE_MAX_SECS, so a kick that never lands cannot hold the tank.
 *
 * 0.2 also fixes Sweep(0.0): 0.1 skipped a dead bot whose death it never saw
 * (dead -1.0 < 0.0), so sweep 1 missed a bot that was dead from its creation.
 *
 * A dead bot tank is never touched (death anim plus l4d_tank_reconnect).
 * Every kick is logged to logs/dead_bot_sweep.log.
 */

#define TEAM_INFECTED 3
#define ZC_TANK 5
#define REFUSE_MAX_SECS 2.0

ConVar g_cvEnabled;
ConVar g_cvSecs;
char g_sLog[PLATFORM_MAX_PATH];
float g_fDiedAt[MAXPLAYERS + 1];   // engine time a fake infected died, 0 = alive / not tracked
float g_fRefuseSince;              // game time this run of tank refusals began, 0 = none
ConVar g_cvMaxZombies;

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
	g_cvMaxZombies = FindConVar("z_max_player_zombies");

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

public void OnMapStart()
{
	g_fRefuseSince = 0.0;
}

public Action L4D_OnSpawnTank(const float vecPos[3], const float vecAng[3])
{
	if (!g_cvEnabled.BoolValue)
		return Plugin_Continue;
	Sweep(0.0, "tank spawning");
	int pending = 0;  // kicked just now or earlier, still on the team until the kick lands
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsClientInKickQueue(i) && IsFakeClient(i) && GetClientTeam(i) == TEAM_INFECTED)
			pending++;
	}
	bool director = vecPos[0] == 0.0 && vecPos[1] == 0.0 && vecPos[2] == 0.0;
	if (pending == 0 || !director || GetTeamClientCount(TEAM_INFECTED) < g_cvMaxZombies.IntValue)
	{
		g_fRefuseSince = 0.0;
		return Plugin_Continue;
	}
	float now = GetGameTime();
	if (g_fRefuseSince == 0.0)
	{
		g_fRefuseSince = now;
		LogToFileEx(g_sLog, "tank spawn refused once: infected team %d/%d holds %d dead bot(s) being kicked; the director retries next tick",
			GetTeamClientCount(TEAM_INFECTED), g_cvMaxZombies.IntValue, pending);
	}
	else if (now - g_fRefuseSince > REFUSE_MAX_SECS)
	{
		LogToFileEx(g_sLog, "tank spawn let through after %.1f s of refusals (dead bots still on the team)", now - g_fRefuseSince);
		g_fRefuseSince = 0.0;
		return Plugin_Continue;
	}
	return Plugin_Handled;
}

public Action Timer_Sweep(Handle timer)
{
	Sweep(g_cvSecs.FloatValue, "dead too long");
	return Plugin_Continue;
}

// Kicks every dead, non-tank infected bot that has been dead at least minSecs
// (engine time). minSecs 0 kicks them all, seen dying or not (logged as dead -1.0).
// Returns how many it kicked.
int Sweep(float minSecs, const char[] why)
{
	if (!g_cvEnabled.BoolValue)
		return 0;
	int kicked = 0;
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
		if (minSecs > 0.0 && dead < minSecs)
			continue;
		char map[64];
		GetCurrentMap(map, sizeof(map));
		LogToFileEx(g_sLog, "kick \"%N\" (userid %d) on %s: %s, dead %.1f s, infected team %d",
			i, GetClientUserId(i), map, why, dead, GetTeamClientCount(TEAM_INFECTED));
		g_fDiedAt[i] = 0.0;
		KickClient(i, "dead bot sweep");
		kicked++;
	}
	return kicked;
}

bool IsDeadInfectedBot(int client)
{
	return IsClientInGame(client) && IsFakeClient(client) && !IsClientSourceTV(client)
		&& GetClientTeam(client) == TEAM_INFECTED && !IsPlayerAlive(client)
		&& GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_TANK
		&& !IsClientInKickQueue(client);
}
