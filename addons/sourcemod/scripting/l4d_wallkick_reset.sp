/**
 * l4d_wallkick_reset: a hunter that pounced or scratched someone can wall kick again.
 *
 * Valve's CLunge keeps two "no wall kick" flags:
 *   m_bTouchedPlayer (m_isLunging + 16): set by CLunge::OnTouch whenever the hunter touches a player.
 *       While it is set, an airborne touch of the world no longer opens the 0.5 s wall-kick window.
 *   m_bNoLungeAgain (m_isLunging + 1): set by CLunge::OnOwnerTakeDamage when the hunter is hurt
 *       mid-pounce. While it is set, the window counts as closed.
 * Both are meant to last for one pounce ("touched a survivor / got shot during THIS pounce, so no kick
 * off the next wall"). But stock server.so clears them only in CLunge::OnCreate (spawn) and at the end
 * of CLunge::ActivateAbility (a new pounce starting). Checked in server.so a4f7509e: no other writer.
 *
 * So after a pin, a scratch that bumped a survivor, or a pounce that got shot, the flag stays set while
 * the hunter is back on its feet. A plain jump at a wall (no fresh pounce from the ground first) then
 * cannot be kicked off: OnTouch refuses to open the window, or CanLungeAgain says no.
 *
 * Fix: once the hunter stands on the ground and is not lunging, m_bTouchedPlayer is cleared, so it again
 * means "during this flight". Touching a survivor during a jump or pounce still costs the kick off the next
 * wall. m_bNoLungeAgain is left alone: l4d_pounceprotect (Rotoblin, live) already clears it after every hit,
 * which also allows a kick in the same flight (verified 2026-11-15 by bisecting the live plugin set).
 *
 * l4d_backjump_fix reads the same +16 byte for prop touches, so it benefits too.
 *
 * 1.2: no pounce off a survivor. The game treats a survivor's head as ground, so a hunter that jumps onto (or gets
 * wedged into the top of) a survivor can crouch and pounce straight off him, usually pinning him at once. That is
 * stock and has nothing to do with the flags above (match 1258, No Mercy 3: the hunter hung in the survivor's
 * shoulders for 0.3 s, was pushed up onto the head, and pounced one tick later; the kick window was never open).
 * Rule: a hunter's attack press is dropped while it stands on a living survivor or its feet are in the top of one.
 * A hunter with real floor under its feet (car roof, ledge) is never blocked, whoever stands beside it.
 * It can pounce again as soon as it is off him. l4d_wallkick_reset_survivor 0 turns only this off.
 */
#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.2"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_HUNTER 3

// CLunge layout in server.so a4f7509e (and l4d-source lunge_fields.inc).
#define EXPECTED_ISLUNGING 0x3b8
#define OFF_TOUCHEDPLAYER 16   // m_bTouchedPlayer

// Feet this far below / above the top of a survivor's box count as being on him (wedged 14 below in match 1258).
#define HEAD_BELOW 24.0
#define HEAD_ABOVE 6.0

ConVar g_cvEnable, g_cvSurvivor, g_cvDebug;
int g_offLunging = -1;

