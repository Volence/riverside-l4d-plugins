#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "0.1"

/**
 * l4d_tank_pass_fix - a passed tank no longer bounces off its new owner.
 *
 * When a human tank runs out of frustration the director starts a lottery
 * (director_tank_lottery_selection_time, 3 s here) and then hands the tank
 * to the winner. About one pass in ten, a SECOND "Tank offer: Starting the
 * lottery" fires in the same second as that handoff. The winner gets the
 * tank, and when the second lottery finishes 3 s later it is taken off them
 * and given to somebody else. Server logs from all our boxes, 2026-07-27 to
 * 2026-09-27: 1204 human passes on Dallas, 113 bounced, and every bounce
 * (109 of 113; the other 4 had the two offers straddle a second boundary)
 * had that duplicate offer at the handoff. No pass without it bounced.
 *
 * A real second frustration needs the whole frustration bar, far longer than
 * one lottery, so a human-tank offer arriving within one lottery of the last
 * one is the duplicate. Block it. Offers for a freshly spawned tank carry
 * the tank BOT as tank_index and are never blocked.
 *
 * Every offer is logged to logs/tank_pass_fix.log so the fix can be checked
 * against real games. l4d_tank_pass_fix 0 keeps the logging and blocks
 * nothing.
 */

ConVar g_cvEnabled, g_cvLottery;
float g_fLastHumanOffer = -1000.0;
char g_sLog[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
	name = "Tank Pass Fix",
	author = "Malevolence",
	description = "Stops a passed tank being taken off its new owner by a duplicate lottery",
	version = PLUGIN_VERSION,
	url = "https://riversidepug.com"
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d_tank_pass_fix", "1", "1 = block a duplicate human-tank offer inside one lottery of the last, 0 = log only.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvLottery = FindConVar("director_tank_lottery_selection_time");
	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/tank_pass_fix.log");
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_fLastHumanOffer = -1000.0;
}

public void OnMapStart()
{
	g_fLastHumanOffer = -1000.0;
}

public Action L4D_OnTryOfferingTankBot(int tank_index, bool &enterStasis)
{
	bool human = tank_index > 0 && tank_index <= MaxClients && IsClientInGame(tank_index) && !IsFakeClient(tank_index);
	float now = GetGameTime();
	float since = now - g_fLastHumanOffer;
	float window = (g_cvLottery != null ? g_cvLottery.FloatValue : 3.0) + 1.5;

	if (!human)
	{
		LogToFileEx(g_sLog, "offer tank_index=%d (bot) stasis=%d t=%.2f", tank_index, enterStasis, now);
		return Plugin_Continue;
	}

	int frus = 100 - GetEntProp(tank_index, Prop_Send, "m_frustration");
	bool dup = since < window;
	bool block = dup && g_cvEnabled.BoolValue;

	LogToFileEx(g_sLog, "offer tank_index=%d \"%N\" frus_left=%d stasis=%d t=%.2f since_last=%.2f %s",
		tank_index, tank_index, frus, enterStasis, now, since,
		block ? "BLOCKED duplicate" : (dup ? "duplicate (log only)" : "allowed"));

	if (block)
		return Plugin_Handled;

	g_fLastHumanOffer = now;
	return Plugin_Continue;
}

public void L4D_OnReplaceTank(int tank, int newtank)
{
	char a[MAX_NAME_LENGTH] = "?", b[MAX_NAME_LENGTH] = "?";
	if (tank > 0 && tank <= MaxClients && IsClientInGame(tank)) GetClientName(tank, a, sizeof(a));
	if (newtank > 0 && newtank <= MaxClients && IsClientInGame(newtank)) GetClientName(newtank, b, sizeof(b));
	LogToFileEx(g_sLog, "replace %d \"%s\" -> %d \"%s\" t=%.2f", tank, a, newtank, b, GetGameTime());
}
