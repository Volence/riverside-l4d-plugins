#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#define PLUGIN_VERSION "1.0"

// Stops one tank rock hurting a survivor twice (2 x 24), and logs every rock hit.
// Was l4d_rock_audit (0.1, logging only, live 2026-10-12).
//
// Cause (proven 2026-10-15, l4d/source/docs/rock-double-damage.md): in one tick the victim's
// own movement touches the point-blank rock -> BounceTouch (hit 1) -> Detonate -> UTIL_Remove
// only MARKS the rock (EFL_KILLME). Later that tick the rock's ProximityThink still runs and
// calls BounceTouch directly, past the engine's touch guards -> hit 2. Human victims only: bot
// usercmds run after the rock's think. With l4d_rock_double_fix 1 a BounceTouch on a rock
// already marked for removal is skipped.
//
// Every rock damage line records which code path dealt it (BounceTouch / ProximityThink /
// neither), whose usercmd was running, and how far the victim stood from where he was at the
// start of the tick. A rock's slot is kept until the entity is really deleted, so a double
// logs as DOUBLE (0.1 freed it at Detonate and logged the second hit as HIT n=0).
//
// Writes logs/rock_double_fix.log: ROCK (release), HIT (every rock damage on a survivor),
// DOUBLE (same rock, same survivor, second time), BLOCKED (fix skipped a second hit), END
// (rock gone, totals), SUMMARY per map. sm_rockfix_stats prints the map's counts.

#define MAX_ROCKS 16

char g_sLog[PLATFORM_MAX_PATH];
ConVar g_cvGuard;
int g_iInThink;			// rock whose ProximityThink is running, 0 if none
int g_iInTouch;			// rock whose BounceTouch is running, 0 if none
int g_iInCmd;			// client whose usercmd is running, 0 if none
float g_vTickStart[MAXPLAYERS + 1][3];	// every survivor's origin at the start of this tick
int g_iHitgroup[MAXPLAYERS + 1];		// hitgroup from the rock's TraceAttack, this tick
int g_iHitgroupTick[MAXPLAYERS + 1];

int g_iRockRef[MAX_ROCKS];
int g_iRockThrower[MAX_ROCKS];			// userid
int g_iRockCreateTick[MAX_ROCKS];
int g_iRockReleaseTick[MAX_ROCKS];		// first ProximityThink, -1 while held
int g_iRockHits[MAX_ROCKS][MAXPLAYERS + 1];
int g_iRockTouches[MAX_ROCKS];
bool g_bRockEnded[MAX_ROCKS];			// END logged; the slot stays until the entity is really gone

int g_iMapRocks, g_iMapHits, g_iMapDoubles, g_iMapBlocks;

public Plugin myinfo =
{
	name = "L4D rock double hit fix",
	author = "Malevolence",
	description = "Stops one tank rock hurting a survivor twice, and logs every rock hit",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/rock_double_fix.log");
	GameData gd = new GameData("l4d_rock_double_fix");
	if (!gd) SetFailState("missing gamedata l4d_rock_double_fix.txt");
	DynamicDetour d = DynamicDetour.FromConf(gd, "RA_BounceTouch");
	if (!d || !d.Enable(Hook_Pre, Touch_Pre) || !d.Enable(Hook_Post, Touch_Post)) SetFailState("BounceTouch detour");
	d = DynamicDetour.FromConf(gd, "RA_ProximityThink");
	if (!d || !d.Enable(Hook_Pre, Think_Pre) || !d.Enable(Hook_Post, Think_Post)) SetFailState("ProximityThink detour");
	d = DynamicDetour.FromConf(gd, "RA_Detonate");
	if (!d || !d.Enable(Hook_Pre, Detonate_Pre)) SetFailState("Detonate detour");
	delete gd;

	CreateConVar("l4d_rock_double_fix_version", PLUGIN_VERSION, "L4D rock double hit fix version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvGuard = CreateConVar("l4d_rock_double_fix", "1", "1 = skip a rock touch once the rock has detonated (stops the double hit)", FCVAR_NONE, true, 0.0, true, 1.0);
	RegAdminCmd("sm_rockfix_stats", Cmd_Stats, ADMFLAG_GENERIC, "Rock hit counts for this map");
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i)) OnClientPutInServer(i);
}

public void OnMapStart()
{
	g_iMapRocks = 0; g_iMapHits = 0; g_iMapDoubles = 0; g_iMapBlocks = 0;
	for (int s = 0; s < MAX_ROCKS; s++) g_iRockRef[s] = 0;
}

