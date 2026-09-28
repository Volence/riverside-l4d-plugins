/*
 * [L4D1] Tank Burn Damage Cap
 *
 * WHY THIS EXISTS
 * ---------------
 * In L4D1 versus a molotov is not a chip-damage weapon against a tank -- it is a
 * kill. Once the tank is lit it burns to death, and the burn rate is calibrated
 * so that happens in exactly z_tank_burning_lifetime seconds regardless of how
 * much health the tank has (see l4d_tankhud.sp:95, which derives the HUD's
 * "On Fire: Ns" countdown as health / (z_tank_health / z_tank_burning_lifetime)).
 * There is no cvar for "how much damage does fire do to a tank" to turn down.
 *
 * This plugin adds one: it tallies the fire damage the tank absorbs and puts the
 * fire out once the tally reaches l4d_tank_burn_cap. It is used by the 4v4 Lite
 * config so newer players get something out of a molotov without the tank simply
 * evaporating.
 *
 * WHY NOT si_fire_immunity.smx
 * ----------------------------
 * Rotoblin already ships si_fire_immunity, whose tank_fire_immunity 3 +
 * tank_extinguish_time is the same idea expressed as a timer. Two problems:
 * it is gated on "GasCan_map" in addons/sourcemod/data/mapinfo.txt, which is
 * true on only three L4D2 maps we never play, and that same flag is what
 * rotoblin.itemcontrol.sp:215 reads to decide whether to strip gascans -- so
 * enabling it globally would hand every mode its cannisters back. A timer is
 * also only as accurate as the damage-rate arithmetic; counting the damage is
 * exact.
 *
 * IMPLEMENTATION NOTES
 * --------------------
 * - SDKHook_OnTakeDamageAlive, not SDKHook_OnTakeDamage. anti-friendly_fire.sp
 *   (which ships with Roto-AZ and supports L4D1) commented the latter out at
 *   line 200 with the note that it fires before health is actually deducted;
 *   its line 376 documents the full L4D1 order:
 *     OnTakeDamage -> AllowDamage detour -> OnTakeDamageAlive -> player_hurt
 * - L4D1's SDKHooks gives the SHORT 5-argument callback. No weapon /
 *   damageForce / damagePosition / damagecustom params like the L4D2 examples.
 * - The extinguish is deferred one frame rather than done inline. Reaching into
 *   the entity while the engine is mid-damage-call is how this sort of plugin
 *   crashes a server.
 * - The tally is global and per ROUND, not per client. It has to survive a tank
 *   pass, which changes the controlling client while the tank keeps its health;
 *   a per-client tally would hand the next player a fresh budget. In this mode
 *   there is one tank per round, so "per round" and "per tank" are the same
 *   thing. If a second tank in a single round ever matters, reset on tank_spawn
 *   when no other tank is live -- l4d_tankhud.sp:246 has the exclude-self helper.
 *
 * CVARS
 *   l4d_tank_burn_cap           0     Max fire damage per round. 0 = off.
 *   l4d_tank_burn_cap_announce  1     Chat line when the cap is hit.
 *
 * Default is 0 so the plugin is inert everywhere. cfg/Reloadables/
 * server_custom_convars.cfg re-asserts 0 on every map in every mode, and only
 * rotoblin_lite_4v4_map.cfg turns it on -- otherwise the value would leak into
 * whatever mode was loaded next.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION      "1.0-2026/8/19"

#define L4D_TEAM_INFECTED   3
#define ZC_TANK             5   // m_zombieClass for the L4D1 tank (l4d_tankhud.sp:105)

ConVar g_hCvarCap;
ConVar g_hCvarAnnounce;

float  g_fCap;
bool   g_bAnnounce;

float  g_fBurnTaken;    // fire damage the tank has absorbed this round
bool   g_bCapReached;

public Plugin myinfo =
{
	name        = "[L4D1] Tank Burn Damage Cap",
	author      = "volence",
	description = "Caps total fire damage on the tank so a molotov chips it instead of killing it",
	version     = PLUGIN_VERSION,
	url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("l4d_tank_burn_cap_version", PLUGIN_VERSION, "Tank Burn Damage Cap version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_hCvarCap = CreateConVar("l4d_tank_burn_cap", "0",
		"Max total fire damage a tank can absorb in one round before the fire is put out. 0 = disabled, tank burns to death as normal.",
		FCVAR_NOTIFY, true, 0.0);

	g_hCvarAnnounce = CreateConVar("l4d_tank_burn_cap_announce", "1",
		"Print a chat line when the tank hits the cap and stops burning. [0-No, 1-Yes]",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	GetCvars();
	g_hCvarCap.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarAnnounce.AddChangeHook(ConVarChanged_Cvars);

	HookEvent("round_start", Event_RoundReset, EventHookMode_PostNoCopy);
	HookEvent("round_end",   Event_RoundReset, EventHookMode_PostNoCopy);

	// Late load (sm plugins reload) -- hook whoever is already connected.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			OnClientPutInServer(i);
		}
	}
}

void GetCvars()
{
	g_fCap     = g_hCvarCap.FloatValue;
	g_bAnnounce = g_hCvarAnnounce.BoolValue;
}

public void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

public void OnMapStart()
{
	ResetRound();
}

void Event_RoundReset(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

void ResetRound()
{
	g_fBurnTaken  = 0.0;
	g_bCapReached = false;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
}

public Action OnTakeDamageAlive(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (g_fCap <= 0.0 || damage <= 0.0)
	{
		return Plugin_Continue;
	}

	// Fire only. The DMG_BULLET guard mirrors anti-friendly_fire.sp:485 -- burning
	// ammo arrives as BURN|BULLET and is not what this cap is about.
	if (!(damagetype & DMG_BURN) || (damagetype & DMG_BULLET))
	{
		return Plugin_Continue;
	}

	if (victim < 1 || victim > MaxClients) return Plugin_Continue;
	if (!IsClientInGame(victim) || !IsPlayerAlive(victim)) return Plugin_Continue;
	if (GetClientTeam(victim) != L4D_TEAM_INFECTED) return Plugin_Continue;
	if (GetEntProp(victim, Prop_Send, "m_zombieClass") != ZC_TANK) return Plugin_Continue;

	// Already spent. Anything that re-lights the tank later in the round (map
	// fire, a second molotov) gets blocked and snuffed the same way.
	if (g_bCapReached)
	{
		damage = 0.0;
		RequestFrame(Frame_Extinguish, GetClientUserId(victim));
		return Plugin_Handled;
	}

	float remaining = g_fCap - g_fBurnTaken;

	if (damage < remaining)
	{
		g_fBurnTaken += damage;
		return Plugin_Continue;
	}

	// This tick is the one that reaches the cap: let through only what is left of
	// the budget, then put the fire out.
	g_fBurnTaken  = g_fCap;
	g_bCapReached = true;
	damage        = remaining;

	RequestFrame(Frame_Extinguish, GetClientUserId(victim));

	if (g_bAnnounce)
	{
		PrintToChatAll("\x04[Tank]\x01 Fire cap reached (%d damage) - tank stopped burning.",
			RoundToNearest(g_fCap));
	}

	return (damage > 0.0) ? Plugin_Changed : Plugin_Handled;
}

// Deferred by one frame on purpose -- see the header note.
void Frame_Extinguish(any userid)
{
	int client = GetClientOfUserId(userid);

	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client)
		&& (GetEntityFlags(client) & FL_ONFIRE))
	{
		ExtinguishEntity(client);
	}
}
