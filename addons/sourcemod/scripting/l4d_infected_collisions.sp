#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <sdktools>
#include <@Forgetest/gamedatawrapper>

// riverside1 (2026-10-05): fork of upstream 1.0-2026/10/6 (Forgetest, Rotoblin-AZMod 48c54bc).
// Adds a cvar per mover so commons and the witch can be switched separately; the
// owner wants commons to walk through a pinned survivor while the witch still
// collides with them. The mover is the trace filter's pass entity
// (CTraceFilterSimple::m_pPassEnt at this+4, read out of the L4D1 server.so constructor).
// Also drops the unused <collisionhook> include.
//
// riverside2 (2026-10-16, server.so audit, l4d-source docs/annotated/collision/): the pass
// entity is NOT the mover. ZombieBotLocomotion::DetectCollision (0x7eefa0) builds the filter
// with an entity the zombie is ignoring for a moment, NULL otherwise, so the mover read as -1,
// the common setting decided for everyone, and with the defaults (common 1, witch 0) the
// witch still walked through pinned survivors. The mover is now taken from DetectCollision
// itself: a pre/post detour notes whether the locomotion moving is a witch's (her locomotor
// pointer at witch+0xD8C, Witch::CreateComponents). The detour is only on while a witch
// exists and the two settings differ, so commons pay nothing extra otherwise.

public Plugin myinfo =
{
	name = "[L4D1/L4D2] ZombieBotCollisionTraceFilter ignore pinned survivor",
	author = "Forgetest, Malevolence",
	description = "Common infected and witch can phase through pulled or pounced survivors",
	version = "1.0-2026/10/6-riverside2",
	url = "https://github.com/jensewe"
}

#define MAXENTITIES 2048

Handle g_call_GetRefEHandle;
int m_pounceAttacker,
	m_tongueOwner;

ConVar g_hCvarCommon, g_hCvarWitch;
bool g_bCvarCommon, g_bCvarWitch;
bool g_bIsWitch[MAXENTITIES + 1];

#define OFFSET_WITCH_LOCO 0xD8C		// Witch::m_locomotor (Witch::GetLocomotionInterface, ELF 0x7e61da)
DynamicDetour g_hDetectCollision;
bool g_bDetourOn;
Address g_aWitchLoco[MAXENTITIES + 1];	// each witch's ZombieBotLocomotion*, Address_Null if not read yet
#define MAX_WITCH_LOCOS 16
Address g_aLocoList[MAX_WITCH_LOCOS];	// the same pointers packed, scanned on every trace
int g_iLocoCount;
int g_iWitches;
int g_iDepth;							// DetectCollision recursion depth
bool g_bWitchMoving[8];					// per depth: the locomotion tracing is a witch's
int g_iStatTraces, g_iStatWitchTraces;	// DetectCollision calls seen while the detour is on
int g_iStatPhase[2], g_iStatCollide[2];	// pinned-survivor decisions, [0] common, [1] witch

public void OnPluginStart()
{
	GameDataWrapper gd = new GameDataWrapper("l4d_infected_collisions");

	SDKCallParamsWrapper params[] = {
		{SDKType_PlainOldData, SDKPass_Plain},
	};
	g_call_GetRefEHandle = gd.CreateSDKCallOrFail(SDKCall_Raw, SDKConf_Virtual, "IHandleEntity::GetRefEHandle", _, 0, true, params[0]);

	delete gd.CreateDetourOrFail("l4d_infected_collisions::ZombieBotCollisionTraceFilter::ShouldHitEntity", DTR_ShouldHitEntity);
	g_hDetectCollision = DynamicDetour.FromConf(gd, "l4d_infected_collisions::ZombieBotLocomotion::DetectCollision");
	if (!g_hDetectCollision)
		SetFailState("Missing detour setup \"l4d_infected_collisions::ZombieBotLocomotion::DetectCollision\"");
	delete gd;

	m_pounceAttacker = FindSendPropInfo("CTerrorPlayer", "m_pounceAttacker");
	m_tongueOwner = FindSendPropInfo("CTerrorPlayer", "m_tongueOwner");

	g_hCvarCommon = CreateConVar("l4d_infected_collisions_common", "1", "If 1, common infected walk through a survivor who is pulled, choked or pounced", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarWitch = CreateConVar("l4d_infected_collisions_witch", "0", "If 1, the witch walks through a survivor who is pulled, choked or pounced", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarCommon.AddChangeHook(ConVarChanged);
	g_hCvarWitch.AddChangeHook(ConVarChanged);
	GetCvars();

	AutoExecConfig(true, "l4d_infected_collisions");
	RegAdminCmd("sm_infcoll_stats", Cmd_Stats, ADMFLAG_ROOT, "Pinned-survivor collision decisions since load");

	// late load: mark witches that already exist
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "witch")) != -1)
	{
		if (entity <= MAXENTITIES)
		{
			g_bIsWitch[entity] = true;
			g_iWitches++;
			ReadWitchLoco(EntIndexToEntRef(entity));
		}
	}
	UpdateDetour();
}

