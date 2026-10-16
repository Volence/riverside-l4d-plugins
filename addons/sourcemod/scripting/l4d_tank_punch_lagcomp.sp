#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION "1.0"
#define GAMEDATA "l4d_tank_punch_lagcomp"

#define TEAM_INFECTED	3
#define IN_ATTACK_BITS	(IN_ATTACK | IN_ATTACK2)

// Lag compensates a human tank's punch whether he taps or holds M1.
//
// Cause (proven 2026-10-15, l4d/source/docs/findings/tank-punch-tap-no-lagcomp.md): each fist
// sweep (CTankClaw::SweepFist, once per usercmd for tank_swing_duration after the 0.5 s windup)
// starts lag compensation, which asks CTerrorPlayer::WantsLagCompensationOnEntity before
// rewinding each survivor. That says yes only if the usercmd holds IN_ATTACK / IN_ATTACK2, or
// its command_number is within 5 of m_iLastWeaponFireUsercmd (+0x17EC). Guns and melee write
// that field; the claw never does. A tank who tapped M1 has let go before the windup ends, so
// his sweeps tested survivors where the server had them, not where he saw them. Stock rig:
// held punches 360 of 360 survivor checks rewound, tapped 0 of 360.
//
// Fix: from CTankClaw::OnWindupFinished (whose first sweep runs inside it) to OnSwingEnd (which
// runs right after the last sweep, same usercmd), keep the tank's m_iLastWeaponFireUsercmd at
// his current command number. That opens the game's own gate; its other checks (team, transmit
// bits, sv_unlag, the rewind itself) still run. Only lag compensation reads +0x17EC in
// server.so (CCSPlayer::OnWeaponFired and CTerrorPlayer::OnMeleeAttack write it), and the old
// value is put back when the window closes, so outside a punch nothing changes: rock throws,
// which also run in the tank's usercmd, keep stock behaviour. Bot tanks are never lag
// compensated by the game (separate bot check) and are left alone.
//
// l4d_tank_punch_lagcomp_debug 1 writes logs/tank_punch_lagcomp.log: one PUNCH line per human
// punch with its sweeps, how many ran with the gate open by this plugin, and how many already
// had attack held (stock would have rewound those anyway).

ConVar g_cvEnable, g_cvDebug;
int g_iOffLastFire;			// CTerrorPlayer::m_iLastWeaponFireUsercmd, from gamedata
char g_sLog[PLATFORM_MAX_PATH];

int g_iCmdNum[MAXPLAYERS + 1];		// command_number of the usercmd being run (OnPlayerRunCmd)
int g_iCmdButtons[MAXPLAYERS + 1];	// its buttons, for the debug "held" count
bool g_bInSwing[MAXPLAYERS + 1];	// windup finished, swing not ended: the gate is held open
int g_iSavedFire[MAXPLAYERS + 1];	// m_iLastWeaponFireUsercmd before the window, restored after

// debug counts for the punch in progress
int g_iSweeps[MAXPLAYERS + 1], g_iSweepsOpen[MAXPLAYERS + 1], g_iSweepsHeld[MAXPLAYERS + 1];
int g_iStatPunches, g_iStatSweeps, g_iStatOpen, g_iStatHeld;

public Plugin myinfo =
{
	name = "[L4D1] Tank Punch Lag Compensation",
	author = "Malevolence",
	description = "A human tank's punch is lag compensated whether he taps or holds attack.",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if( GetEngineVersion() != Engine_Left4Dead )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	GameData gd = new GameData(GAMEDATA);
	if( gd == null ) SetFailState("Missing gamedata \"%s\"", GAMEDATA);

	g_iOffLastFire = gd.GetOffset("CTerrorPlayer::m_iLastWeaponFireUsercmd");
	if( g_iOffLastFire <= 0 ) SetFailState("Missing offset CTerrorPlayer::m_iLastWeaponFireUsercmd");

	// same definitions as l4d_tank_fair_punch's detours on these functions
	DynamicDetour dw = DynamicDetour.FromConf(gd, "CTankClaw::OnWindupFinished");
	if( dw == null || !dw.Enable(Hook_Pre, Detour_OnWindupFinished) ) SetFailState("Failed to detour CTankClaw::OnWindupFinished");
	DynamicDetour de = DynamicDetour.FromConf(gd, "CTankClaw::OnSwingEnd");
	if( de == null || !de.Enable(Hook_Pre, Detour_OnSwingEnd) ) SetFailState("Failed to detour CTankClaw::OnSwingEnd");
	DynamicDetour dsf = DynamicDetour.FromConf(gd, "CTankClaw::SweepFist");
	if( dsf == null || !dsf.Enable(Hook_Pre, Detour_SweepFist) ) SetFailState("Failed to detour CTankClaw::SweepFist");
	delete gd;

	CreateConVar("l4d_tank_punch_lagcomp_version", PLUGIN_VERSION, "Tank Punch Lag Compensation version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d_tank_punch_lagcomp_enable", "1", "1 = a human tank's punch is lag compensated whether attack is held or tapped. 0 = stock (only while attack is held).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("l4d_tank_punch_lagcomp_debug", "0", "1 = log a PUNCH line per human punch to logs/tank_punch_lagcomp.log.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvEnable.AddChangeHook(OnEnableChanged);

	HookEvent("player_death", Event_PlayerGone);
	HookEvent("player_team", Event_PlayerGone);
	RegAdminCmd("sm_punchlagcomp_stats", Cmd_Stats, ADMFLAG_ROOT, "Human punches, sweeps, sweeps with the gate opened by this plugin, sweeps with attack held, since load.");
	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/tank_punch_lagcomp.log");
}

public void OnPluginEnd()
{
	for( int i = 1; i <= MaxClients; i++ ) EndWindow(i);
}

void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if( !convar.BoolValue )
		for( int i = 1; i <= MaxClients; i++ ) EndWindow(i);
}

