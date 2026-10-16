/**
 * l4d_witch_direct_fix: stops a startled witch from cutting straight at her victim across a gap.
 *
 * WitchAttack::Update (and DirectChasePath::Update for other infected) drops the nav path and runs
 * straight at the victim whenever no climb or gap jump is ahead on the path and her locomotion's
 * ILocomotion::IsPotentiallyTraversable(feet, victim) says yes. That check is a hull trace plus a
 * height limit (GetMaxJumpHeight, 180); it never asks whether there is floor under the line. So a
 * witch walking up a ramp toward a survivor on a ledge sees a clear line through the open air above
 * a pit, turns off her path and runs straight at them, falls back below the ledge, loses the line,
 * picks the path up again, climbs the ramp, and does it again (Death Toll 4 crater: 11-15 s chases
 * for 390 units; she reaches the target in ~4 s once the shortcut is refused).
 *
 * The fix hooks IsPotentiallyTraversable (vtable slot 83) on each witch's own WitchLocomotion, so
 * commons and special infected never see it. When the game says yes to a line at least
 * l4d_witch_direct_fix_minlen long (shorter calls are path look-ahead probes at ledge edges), the
 * plugin walks the 2D line and traces down every l4d_witch_direct_fix_step units: if the floor
 * anywhere falls more than l4d_witch_direct_fix_drop below both the line and the victim's height,
 * the answer becomes no and she keeps following her nav path. A clean drop down to a victim below
 * her still passes. Rig, 24 spots: DT4 crater 18.1 -> 6.3 s, BH2 train car 17.2 -> 5.6 s, the rest
 * within noise (witchfix/rig/batch_direct.txt, batch_v3.txt).
 *
 * l4d_witch_direct_fix_mode: 0 off, 1 refuse every shortcut (test only), 2 refuse shortcuts over a gap.
 * Linux and Windows (Windows: offsets from server.dll, the same layout as l4d_witch_corner_fix 1.1).
 */
#include <sourcemod>
#include <sdktools>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "L4D Witch Direct Fix",
	author = "Malevolence",
	description = "Stops a startled witch cutting straight at her victim across a gap",
	version = "1.1.0",
	url = ""
};

int g_locoOffset;             // Witch -> WitchLocomotion*
Address g_witchVtable;        // what a WitchLocomotion's vptr holds
DynamicHook g_trav;
int g_hook[2048] = { INVALID_HOOK_ID, ... };
ConVar g_cvMode, g_cvDrop, g_cvStep, g_cvMinLen, g_cvLog;

public void OnPluginStart()
{
	GameData gd = new GameData("l4d_witch_direct_fix");
	if (gd == null) SetFailState("gamedata l4d_witch_direct_fix.txt missing");
	bool windows = gd.GetOffset("Platform") == 2;
	Address gli = gd.GetAddress("GetLocomotionInterface");
	Address vt = gd.GetAddress("WitchLocomotionVtable");
	int slot = gd.GetOffset("ILocomotion::IsPotentiallyTraversable");
	delete gd;
	if (gli == Address_Null || vt == Address_Null || slot < 0) SetFailState("a symbol was not found");

	if (windows)
	{
		// no getter to read here: gli is Witch::CreateComponents, and at +0x48, right after the
		// WitchLocomotion is built, it stores it with mov [esi+imm32], edi (89 BE ....)
		if (Byte(gli, 0x48) != 0x89 || Byte(gli, 0x49) != 0xBE) SetFailState("Witch::CreateComponents has an unexpected shape");
		g_locoOffset = LoadFromAddress(gli + view_as<Address>(0x4A), NumberType_Int32);
		g_witchVtable = vt;
	}
	else
	{
		// mov eax,[esp+4] (8B 44 24 04); mov eax,[eax+imm32] (8B 80 ....); ret (C3)
		int head[6] = { 0x8B, 0x44, 0x24, 0x04, 0x8B, 0x80 };
		for (int i = 0; i < 6; i++)
			if (Byte(gli, i) != head[i]) SetFailState("Witch::GetLocomotionInterface has an unexpected shape");
		if (Byte(gli, 10) != 0xC3) SetFailState("Witch::GetLocomotionInterface has an unexpected shape");
		g_locoOffset = LoadFromAddress(gli + view_as<Address>(6), NumberType_Int32);
		g_witchVtable = vt + view_as<Address>(8);
	}

	// bool IsPotentiallyTraversable(const Vector &from, const Vector &to, TraverseWhenType when, float *fraction)
	g_trav = new DynamicHook(slot, HookType_Raw, ReturnType_Bool, ThisPointer_Address);
	g_trav.AddParam(HookParamType_VectorPtr);
	g_trav.AddParam(HookParamType_VectorPtr);
	g_trav.AddParam(HookParamType_Int);
	g_trav.AddParam(HookParamType_Int);

	g_cvMode = CreateConVar("l4d_witch_direct_fix_mode", "2", "0 off, 1 refuse every straight-line shortcut (test), 2 refuse shortcuts over a gap", _, true, 0.0, true, 2.0);
	g_cvDrop = CreateConVar("l4d_witch_direct_fix_drop", "48", "Refuse the shortcut if the floor falls this far below the straight line anywhere along it", _, true, 18.0);
	g_cvStep = CreateConVar("l4d_witch_direct_fix_step", "24", "Spacing of the floor checks along the line", _, true, 8.0);
	g_cvMinLen = CreateConVar("l4d_witch_direct_fix_minlen", "96", "Only check lines at least this long (shorter ones are path look-ahead probes)", _, true, 0.0);
	g_cvLog = CreateConVar("l4d_witch_direct_fix_log", "0", "1: log every refused shortcut");
	AutoExecConfig(true, "l4d_witch_direct_fix");

	int w = -1;
	while ((w = FindEntityByClassname(w, "witch")) != -1) HookWitch(w);
}