// The detour is needed only when the two settings differ and a witch is around.
void UpdateDetour()
{
	bool want = g_iWitches > 0 && g_bCvarCommon != g_bCvarWitch;
	if (want == g_bDetourOn) return;
	if (want)
	{
		if (!g_hDetectCollision.Enable(Hook_Pre, DTR_DetectCollision_Pre) || !g_hDetectCollision.Enable(Hook_Post, DTR_DetectCollision_Post))
			SetFailState("Failed to detour ZombieBotLocomotion::DetectCollision");
	}
	else
	{
		g_hDetectCollision.Disable(Hook_Pre, DTR_DetectCollision_Pre);
		g_hDetectCollision.Disable(Hook_Post, DTR_DetectCollision_Post);
	}
	g_bDetourOn = want;
	g_iDepth = 0;
}

// Witch::CreateComponents runs in Spawn, after OnEntityCreated: read the pointer a frame later.
void ReadWitchLoco(int ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity == INVALID_ENT_REFERENCE || entity > MAXENTITIES || !g_bIsWitch[entity])
		return;
	Address addr = GetEntityAddress(entity);
	g_aWitchLoco[entity] = addr == Address_Null ? Address_Null
		: view_as<Address>(LoadFromAddress(addr + view_as<Address>(OFFSET_WITCH_LOCO), NumberType_Int32));
	RebuildLocoList();
}

// DetectCollision runs for every zombie movement step; keep the per-call check to a few compares
void RebuildLocoList()
{
	g_iLocoCount = 0;
	for (int i = MaxClients + 1; i <= MAXENTITIES && g_iLocoCount < MAX_WITCH_LOCOS; i++)
		if (g_bIsWitch[i] && g_aWitchLoco[i] != Address_Null) g_aLocoList[g_iLocoCount++] = g_aWitchLoco[i];
}

bool IsWitchLoco(Address loco)
{
	for (int i = 0; i < g_iLocoCount; i++)
		if (g_aLocoList[i] == loco) return true;
	return false;
}

MRESReturn DTR_DetectCollision_Pre(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	bool witch = IsWitchLoco(pThis);
	if (g_iDepth < sizeof(g_bWitchMoving))
		g_bWitchMoving[g_iDepth] = witch;
	g_iStatTraces++;
	if (witch) g_iStatWitchTraces++;
	g_iDepth++;
	return MRES_Ignored;
}

MRESReturn DTR_DetectCollision_Post(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (g_iDepth > 0) g_iDepth--;
	return MRES_Ignored;
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_bCvarCommon = g_hCvarCommon.BoolValue;
	g_bCvarWitch = g_hCvarWitch.BoolValue;
	if (g_hDetectCollision) UpdateDetour();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity < 0 || entity > MAXENTITIES)
		return;

	g_bIsWitch[entity] = (classname[0] == 'w' && strcmp(classname, "witch") == 0);
	g_aWitchLoco[entity] = Address_Null;
	if (g_bIsWitch[entity])
	{
		g_iWitches++;
		RequestFrame(ReadWitchLoco, EntIndexToEntRef(entity));
		UpdateDetour();
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity >= 0 && entity <= MAXENTITIES)
	{
		if (g_bIsWitch[entity] && g_iWitches > 0)
		{
			g_iWitches--;
			g_bIsWitch[entity] = false;
			g_aWitchLoco[entity] = Address_Null;
			RebuildLocoList();
			UpdateDetour();
		}
		g_bIsWitch[entity] = false;
	}
}

public void OnMapStart()
{
	g_iWitches = 0;
	g_iDepth = 0;
	for (int i = 0; i <= MAXENTITIES; i++) { g_bIsWitch[i] = false; g_aWitchLoco[i] = Address_Null; }
	g_iLocoCount = 0;
	UpdateDetour();
}

MRESReturn DTR_ShouldHitEntity(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (!g_bCvarCommon && !g_bCvarWitch)
		return MRES_Ignored;

	int touch = EntityFromEntityHandle(hParams.Get(1));

	if (touch < 1 || touch > MaxClients || !IsClientInGame(touch) || GetClientTeam(touch) != 2)
		return MRES_Ignored;

	if (GetEntDataEnt2(touch, m_pounceAttacker) == -1
		&& GetEntDataEnt2(touch, m_tongueOwner) == -1)
		return MRES_Ignored;

	// riverside2: the mover comes from the DetectCollision detour (only on when the settings
	// differ and a witch exists; otherwise every mover is treated alike)
	bool bWitch = g_bDetourOn && g_iDepth > 0 && g_iDepth <= sizeof(g_bWitchMoving) && g_bWitchMoving[g_iDepth - 1];
	if (g_bCvarCommon != g_bCvarWitch && (bWitch ? !g_bCvarWitch : !g_bCvarCommon))
	{
		g_iStatCollide[bWitch ? 1 : 0]++;
		return MRES_Ignored;
	}

	g_iStatPhase[bWitch ? 1 : 0]++;
	hReturn.Value = false;
	return MRES_Override;
}

int EntityFromEntityHandle(Address pHandleEntity)
{
	if (pHandleEntity == Address_Null)
		return -1;

	Address ehandle = SDKCall(g_call_GetRefEHandle, pHandleEntity);
	return LoadEntityFromHandleAddress(ehandle);
}

Action Cmd_Stats(int client, int args)
{
	ReplyToCommand(client, "[infected_collisions] detour %s, witches %d, traces %d (witch %d) | pinned survivor: commons phase %d collide %d, witch phase %d collide %d",
		g_bDetourOn ? "on" : "off", g_iWitches, g_iStatTraces, g_iStatWitchTraces, g_iStatPhase[0], g_iStatCollide[0], g_iStatPhase[1], g_iStatCollide[1]);
	return Plugin_Handled;
}