public void OnClientDisconnect(int client)
{
	EndWindow(client);
}

void Event_PlayerGone(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if( client > 0 ) EndWindow(client);
}

// Close the window: put back the field's value from before the punch.
void EndWindow(int client)
{
	if( !g_bInSwing[client] ) return;
	g_bInSwing[client] = false;
	if( IsClientInGame(client) ) SetEntData(client, g_iOffLastFire, g_iSavedFire[client], 4);
}

int OwnerTank(int claw)
{
	if( claw <= MaxClients || !IsValidEntity(claw) ) return 0;
	int tank = GetEntPropEnt(claw, Prop_Send, "m_hOwner");
	if( tank < 1 || tank > MaxClients || !IsClientInGame(tank) ) return 0;
	return tank;
}

bool HoldsClaw(int client)
{
	int w = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if( w <= MaxClients || !IsValidEntity(w) ) return false;
	char cls[32];
	GetEntityClassname(w, cls, sizeof(cls));
	return StrEqual(cls, "weapon_tank_claw");
}

// Runs before each usercmd is processed, so a write here covers that usercmd's sweeps.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	g_iCmdNum[client] = cmdnum;
	g_iCmdButtons[client] = buttons;
	if( g_bInSwing[client] )
	{
		if( !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_INFECTED || !HoldsClaw(client) ) EndWindow(client);
		else SetEntData(client, g_iOffLastFire, cmdnum, 4);
	}
	return Plugin_Continue;
}

// Windup over: the punch goes live and its first sweep runs inside this call.
MRESReturn Detour_OnWindupFinished(int claw)
{
	if( !g_cvEnable.BoolValue ) return MRES_Ignored;
	int tank = OwnerTank(claw);
	if( tank == 0 || IsFakeClient(tank) ) return MRES_Ignored;
	if( !g_bInSwing[tank] ) g_iSavedFire[tank] = GetEntData(tank, g_iOffLastFire, 4);
	g_bInSwing[tank] = true;
	SetEntData(tank, g_iOffLastFire, g_iCmdNum[tank], 4);
	g_iSweeps[tank] = 0;
	g_iSweepsOpen[tank] = 0;
	g_iSweepsHeld[tank] = 0;
	return MRES_Ignored;
}

MRESReturn Detour_SweepFist(int claw, DHookParam hParams)
{
	int tank = OwnerTank(claw);
	if( tank == 0 || !g_bInSwing[tank] ) return MRES_Ignored;
	g_iSweeps[tank]++;
	if( GetEntData(tank, g_iOffLastFire, 4) == g_iCmdNum[tank] ) g_iSweepsOpen[tank]++;
	if( g_iCmdButtons[tank] & IN_ATTACK_BITS ) g_iSweepsHeld[tank]++;
	return MRES_Ignored;
}

// Runs after the swing's last sweep (also from holster, stun and the like).
MRESReturn Detour_OnSwingEnd(int claw, DHookParam hParams)
{
	int tank = OwnerTank(claw);
	if( tank == 0 || !g_bInSwing[tank] ) return MRES_Ignored;
	EndWindow(tank);
	g_iStatPunches++;
	g_iStatSweeps += g_iSweeps[tank];
	g_iStatOpen += g_iSweepsOpen[tank];
	g_iStatHeld += g_iSweepsHeld[tank];
	if( g_cvDebug.BoolValue )
	{
		char map[64];
		GetCurrentMap(map, sizeof(map));
		LogToFileEx(g_sLog, "PUNCH map=%s tank=\"%N\" sweeps=%d in_window=%d held=%d",
			map, tank, g_iSweeps[tank], g_iSweepsOpen[tank], g_iSweepsHeld[tank]);
	}
	return MRES_Ignored;
}

Action Cmd_Stats(int client, int args)
{
	ReplyToCommand(client, "[punchlagcomp] enable %d: punches %d, sweeps %d, in window %d, attack held %d",
		g_cvEnable.IntValue, g_iStatPunches, g_iStatSweeps, g_iStatOpen, g_iStatHeld);
	return Plugin_Handled;
}
