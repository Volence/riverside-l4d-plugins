/*
 * l4d_hltv_addon_guard: survivors' holstered-weapon models are switched off while a SourceTV spectator loads in.
 *
 * A stock L4D1 client watching SourceTV can crash to desktop at client.dll+0x1EE8AF, C_AddonProp::ComputeStencilState
 * (the model of a weapon a survivor carries but is not holding, e.g. the shotgun on the back). The prop is
 * client-only; C_HLTVCamera::FixupMovmentParents resets every entity's move parent to its networked one after each
 * packet, so on an HLTV client the prop's owner handle becomes -1. ShouldDraw checks for that, but the fast-path model
 * renderer still calls ComputeStencilState on a prop already in its list, which dereferences the NULL owner.
 * It shows as a crash on joining (or reconnecting to) a game already in progress, usually on the 4th map; the
 * spectator's first snapshot is the dangerous moment. Seen in sourcetv_sessions on every box since 2026-09-25.
 *
 * The client builds these props from the networked m_iAddonBits, which CCSPlayer::PostThink recomputes every frame
 * (CTerrorPlayer::UpdateAddonBits). While the guard is on, PostThinkPost writes 0 over it, so no client creates
 * the props; when it ends the real bits are back on the next frame. Players lose the holstered models only while
 * the guard is on:
 *   - from map start until the survivors leave the saferoom (ready-up, not live play). Spectators carried over
 *     reload the map with everyone else, and SourceTV does not count them while it changes level, so every map
 *     start is guarded;
 *   - for l4d_hltv_addon_guard_join_secs after a SourceTV spectator connects.
 *
 * 1.1: SourceTV camera unfreeze. An intro point_viewcontrol_multiplayer (hospital01, farm01, smalltown01, ...)
 * freezes every player in game, the SourceTV bot included, and points their view at the camera. When it ends,
 * CTriggerCameraMultiplayer::Disable/RemovePlayer give control back only to living players; the SourceTV bot is
 * always dead (team 1, lifeState 2), so it keeps FL_FROZEN. A SourceTV viewer's local player is that bot, and
 * C_BasePlayer::CreateMove (L4D1 client.dll 0x100602ee) puts back the old view angles every frame while the local
 * player is frozen, so mouse look is dead for every viewer. Match 1189 (hospital01, 2026-11-15): frozen for all of
 * both halves. A short timer clears FL_FROZEN and the camera view handle on the SourceTV bot; the bot never
 * moves, so nothing in the game changes. l4d_hltv_addon_guard_unfreeze 0 turns it off.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION	"1.1"

public Plugin myinfo =
{
	name = "[L4D] SourceTV addon guard",
	author = "Malevolence",
	description = "Holstered-weapon models off while a SourceTV spectator loads in, so a stock client cannot crash in C_AddonProp",
	version = PLUGIN_VERSION,
	url = ""
};

ConVar g_cvJoinSecs;
ConVar g_cvUnfreeze;
bool g_bUntilLeftStart;		// map-start guard, cleared when the survivors leave the saferoom
float g_fUntil;				// join guard, GetEngineTime() deadline
bool g_bLate;				// loaded mid-map: the saferoom may already be behind us, so no map-start guard

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("l4d_hltv_addon_guard_version", PLUGIN_VERSION, "l4d_hltv_addon_guard version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvJoinSecs = CreateConVar("l4d_hltv_addon_guard_join_secs", "45", "Seconds the holstered-weapon models stay off after a SourceTV spectator connects", _, true, 0.0);
	g_cvUnfreeze = CreateConVar("l4d_hltv_addon_guard_unfreeze", "1", "Clear the intro camera's freeze and view on the SourceTV bot, so SourceTV viewers keep mouse look", _, true, 0.0, true, 1.0);
	CreateTimer(0.25, Timer_Unfreeze, _, TIMER_REPEAT);
	HookEvent("player_left_start_area", Event_LeftStartArea, EventHookMode_PostNoCopy);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i)) OnClientPutInServer(i);
	}
}

public void OnMapStart()
{
	g_bUntilLeftStart = !g_bLate;
	g_bLate = false;
	g_fUntil = 0.0;
	if (g_bUntilLeftStart) LogMessage("HLTVADDON guard on: map start, until the survivors leave the saferoom");
}

void Event_LeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
	LeftStart();
}

// Left 4 DHooks' own saferoom detection, in case the event does not fire.
public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
	LeftStart();
}

void LeftStart()
{
	if (g_bUntilLeftStart) LogMessage("HLTVADDON guard off: survivors left the saferoom");
	g_bUntilLeftStart = false;
}

public void SourceTV_OnSpectatorConnected(int client)
{
	g_fUntil = GetEngineTime() + g_cvJoinSecs.FloatValue;
	LogMessage("HLTVADDON guard on: SourceTV spectator connected, %.0f s", g_cvJoinSecs.FloatValue);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
}

void OnPostThinkPost(int client)
{
	if ((g_bUntilLeftStart || GetEngineTime() < g_fUntil) && GetEntProp(client, Prop_Send, "m_iAddonBits") != 0)
	{
		SetEntProp(client, Prop_Send, "m_iAddonBits", 0);
	}
}

// Runs across map changes (no TIMER_FLAG_NO_MAPCHANGE); a cheap check of one client.
Action Timer_Unfreeze(Handle timer)
{
	if (!g_cvUnfreeze.BoolValue) return Plugin_Continue;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsClientSourceTV(i)) continue;
		int flags = GetEntityFlags(i);
		int view = GetEntPropEnt(i, Prop_Send, "m_hViewEntity");
		if (!(flags & FL_FROZEN) && (view == -1 || view == i)) continue;
		if (flags & FL_FROZEN) SetEntityFlags(i, flags & ~FL_FROZEN);
		// SetClientViewEntity only moves the engine's view; the networked handle needs a direct write.
		if (view != -1 && view != i) SetEntPropEnt(i, Prop_Send, "m_hViewEntity", -1);
		LogMessage("HLTVUNFREEZE cleared SourceTV bot: frozen %d, view entity %d", (flags & FL_FROZEN) ? 1 : 0, view);
	}
	return Plugin_Continue;
}
