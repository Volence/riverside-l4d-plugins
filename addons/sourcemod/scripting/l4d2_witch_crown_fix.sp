#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>

#define WITCH_DAMAGE_THRESHOLD 799.0

new Float:inflictedDamage[MAXPLAYERS + 1];

public Plugin:myinfo = 
{
	name = "L4D2 Witch Crown Fix",
	author = "Visor",
	description = "Fixes the Witch not dying from a perfectly aligned shotgun blast due to the random nature of the pellet spread,l4d1 port by Harry",
	version = "1.2-riverside1",
	url = "https://github.com/Attano/ProMod"
};

public OnEntityCreated(entity, const String:classname[])
{
    if (StrEqual(classname, "witch"))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnWitchTakeDamage);
    }
}

public Action:OnWitchTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damageType, &weapon, Float:damageForce[3], Float:damagePosition[3]) 
{
	if (!IsWitch(victim) || !IsSurvivor(attacker) || IsFakeClient(attacker))
		return Plugin_Continue;
		
	decl String:sWeaponName[32];
	GetClientWeapon(attacker, sWeaponName, sizeof(sWeaponName));//正在拿的武器
	//PrintToChatAll("sWeaponName: %s",sWeaponName);
	
	if (StrEqual(sWeaponName, "weapon_pumpshotgun"))
	{
		inflictedDamage[attacker] += damage;
		if (inflictedDamage[attacker] >= WITCH_DAMAGE_THRESHOLD)
		{
			// riverside1: was z_witch_health - inflictedDamage + damage, a top-up to
			// exactly her max health in float. CBaseCombatCharacter::OnTakeDamage_Alive
			// takes floorf(damage) per hit and parks the fraction in
			// m_flDamageAccumulator, paying it out only in whole points, so the
			// fraction left there at the end of the blast never came off her.
			// When this was the blast's last pellet she lived on 1 HP (6 such
			// incaps 2026-10-04..18). Deal her current health plus a margin instead.
			damage = float(GetEntProp(victim, Prop_Data, "m_iHealth")) + 10.0;
			inflictedDamage[attacker] = 0.0;
			return Plugin_Changed;
		}
	}
	CreateTimer(0.1, ResetDamageCounter);
	return Plugin_Continue;
}

public Action:ResetDamageCounter(Handle:timer)
{
    for (new i = 1; i <= MaxClients; i++) 
	{
		inflictedDamage[i] = 0.0;
	}
}

bool:IsSurvivor(client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2);
}

bool:IsWitch(entity)
{
    if (entity > 0 && IsValidEntity(entity) && IsValidEdict(entity))
    {
        decl String:strClassName[64];
        GetEdictClassname(entity, strClassName, sizeof(strClassName));
        return StrEqual(strClassName, "witch");
    }
    return false;
}