public void OnMapEnd()
{
	if (g_iMapRocks == 0) return;
	char map[64];
	GetCurrentMap(map, sizeof(map));
	LogToFileEx(g_sLog, "SUMMARY map=%s rocks=%d hits=%d doubles=%d blocked=%d", map, g_iMapRocks, g_iMapHits, g_iMapDoubles, g_iMapBlocks);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

bool IsRock(int ent)
{
	if (ent <= MaxClients || !IsValidEntity(ent)) return false;
	char cls[16];
	GetEntityClassname(ent, cls, sizeof(cls));
	return StrEqual(cls, "tank_rock");
}

int SlotOf(int rock)
{
	int ref = EntIndexToEntRef(rock);
	for (int s = 0; s < MAX_ROCKS; s++)
		if (g_iRockRef[s] == ref) return s;
	return -1;
}

public void OnEntityCreated(int ent, const char[] cls)
{
	if (!StrEqual(cls, "tank_rock")) return;
	int s = -1;
	for (int i = 0; i < MAX_ROCKS && s < 0; i++)
		if (g_iRockRef[i] == 0 || EntRefToEntIndex(g_iRockRef[i]) == INVALID_ENT_REFERENCE) s = i;
	if (s < 0) return;
	g_iRockRef[s] = EntIndexToEntRef(ent);
	g_iRockThrower[s] = 0;
	g_iRockCreateTick[s] = GetGameTickCount();
	g_iRockReleaseTick[s] = -1;
	g_iRockTouches[s] = 0;
	g_bRockEnded[s] = false;
	for (int c = 0; c <= MaxClients; c++) g_iRockHits[s][c] = 0;
}

public void OnEntityDestroyed(int ent)
{
	if (ent <= MaxClients || ent >= 2048) return;
	int s = SlotOf(ent);
	if (s < 0 || g_bRockEnded[s]) return;
	g_bRockEnded[s] = true;
	// Keep g_iRockRef: this fires when Detonate marks the rock, and a second hit can still land
	// later in the same tick (0.1 freed the slot here, so that hit logged as HIT n=0, not DOUBLE).
	// OnEntityCreated reuses the slot once the ref no longer resolves.
	if (g_iRockReleaseTick[s] >= 0)
	{
		int hits = 0, victims = 0;
		for (int c = 1; c <= MaxClients; c++)
			if (g_iRockHits[s][c] > 0) { hits += g_iRockHits[s][c]; victims++; }
		LogToFileEx(g_sLog, "END rock=%d thrower=%s life=%d ticks touches=%d hits=%d victims=%d",
			ent, ThrowerName(s), GetGameTickCount() - g_iRockReleaseTick[s], g_iRockTouches[s], hits, victims);
	}
}

char[] ThrowerName(int s)
{
	char name[MAX_NAME_LENGTH] = "?";
	int t = GetClientOfUserId(g_iRockThrower[s]);
	if (t > 0 && IsClientInGame(t)) FormatEx(name, sizeof(name), "%N%s", t, IsFakeClient(t) ? "(bot)" : "");
	return name;
}

// Start of every tick, before any usercmd: where each survivor really stands.
public void OnGameFrame()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 2)
			GetClientAbsOrigin(i, g_vTickStart[i]);
}

public Action OnPlayerRunCmd(int client, int &buttons)
{
	g_iInCmd = client;
	return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons)
{
	g_iInCmd = 0;
}

MRESReturn Think_Pre(int rock)
{
	g_iInThink = rock;
	int s = SlotOf(rock);
	if (s >= 0 && g_iRockReleaseTick[s] < 0)
	{
		// first think = the rock left the hand
		g_iRockReleaseTick[s] = GetGameTickCount();
		int owner = GetEntPropEnt(rock, Prop_Send, "m_hOwnerEntity");
		if (owner > 0 && owner <= MaxClients && IsClientInGame(owner)) g_iRockThrower[s] = GetClientUserId(owner);
		g_iMapRocks++;
		float o[3];
		GetEntPropVector(rock, Prop_Data, "m_vecAbsOrigin", o);
		LogToFileEx(g_sLog, "ROCK rock=%d thrower=%s held=%d ticks incmd=%d at %.0f %.0f %.0f",
			rock, ThrowerName(s), g_iRockReleaseTick[s] - g_iRockCreateTick[s], g_iInCmd, o[0], o[1], o[2]);
	}
	return MRES_Ignored;
}

MRESReturn Think_Post(int rock)
{
	g_iInThink = 0;
	return MRES_Ignored;
}

