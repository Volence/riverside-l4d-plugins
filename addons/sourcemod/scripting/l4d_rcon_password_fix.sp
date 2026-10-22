// l4d_rcon_password_fix: setting rcon_password to the value it already has no longer closes
// every RCON connection.
//
// Stock L4D1 engine bug (R3 in the engine rebuild's docs/engine/rcon.md, engine.so sha256 0d3f61c2...):
// ConVar::ChangeStringValue calls the change callback without comparing old and new, and
// RconPasswordChanged_f (0x1acd36) calls CSocketCreator::CloseAllAcceptedSockets unconditionally.
// Our cfgs set rcon_password on every map start (riverside/server.cfg -> exec secrets.cfg), and the
// site runs `exec secrets.cfg` when it releases a server, so every changelevel and every release
// dropped every open rcon connection, including the site's own.
//
// The fix is a detour on RconPasswordChanged_f that skips it when the new value equals the old one.
// That callback does exactly two things (close every rcon socket, copy the new value into the RCON
// server's own password), and with the value unchanged the copy is a no-op, so skipping it changes
// nothing but the needless close. A real change runs the stock callback: everyone is closed and must
// log in again with the new password, as before.
//
// Fails safe: the plugin never sets or reads out the password itself. If it is not loaded, or the
// gamedata does not match the running engine.so, the server behaves exactly like stock.
// Safe to load and unload at any time.
#include <sourcemod>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"
#define TAG "[l4d_rcon_password_fix]"

public Plugin myinfo =
{
	name = "L4D RCON password fix",
	author = "Malevolence",
	description = "Re-setting rcon_password to the same value no longer closes every RCON connection",
	version = PLUGIN_VERSION,
	url = ""
};

ConVar g_cvPassword;
int g_iSkipped;

public void OnPluginStart()
{
	g_cvPassword = FindConVar("rcon_password");
	if (g_cvPassword == null)
		SetFailState("rcon_password not found; not attached");

	GameData gd = new GameData("l4d_rcon_password_fix.games");
	if (gd == null)
		SetFailState("gamedata l4d_rcon_password_fix.games missing; not attached, stock behaviour");
	// The prologue of the build this was written for: push edi; push esi; push ebx; sub $0x20,%esp.
	Address fn = gd.GetAddress("RconPasswordChanged_f");
	if (fn == Address_Null || !BytesAre(fn, {0x57, 0x56, 0x53, 0x83, 0xec, 0x20}, 6))
	{
		delete gd;
		SetFailState("RconPasswordChanged_f is not the code this plugin was built for; not attached, stock behaviour");
	}
	DynamicDetour d = DynamicDetour.FromConf(gd, "RconPasswordChanged_f");
	delete gd;
	if (d == null || !d.Enable(Hook_Pre, Detour_PasswordChanged))
		SetFailState("could not detour RconPasswordChanged_f; not attached, stock behaviour");

	CreateConVar("l4d_rcon_password_fix_version", PLUGIN_VERSION, "L4D RCON password fix version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	RegServerCmd("sm_rcon_password_fix_status", Cmd_Status, "How many same-value rcon_password sets were kept from closing rcon connections");
	LogMessage("%s %s attached", TAG, PLUGIN_VERSION);
}

bool BytesAre(Address a, const int[] want, int n)
{
	for (int i = 0; i < n; i++)
		if (LoadFromAddress(a + view_as<Address>(i), NumberType_Int8) != want[i])
			return false;
	return true;
}

// static void RconPasswordChanged_f(IConVar *var, const char *pOldValue, float flOldValue)
// Runs after the cvar already holds the new value.
public MRESReturn Detour_PasswordChanged(DHookParam hParams)
{
	char oldValue[512], newValue[512];
	if (hParams.IsNull(2))
		return MRES_Ignored;
	hParams.GetString(2, oldValue, sizeof(oldValue));
	g_cvPassword.GetString(newValue, sizeof(newValue));
	// A value that fills the buffer may have been cut, so it never counts as unchanged.
	if (strlen(oldValue) >= sizeof(oldValue) - 1 || strlen(newValue) >= sizeof(newValue) - 1)
		return MRES_Ignored;
	if (!StrEqual(oldValue, newValue, true))
		return MRES_Ignored;  // a real change: stock closes everyone and takes the new password
	g_iSkipped++;
	return MRES_Supercede;
}

public Action Cmd_Status(int args)
{
	PrintToServer("%s %s: %d same-value rcon_password set(s) kept from closing rcon connections since load", TAG, PLUGIN_VERSION, g_iSkipped);
	return Plugin_Handled;
}
