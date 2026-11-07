#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "0.2.1-riverside1"

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
 *
 * 0.2 (PUG 1060, farm02): the vomit stream calls OnVomitedUpon on the same
 * victim several times in a row (7 calls in 0.08 s there). The engine only
 * spawns on the first, but 0.1 re-found the same 15 commons each time (still
 * alive, removal pending), and each post-forward raised the pending mob by
 * another 15: one boom became a mob of 117. Now the plugin acts only when the
 * engine itself will count (the victim's m_itTimer has run out, the same test
 * CTerrorPlayer::OnVomitedUpon makes before NextBotManager::
 * OnSurvivorVomitedUpon), and a common already slated for removal is never
 * counted or added again (the BOOMHORDE line reports any still pending).
 *
 * 0.2.1: "already removed" is the engine's EFL_KILLME flag, not a plugin
 * array. RemoveEntity runs UpdateOnRemove at once, so OnEntityDestroyed fires
 * immediately while the common stays in the entity list until the frame ends;
 * 0.2's array was cleared there, and a boomer splash covering several
 * survivors in one frame replaced the same commons once per victim (rig: two
 * victims, 30 replaced twice, pending 60).
 *
 * Also 0.2: NavAreaTravelDistance only finds the goal when it lies over a nav
 * area, so a victim on a car roof, ledge or prop (Double at z 176 on farm02)
 * made every common "no path" and nearly all of them were replaced. When the
 * victim is not over nav, the walk is measured to the centre of the victim's
 * last known nav area instead; if that area is not near the victim either,
 * nothing is replaced.
 */

#define TEAM_SURVIVOR 2
#define MIN_AGE 3.0
#define EFL_KILLME 1   // UTIL_Remove has run; the entity goes away at the end of the frame
#define GOAL_SNAP 400.0   // furthest the last known area centre may be from the victim

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
	g_iRemoved = 0;
	if (!g_cvEnabled.BoolValue || victim < 1 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != TEAM_SURVIVOR)
		return Plugin_Continue;

	float now = GetGameTime();
	// the engine only counts and spawns while the victim is not yet "it"; the vomit
	// stream calls this several times per boom and every later call must do nothing
	float itEnd = GetEntPropFloat(victim, Prop_Send, "m_itTimer", 1);
	if (itEnd > 0.0 && !(now > itEnd))
		return Plugin_Continue;

	float range = g_cvNoticeRange.FloatValue;
	float maxTravel = g_cvTravel.FloatValue;
	float v[3], p[3];
	GetClientAbsOrigin(victim, v);
	float goal[3];
	if (!VictimNavGoal(victim, v, goal))
		return Plugin_Continue;

	int inRange, noPath, far, stale;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "infected")) != -1)
	{
		if (GetEntProp(ent, Prop_Data, "m_iHealth") <= 0)
			continue;
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
		if (GetVectorDistance(v, p) >= range)
			continue;
		if (GetEntProp(ent, Prop_Data, "m_iEFlags") & EFL_KILLME)
		{
			stale++;   // removed by an earlier vomit and still alive: never count it twice
			continue;
		}
		inRange++;
		if (ent < sizeof(g_fBorn) && now - g_fBorn[ent] < MIN_AGE)
			continue;
		if (NearOrSeenBySurvivor(ent, p))
			continue;
		float travel = L4D2_NavAreaTravelDistance(p, goal, false);
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
		LogToGame("(BOOMHORDE) %N vomited: %d commons in range, replacing %d (%d no path, %d over %.0f walk, %d still pending removal)",
		          victim, inRange, g_iRemoved, noPath, far, maxTravel, stale);
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

// another plugin blocked the vomit: our post-forward will not run, drop the count
public void L4D_OnVomitedUpon_PostHandled(int victim, int attacker, bool boomerExplosion)
{
	g_iRemoved = 0;
}

// NavAreaTravelDistance only reaches a goal that lies over a nav area; off the mesh
// (car roof, ledge, prop) use the centre of the victim's last known area. False when
// that area is missing or too far away to stand in for the victim.
bool VictimNavGoal(int victim, const float v[3], float goal[3])
{
	goal = v;
	float probe[3];
	probe = v;
	if (L4D2Direct_GetTerrorNavArea(probe) != Address_Null)
		return true;
	Address area = L4D_GetLastKnownArea(victim);
	if (area == Address_Null)
		return false;
	L4D_GetNavAreaCenter(area, goal);
	return GetVectorDistance(v, goal) <= GOAL_SNAP;
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
