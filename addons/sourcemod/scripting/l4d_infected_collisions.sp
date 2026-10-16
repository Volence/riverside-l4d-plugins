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

public Plugin myinfo =
{
	name = "[L4D1/L4D2] ZombieBotCollisionTraceFilter ignore pinned survivor",
	author = "Forgetest, Malevolence",
	description = "Common infected and witch can phase through pulled or pounced survivors",
	version = "1.0-2026/10/6-riverside1",
	url = "https://github.com/jensewe"
}

#define MAXENTITIES 2048
#define OFFSET_PASSENT 4

Handle g_call_GetRefEHandle;
int m_pounceAttacker,
	m_tongueOwner;

ConVar g_hCvarCommon, g_hCvarWitch;
bool g_bCvarCommon, g_bCvarWitch;
bool g_bIsWitch[MAXENTITIES + 1];

public void OnPluginStart()
{
	GameDataWrapper gd = new GameDataWrapper("l4d_infected_collisions");

	SDKCallParamsWrapper params[] = {
		{SDKType_PlainOldData, SDKPass_Plain},
	};
	g_call_GetRefEHandle = gd.CreateSDKCallOrFail(SDKCall_Raw, SDKConf_Virtual, "IHandleEntity::GetRefEHandle", _, 0, true, params[0]);

	delete gd.CreateDetourOrFail("l4d_infected_collisions::ZombieBotCollisionTraceFilter::ShouldHitEntity", DTR_ShouldHitEntity);
	delete gd;

	m_pounceAttacker = FindSendPropInfo("CTerrorPlayer", "m_pounceAttacker");
	m_tongueOwner = FindSendPropInfo("CTerrorPlayer", "m_tongueOwner");

	g_hCvarCommon = CreateConVar("l4d_infected_collisions_common", "1", "If 1, common infected walk through a survivor who is pulled, choked or pounced", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarWitch = CreateConVar("l4d_infected_collisions_witch", "0", "If 1, the witch walks through a survivor who is pulled, choked or pounced", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarCommon.AddChangeHook(ConVarChanged);
	g_hCvarWitch.AddChangeHook(ConVarChanged);
	GetCvars();

	AutoExecConfig(true, "l4d_infected_collisions");

	// late load: mark witches that already exist
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "witch")) != -1)
	{
		if (entity <= MAXENTITIES)
			g_bIsWitch[entity] = true;
	}
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_bCvarCommon = g_hCvarCommon.BoolValue;
	g_bCvarWitch = g_hCvarWitch.BoolValue;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity < 0 || entity > MAXENTITIES)
		return;

	g_bIsWitch[entity] = (classname[0] == 'w' && strcmp(classname, "witch") == 0);
}

public void OnEntityDestroyed(int entity)
{
	if (entity >= 0 && entity <= MAXENTITIES)
		g_bIsWitch[entity] = false;
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

	// riverside1: only now look up the mover, so the common case (touch is not a pinned survivor) costs nothing extra
	if (!g_bCvarCommon || !g_bCvarWitch)
	{
		int mover = EntityFromEntityHandle(view_as<Address>(LoadFromAddress(pThis + view_as<Address>(OFFSET_PASSENT), NumberType_Int32)));
		bool bWitch = (mover > 0 && mover <= MAXENTITIES && g_bIsWitch[mover]);
		if (bWitch ? !g_bCvarWitch : !g_bCvarCommon)
			return MRES_Ignored;
	}

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
