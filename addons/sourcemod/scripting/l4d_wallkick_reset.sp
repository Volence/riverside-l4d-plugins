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
 */
#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1"

#define TEAM_INFECTED 3
#define ZC_HUNTER 3

// CLunge layout in server.so a4f7509e (and l4d-source lunge_fields.inc).
#define EXPECTED_ISLUNGING 0x3b8
#define OFF_TOUCHEDPLAYER 16   // m_bTouchedPlayer

ConVar g_cvEnable, g_cvDebug;
int g_offLunging = -1;

public Plugin myinfo =
{
	name = "L4D hunter wall kick reset",
	author = "Malevolence",
	description = "Clears the hunter's stale touched-a-player flag on landing",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_offLunging = FindSendPropInfo("CLunge", "m_isLunging");
	if (g_offLunging != EXPECTED_ISLUNGING)
		SetFailState("CLunge::m_isLunging at %d, expected %d: server.so layout changed", g_offLunging, EXPECTED_ISLUNGING);

	g_cvEnable = CreateConVar("l4d_wallkick_reset_enable", "1", "1 = clear the hunter's touched-a-player flag when it lands", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d_wallkick_reset_debug", "0", "1 = tell the hunter in chat when a stale flag was cleared", FCVAR_NONE, true, 0.0, true, 1.0);
	CreateConVar("l4d_wallkick_reset_version", PLUGIN_VERSION, "l4d_wallkick_reset version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
}

public Action OnPlayerRunCmd(int client, int &buttons)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;
	if (!IsPlayerAlive(client) || GetClientTeam(client) != TEAM_INFECTED)
		return Plugin_Continue;
	if (GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_HUNTER)
		return Plugin_Continue;
	if (!(GetEntityFlags(client) & FL_ONGROUND))
		return Plugin_Continue;

	int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
	if (ability <= MaxClients || !IsValidEntity(ability))
		return Plugin_Continue;
	static char cls[16];
	if (!GetEntityClassname(ability, cls, sizeof cls) || !StrEqual(cls, "ability_lunge"))
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