public void OnPluginEnd()
{
	for (int i = 0; i < sizeof(g_hook); i++) Unhook(i);
}

int Byte(Address base, int off)
{
	return LoadFromAddress(base + view_as<Address>(off), NumberType_Int8) & 0xFF;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// the locomotion object is built in Witch::CreateComponents, after creation: wait a frame
	if (entity > MaxClients && entity < 2048 && StrEqual(classname, "witch"))
		RequestFrame(F_Hook, EntIndexToEntRef(entity));
}

public void F_Hook(int ref)
{
	int w = EntRefToEntIndex(ref);
	if (w != INVALID_ENT_REFERENCE) HookWitch(w);
}

void HookWitch(int w)
{
	if (g_hook[w] != INVALID_HOOK_ID) return;
	Address loco = view_as<Address>(LoadFromAddress(GetEntityAddress(w) + view_as<Address>(g_locoOffset), NumberType_Int32));
	if (loco == Address_Null) { LogError("witch %d has no locomotion yet", w); return; }
	Address vt = view_as<Address>(LoadFromAddress(loco, NumberType_Int32));
	if (vt != g_witchVtable) { LogError("witch %d locomotion has vtable %X, expected %X; not hooking", w, vt, g_witchVtable); return; }
	g_hook[w] = g_trav.HookRaw(Hook_Post, loco, Trav_Post);
}

public void OnEntityDestroyed(int entity)
{
	if (entity > MaxClients && entity < 2048) Unhook(entity);
}

void Unhook(int i)
{
	if (g_hook[i] != INVALID_HOOK_ID) { DynamicHook.RemoveHook(g_hook[i]); g_hook[i] = INVALID_HOOK_ID; }
}

public MRESReturn Trav_Post(Address loco, DHookReturn ret, DHookParam params)
{
	int mode = g_cvMode.IntValue;
	if (mode == 0 || !ret.Value) return MRES_Ignored;
	float from[3], to[3];
	params.GetVector(1, from);
	params.GetVector(2, to);
	if (mode == 1 || OverGap(from, to))
	{
		if (g_cvLog.BoolValue)
			LogMessage("refused shortcut %.0f %.0f %.0f -> %.0f %.0f %.0f", from[0], from[1], from[2], to[0], to[1], to[2]);
		ret.Value = false;
		return MRES_Override;
	}
	return MRES_Ignored;
}

// True if, anywhere along the 2D line from -> to, the floor sits more than the drop limit below both
// the straight line and the victim's height: the shortcut would cross a pit or open air. A clean
// drop down to a victim below her passes (the floor never goes lower than the victim stands).
bool OverGap(const float from[3], const float to[3])
{
	float dx = to[0] - from[0], dy = to[1] - from[1];
	float len = SquareRoot(dx * dx + dy * dy);
	// short look-ahead probes from the path follower (about 45 units, at ledge edges before a drop)
	// are not the victim shortcut; leave them to the game
	if (len < g_cvMinLen.FloatValue) return false;
	float step = g_cvStep.FloatValue, drop = g_cvDrop.FloatValue;
	for (float u = step; u < len - 16.0; u += step)
	{
		float f = u / len;
		float a[3], b[3];
		a[0] = from[0] + dx * f; a[1] = from[1] + dy * f;
		float lineZ = from[2] + (to[2] - from[2]) * f;
		// start at her level or the line, whichever is higher, so a trace never begins under the floor she stands on
		a[2] = (lineZ > from[2] ? lineZ : from[2]) + 32.0;
		b[0] = a[0]; b[1] = a[1]; b[2] = (lineZ < to[2] ? lineZ : to[2]) - drop;
		Handle t = TR_TraceRayFilterEx(a, b, MASK_NPCSOLID_BRUSHONLY, RayType_EndPoint, F_World);
		bool hit = TR_DidHit(t);
		delete t;
		if (!hit) return true;
	}
	return false;
}

public bool F_World(int ent, int mask) { return ent == 0 || ent > MaxClients; }
