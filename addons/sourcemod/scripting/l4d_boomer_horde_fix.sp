#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "0.1-riverside1"

/**
 * l4d_boomer_horde_fix - every boom brings a full horde that actually arrives.
 *
 * Owner report 2026-11-06 (Grma, PUG 1004 and 1037 on Passifice): some booms
 * bring almost no commons, others feel like all 30. Cause, from the source
 * rebuild (NextBotManager::OnSurvivorVomitedUpon): when a survivor is vomited
 * on, every living common within z_notice_it_range (1500, straight line,
 * through floors) is told to attack and counted, and only
 * z_mob_spawn_max_size (28) minus that count is spawned new. With 28 in range
 * nothing new spawns ("(MOB) 30 wanderers grabbed", no "will make" line).
 * Commons a floor away or stuck on a ledge count fully but take 20-40 s to
 * arrive or never do. Dallas logs: zero-new booms on 59% of NM4, 49% of DA2,
 * 48% of bedlam. Rig on bedlam: mid-map about half the grabbed commons
 * arrived within 40 s.
 *
 * Fix: just before the game counts (left4dhooks pre-forward on
 * CTerrorPlayer::OnVomitedUpon), remove each in-range common that cannot get
 * there soon: nav travel distance to the victim over
 * l4d_boomer_horde_fix_travel, or no path at all. Removal only happens at the
 * end of the frame, so the game still counts those commons; the post-forward
 * then raises the pending mob by the number removed through
 * ZombieManager::SpawnITMob, so the fresh mob is 28 minus the commons that
 * really are on their way. A common is never removed if a
 * survivor can see it, if it is within l4d_boomer_horde_fix_guard of any
 * survivor, or if it is under 3 s old (so a boom that covers several
 * survivors does not throw away the mob it just spawned). Commons out of
 * range are left to the engine's own cull, which already removes unseen
 * calm commons while a mob waits for room under z_common_limit.
 *
 * Each vomit with a removal logs a "(BOOMHORDE)" line to the game log, next
 * to the engine's "(MOB)" lines.
 */

#define TEAM_SURVIVOR 2
#define MIN_AGE 3.0

ConVar g_cvEnabled;
ConVar g_cvTravel;
ConVar g_cvGuard;
ConVar g_cvNoticeRange;
float g_fBorn[2049];   // game time each common was created
int g_iRemoved;        // commons removed by the pre-forward of the vomit being handled
Handle g_hSpawnITMob;

public Plugin myinfo =
{
	name = "L4D Boomer Horde Fix",
	author = "Malevolence",
	description = "Boomer hordes replace far or stuck commons with fresh ones so the full horde arrives",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d_boomer_horde_fix", "1", "Replace far or stuck commons when a survivor is vomited on (0 = off)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvTravel = CreateConVar("l4d_boomer_horde_fix_travel", "1200.0", "A common with a longer walk than this to the victim (or no path) is replaced", FCVAR_NONE, true, 0.0);
	g_cvGuard = CreateConVar("l4d_boomer_horde_fix_guard", "500.0", "Never replace a common this close to any survivor", FCVAR_NONE, true, 0.0);
	CreateConVar("l4d_boomer_horde_fix_version", PLUGIN_VERSION, "l4d_boomer_horde_fix version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvNoticeRange = FindConVar("z_notice_it_range");

	GameData gd = new GameData("left4dhooks.l4d1");
	if (gd == null)
		SetFailState("left4dhooks.l4d1 gamedata missing");
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "ZombieManager::SpawnITMob"))
		SetFailState("ZombieManager::SpawnITMob signature not found");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hSpawnITMob = EndPrepSDKCall();
	delete gd;
	if (g_hSpawnITMob == null)
		SetFailState("ZombieManager::SpawnITMob call could not be prepared");
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity > 0 && entity < sizeof(g_fBorn) && StrEqual(classname, "infected"))
		g_fBorn[entity] = GetGameTime();
}

public Action L4D_OnVomitedUpon(int victim, int &attacker, bool &boomerExplosion)
{
	if (!g_cvEnabled.BoolValue || victim < 1 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != TEAM_SURVIVOR)
		return Plugin_Continue;

	g_iRemoved = 0;
	float range = g_cvNoticeRange.FloatValue;
	float maxTravel = g_cvTravel.FloatValue;
	float now = GetGameTime();
	float v[3], p[3];
	GetClientAbsOrigin(victim, v);

	int inRange, noPath, far;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "infected")) != -1)
	{
		if (GetEntProp(ent, Prop_Data, "m_iHealth") <= 0)
			continue;
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
		if (GetVectorDistance(v, p) >= range)
			continue;
		inRange++;
		if (ent < sizeof(g_fBorn) && now - g_fBorn[ent] < MIN_AGE)
			continue;
		if (NearOrSeenBySurvivor(ent, p))
			continue;
		float travel = L4D2_NavAreaTravelDistance(p, v, false);
		if (travel >= 0.0 && travel <= maxTravel)
			continue;
		if (travel < 0.0)
			noPath++;
		else
			far++;
		RemoveEntity(ent);
	}

	g_iRemoved = noPath + far;
	if (g_iRemoved > 0)
		LogToGame("(BOOMHORDE) %N vomited: %d commons in range, replacing %d (%d no path, %d over %.0f walk)",
		          victim, inRange, g_iRemoved, noPath, far, maxTravel);
	return Plugin_Continue;
}

public void L4D_OnVomitedUpon_Post(int victim, int attacker, bool boomerExplosion)
{
	if (g_iRemoved <= 0)
		return;
	// the game has spawned 28 minus everything it counted, removed commons included; add those back
	int want = L4D2Direct_GetPendingMobCount() + g_iRemoved;
	g_iRemoved = 0;
	Address zm = L4D_GetPointer(POINTER_ZOMBIEMANAGER);
	if (zm != Address_Null)
		SDKCall(g_hSpawnITMob, zm, want);
}

bool NearOrSeenBySurvivor(int common, const float pos[3])
{
	float guard = g_cvGuard.FloatValue;
	float eye[3], s[3], head[3];
	head = pos;
	head[2] += 56.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;
		GetClientAbsOrigin(i, s);
		if (GetVectorDistance(s, pos) < guard)
			return true;
		GetClientEyePosition(i, eye);
		Handle tr = TR_TraceRayFilterEx(eye, head, MASK_VISIBLE, RayType_EndPoint, Filter_WorldOnly, common);
		bool seen = !TR_DidHit(tr) || TR_GetEntityIndex(tr) == common;
		delete tr;
		if (seen)
			return true;
	}
	return false;
}

public bool Filter_WorldOnly(int entity, int contentsMask, any common)
{
	if (entity == common)
		return true;
	if (entity >= 1 && entity <= MaxClients)
		return false;
	char cls[16];
	GetEntityClassname(entity, cls, sizeof(cls));
	return !StrEqual(cls, "infected");
}