public Plugin myinfo =
{
	name = "L4D hunter wall kick reset",
	author = "Malevolence",
	description = "Clears the hunter's stale touched-a-player flag on landing; no pounce off a survivor's head",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_offLunging = FindSendPropInfo("CLunge", "m_isLunging");
	if (g_offLunging != EXPECTED_ISLUNGING)
		SetFailState("CLunge::m_isLunging at %d, expected %d: server.so layout changed", g_offLunging, EXPECTED_ISLUNGING);

	g_cvEnable = CreateConVar("l4d_wallkick_reset_enable", "1", "1 = clear the hunter's touched-a-player flag when it lands", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvSurvivor = CreateConVar("l4d_wallkick_reset_survivor", "1", "1 = a hunter standing on (or wedged into the top of) a survivor cannot pounce off him", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d_wallkick_reset_debug", "0", "1 = tell the hunter in chat when a stale flag was cleared", FCVAR_NONE, true, 0.0, true, 1.0);
	CreateConVar("l4d_wallkick_reset_version", PLUGIN_VERSION, "l4d_wallkick_reset version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
}

/** The lunge ability of a living hunter, or -1. */
int HunterLunge(int client)
{
	if (GetClientTeam(client) != TEAM_INFECTED || !IsPlayerAlive(client))
		return -1;
	if (GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_HUNTER)
		return -1;
	int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
	if (ability <= MaxClients || !IsValidEntity(ability))
		return -1;
	static char cls[16];
	if (!GetEntityClassname(ability, cls, sizeof cls) || !StrEqual(cls, "ability_lunge"))
		return -1;
	return ability;
}

public bool Filter_NotPlayers(int entity, int mask)
{
	return entity == 0 || entity > MaxClients;
}

/** True when the world or a prop (anything but a player) is right under these feet. */
bool OnSolidFloor(const float feet[3])
{
	float end[3];
	end = feet;
	end[2] -= 4.0;
	Handle tr = TR_TraceHullFilterEx(feet, end, view_as<float>({-16.0, -16.0, 0.0}), view_as<float>({16.0, 16.0, 1.0}), MASK_PLAYERSOLID, Filter_NotPlayers);
	bool hit = TR_DidHit(tr);
	delete tr;
	return hit;
}

/** True when the hunter stands on a living survivor, or its feet are inside the top of one. */
bool OnSurvivor(int client)
{
	int ground = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
	if (ground >= 1 && ground <= MaxClients && GetClientTeam(ground) == TEAM_SURVIVOR && IsPlayerAlive(ground))
		return true;
	// The ground entity is not always the survivor (it was not in match 1258), so also test the boxes.
	float me[3], them[3], maxs[3];
	GetClientAbsOrigin(client, me);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;
		GetClientAbsOrigin(i, them);
		if (FloatAbs(me[0] - them[0]) >= 32.0 || FloatAbs(me[1] - them[1]) >= 32.0)
			continue;  // hulls are 32 wide: no overlap seen from above
		GetEntPropVector(i, Prop_Send, "m_vecMaxs", maxs);
		float top = them[2] + maxs[2];
		if (me[2] >= top - HEAD_BELOW && me[2] <= top + HEAD_ABOVE)
			return !OnSolidFloor(me);  // on a car roof or ledge with the survivor tucked beside it: a normal pounce
	}
	return false;
}

public Action OnPlayerRunCmd(int client, int &buttons)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;
	int ability = HunterLunge(client);
	if (ability == -1)
		return Plugin_Continue;

	if ((buttons & IN_ATTACK) && g_cvSurvivor.BoolValue && OnSurvivor(client))
	{
		buttons &= ~IN_ATTACK;
		if (g_cvDebug.BoolValue && !IsFakeClient(client) && !(GetEntProp(client, Prop_Data, "m_nOldButtons") & IN_ATTACK))
			PrintToChat(client, "[wallkick] no pounce off a survivor");
		return Plugin_Changed;  // still on him: the flag is his to keep
	}

	if (!(GetEntityFlags(client) & FL_ONGROUND))
		return Plugin_Continue;
	if (GetEntData(ability, g_offLunging, 1))
		return Plugin_Continue;  // still in a pounce (a landing counts after 0.5 s): its flag belongs to it

	if (!GetEntData(ability, g_offLunging + OFF_TOUCHEDPLAYER, 1))
		return Plugin_Continue;

	// Not networked, so a plain write is enough.
	SetEntData(ability, g_offLunging + OFF_TOUCHEDPLAYER, 0, 1, false);
	if (g_cvDebug.BoolValue && !IsFakeClient(client))
		PrintToChat(client, "[wallkick] cleared the touched-a-player flag");
	return Plugin_Continue;
}