MRESReturn Touch_Pre(int rock, DHookParam p)
{
	// EFL_KILLME (bit 0 of m_iEFlags) is set by UTIL_Remove: the rock already detonated. Not
	// FL_KILLME in m_fFlags, which UpdateOnRemove only adds later, at the actual deletion.
	if (g_cvGuard.BoolValue && (GetEntProp(rock, Prop_Data, "m_iEFlags") & 1))
	{
		int other = p.IsNull(1) ? -1 : p.Get(1);
		char victim[MAX_NAME_LENGTH + 8] = "-";
		if (other > 0 && other <= MaxClients && IsClientInGame(other))
			FormatEx(victim, sizeof(victim), "%N%s", other, IsFakeClient(other) ? "(bot)" : "");
		int s = SlotOf(rock);
		LogToFileEx(g_sLog, "BLOCKED rock=%d thrower=%s victim=%d \"%s\" age=%d tick=%d via=%s incmd=%d",
			rock, s >= 0 ? ThrowerName(s) : "?", other, victim,
			s >= 0 && g_iRockReleaseTick[s] >= 0 ? GetGameTickCount() - g_iRockReleaseTick[s] : -1,
			GetGameTickCount(), Via(rock), g_iInCmd);
		g_iMapBlocks++;
		return MRES_Supercede;	// g_iInTouch untouched, so Touch_Post (if it runs) leaves it as it was
	}
	g_iInTouch = rock;
	int s = SlotOf(rock);
	if (s >= 0) g_iRockTouches[s]++;
	return MRES_Ignored;
}

MRESReturn Touch_Post(int rock, DHookParam p)
{
	if (g_iInTouch == rock) g_iInTouch = 0;
	return MRES_Ignored;
}

MRESReturn Detonate_Pre(int rock)
{
	int s = SlotOf(rock);
	if (s < 0 || g_iRockReleaseTick[s] < 0) return MRES_Ignored;
	LogToFileEx(g_sLog, "DETONATE rock=%d tick+%d via=%s incmd=%d killme=%d",
		rock, GetGameTickCount() - g_iRockReleaseTick[s], Via(rock), g_iInCmd, (GetEntityFlags(rock) & FL_KILLME) ? 1 : 0);
	return MRES_Ignored;
}

char[] Via(int rock)
{
	char via[16];
	if (g_iInTouch == rock && g_iInThink == rock) via = "think+touch";
	else if (g_iInTouch == rock) via = "touch";
	else if (g_iInThink == rock) via = "think";
	else via = "other";
	return via;
}

Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
	if (IsRock(inflictor))
	{
		g_iHitgroup[victim] = hitgroup;
		g_iHitgroupTick[victim] = GetGameTickCount();
	}
	return Plugin_Continue;
}

Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (GetClientTeam(victim) != 2 || !IsRock(inflictor)) return Plugin_Continue;
	int s = SlotOf(inflictor);
	int tick = GetGameTickCount();
	int n = 0, age = -1;
	if (s >= 0)
	{
		n = ++g_iRockHits[s][victim];
		age = g_iRockReleaseTick[s] >= 0 ? tick - g_iRockReleaseTick[s] : -1;
	}
	g_iMapHits++;

	float pos[3], rpos[3], vel[3];
	GetClientAbsOrigin(victim, pos);
	GetEntPropVector(inflictor, Prop_Data, "m_vecAbsOrigin", rpos);
	GetEntPropVector(victim, Prop_Data, "m_vecVelocity", vel);
	float rewound = GetVectorDistance(pos, g_vTickStart[victim]);
	int hg = g_iHitgroupTick[victim] == tick ? g_iHitgroup[victim] : -1;
	char incmd[MAX_NAME_LENGTH + 8] = "-";
	if (g_iInCmd > 0 && IsClientInGame(g_iInCmd))
		FormatEx(incmd, sizeof(incmd), "%N%s", g_iInCmd, IsFakeClient(g_iInCmd) ? "(bot)" : "");
	float lat = IsFakeClient(victim) ? 0.0 : GetClientLatency(victim, NetFlow_Outgoing) * 1000.0;

	LogToFileEx(g_sLog, "%s rock=%d n=%d thrower=%s victim=\"%N\" age=%d via=%s incmd=\"%s\" rewound=%.1f dmg=%.0f type=0x%x hg=%d hp=%d+%d onground=%d vz=%.0f dist=%.0f victim_ping=%.0f victim_at=%.0f %.0f %.0f",
		n > 1 ? "DOUBLE" : "HIT", inflictor, n, s >= 0 ? ThrowerName(s) : "?", victim, age, Via(inflictor), incmd, rewound,
		damage, damagetype, hg, GetClientHealth(victim), RoundToFloor(GetEntPropFloat(victim, Prop_Send, "m_healthBuffer")),
		(GetEntityFlags(victim) & FL_ONGROUND) ? 1 : 0, vel[2], GetVectorDistance(pos, rpos), lat, pos[0], pos[1], pos[2]);
	if (n == 2) g_iMapDoubles++;
	return Plugin_Continue;
}

Action Cmd_Stats(int client, int args)
{
	ReplyToCommand(client, "[rock fix] this map: rocks %d, hits %d, doubles %d, blocked %d (fix %d)", g_iMapRocks, g_iMapHits, g_iMapDoubles, g_iMapBlocks, g_cvGuard.IntValue);
	return Plugin_Handled;
}
