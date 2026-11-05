/*
 * l4d_null_activator_guard: an input that reads its activator is dropped when the activator is NULL.
 *
 * Based on "[ANY] Fix Null Activator" 1.3 by GoD-Tony (original) and blueblur
 * (https://github.com/blueblur0730/modified-plugins). Changes in this copy:
 *   - The class -> input table is built in. Upstream's cfg repeats "entity_name" inside one section and reads it
 *     with KeyValues.GetString, which returns only the first key, so filter_activator_model was never hooked.
 *   - Only the filters whose PassesFilterImpl reads the activator without a NULL check in L4D1's server.so are
 *     hooked (disassembled 2026-11-04). filter_activator_team, filter_activator_infected_class, filter_enemy,
 *     filter_base and filter_damage_type check for NULL or never read it; blocking them would only suppress
 *     their OnFail / negated OnPass outputs.
 *   - Hooked in OnEntityCreated (plus existing entities on a late load), not by a sweep at OnMapStart, so
 *     point_template and other late spawns are covered.
 *   - AcceptInput's vtable offset comes from SourceMod's own sdktools gamedata; no gamedata file to ship.
 *   - A blocked input is logged to the game log as a NULLACTIVATOR line (the census, like NULLMODEL).
 *
 * The crash it guards, c6m2_bedlam 2026-11-04 (Riverside #3): a trigger queued filter_witchkill.TestActivator for
 * a common that was deleted before the event queue ran it, so pActivator was NULL and
 * CFilterModel::PassesFilterImpl read its vtable: SIGSEGV at 0. That trigger is removed by stripper; this covers
 * the same pattern on any other map.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION	"1.0"

public Plugin myinfo =
{
	name = "[L4D] Null activator guard",
	author = "GoD-Tony, blueblur, Malevolence",
	description = "Drops filter TestActivator / game_ui Deactivate with a NULL activator instead of crashing",
	version = PLUGIN_VERSION,
	url = ""
};

DynamicHook g_hAcceptInput;
StringMap g_hInputByClass;
int g_iHooked;

public void OnPluginStart()
{
	CreateConVar("l4d_null_activator_guard_version", PLUGIN_VERSION, "l4d_null_activator_guard version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	GameData gd = new GameData("sdktools.games");
	if (!gd) SetFailState("sdktools.games gamedata missing");
	int offset = gd.GetOffset("AcceptInput");
	delete gd;
	if (offset == -1) SetFailState("AcceptInput offset missing from sdktools.games");

	// bool CBaseEntity::AcceptInput(const char *szInputName, CBaseEntity *pActivator, CBaseEntity *pCaller, variant_t Value, int outputID)
	g_hAcceptInput = new DynamicHook(offset, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity);
	g_hAcceptInput.AddParam(HookParamType_CharPtr);
	g_hAcceptInput.AddParam(HookParamType_CBaseEntity);
	g_hAcceptInput.AddParam(HookParamType_CBaseEntity);
	g_hAcceptInput.AddParam(HookParamType_Object, 20);	// variant_t: 12-byte union + EHANDLE + fieldType
	g_hAcceptInput.AddParam(HookParamType_Int);

	g_hInputByClass = new StringMap();
	g_hInputByClass.SetString("filter_activator_model", "TestActivator");
	g_hInputByClass.SetString("filter_activator_class", "TestActivator");
	g_hInputByClass.SetString("filter_activator_name", "TestActivator");
	g_hInputByClass.SetString("filter_activator_context", "TestActivator");
	g_hInputByClass.SetString("filter_activator_mass_greater", "TestActivator");
	g_hInputByClass.SetString("filter_multi", "TestActivator");
	g_hInputByClass.SetString("game_ui", "Deactivate");

	// Late load: whatever already spawned on this map.
	// Filters and game_ui are server-only entities, indexed above the networked range (up to 4096).
	char cls[64];
	for (int ent = MaxClients + 1; ent < 4096; ent++)
	{
		if (IsValidEntity(ent) && GetEntityClassname(ent, cls, sizeof(cls))) Watch(ent, cls);
	}
	if (g_iHooked) LogMessage("hooked %d entities on late load", g_iHooked);
}

public void OnMapStart()
{
	// Map entities spawn before OnMapStart, so this is the map's own count.
	LogMessage("hooked %d entities", g_iHooked);
}

public void OnMapEnd()
{
	g_iHooked = 0;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// A server-only entity arrives as a reference (negative); hook it by its index.
	if (entity < 0) entity = EntRefToEntIndex(entity);
	if (entity > MaxClients) Watch(entity, classname);
}

void Watch(int entity, const char[] classname)
{
	// Fast reject: every class in the table starts with "f" or "g".
	if (classname[0] != 'f' && classname[0] != 'g') return;
	if (!g_hInputByClass.ContainsKey(classname)) return;
	if (g_hAcceptInput.HookEntity(Hook_Pre, entity, OnAcceptInput) != INVALID_HOOK_ID) g_iHooked++;
}

MRESReturn OnAcceptInput(int entity, DHookReturn hReturn, DHookParam hParams)
{
	if (!hParams.IsNull(2)) return MRES_Ignored;

	char cls[64], input[64], want[64];
	GetEntityClassname(entity, cls, sizeof(cls));
	hParams.GetString(1, input, sizeof(input));
	if (!g_hInputByClass.GetString(cls, want, sizeof(want)) || !StrEqual(input, want, false)) return MRES_Ignored;

	if (StrEqual(cls, "game_ui")) SetEntProp(entity, Prop_Data, "m_nNextThinkTick", -1);

	char map[64], name[64];
	GetCurrentMap(map, sizeof(map));
	GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
	LogToGame("NULLACTIVATOR map=%s class=%s name=\"%s\" input=%s", map, cls, name, input);

	hReturn.Value = false;
	return MRES_Supercede;
}
