/**
 * l4d_witch_fire_fix: map fire no longer burns the witch.
 *
 * A burning witch chases whoever set her on fire. When that is a map fire (the
 * trigger_hurt on a fire barrel or a burning car, which hurts NPCs as well as players),
 * nobody is credited and she drops the survivor she was chasing. Dead Air 3 has a fire
 * barrel at -4581 -903 on a spot she climbs (match 683, 2026-10-14).
 *
 * Burn damage to a witch is dropped unless a survivor dealt it, so the map fire never
 * lights her. Molotovs, gas cans and a burning witch a survivor lit are untouched: the
 * survivor is the attacker on every tick of those.
 *
 * 1.0.1: CEntityFlame::FlameThink (server.so 0x43b5e6) credits each burn tick to whoever lit
 * her only while that player is still a team-2 client. If the survivor who lit her left, went
 * idle or changed team, 1.0.0 dropped the ticks and she burned forever without dying. Burn
 * damage dealt by her own flame (her m_hEffectEntity) is now always let through: map fire
 * never gets to light her, so a flame of her own was started by a survivor.
 */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "L4D Witch Fire Fix",
	author = "Malevolence",
	description = "Map fire no longer burns the witch",
	version = "1.0.1",
	url = ""
};

public void OnPluginStart()
{
	int e = -1;
	while ((e = FindEntityByClassname(e, "witch")) != -1)
		SDKHook(e, SDKHook_OnTakeDamage, OnWitchDamage);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "witch"))
		SDKHook(entity, SDKHook_OnTakeDamage, OnWitchDamage);
}

public Action OnWitchDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!(damagetype & DMG_BURN)) return Plugin_Continue;
	if (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
		return Plugin_Continue;
	int flame = GetEntPropEnt(victim, Prop_Send, "m_hEffectEntity");
	if (flame > MaxClients && inflictor == flame)
		return Plugin_Continue;
	return Plugin_Handled;
}
