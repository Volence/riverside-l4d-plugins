/*
 * [L4D1] Remove Pipe Bombs
 *
 * WHY THIS EXISTS
 * ---------------
 * 4v4 Lite wants molotovs but no pipe bombs. Rotoblin's throwable control is a
 * single boolean -- rotoblin_enable_throwables is all-or-nothing across pipes
 * and mollys -- so there is no cfg way to split them.
 *
 * The obvious-looking lever, director_pipe_bomb_density 0, DOES NOT WORK. It was
 * tried live on 2026-08-19 and a pipe bomb still spawned. The reason is in
 * rotoblin.itemcontrol.sp:246: EnableOneThrowables() is an empty stub whose only
 * content is a comment saying "let cfg do it" and naming the density cvars. The
 * densities only govern spawns the DIRECTOR populates; the weapon_pipe_bomb_spawn
 * entities baked into the map by the level designer spawn their item regardless.
 * Note that Rotoblin's own remove-all-throwables path (RemoveThrowables(), line
 * 231) does not touch the densities either -- it deletes the entities. So does
 * this, just the pipe half of it.
 *
 * IMPLEMENTATION NOTES
 * --------------------
 * - Two passes, because neither alone is enough. A round_start sweep catches the
 *   map's own baked-in spawners; an OnEntityCreated hook catches anything created
 *   afterwards. Rotoblin needs both for the same reason (itemcontrol.sp:220, 335).
 * - Entities created this frame cannot be killed this frame, hence the 0.1s
 *   deferred timer on an entity REFERENCE (not an index -- indices get recycled).
 *   REMOVE_DELAY 0.1 is lifted straight from itemcontrol.sp:34.
 * - The round_start sweep also runs on a short delay. Map entities are not all
 *   present the instant the event fires; rotoblin.healthcontrol.sp:284 hedges the
 *   same way with a 0.25s timer.
 * - "Kill" defers actual deletion to the end of the frame, so iterating with
 *   FindEntityByClassname while killing is safe.
 *
 * CVAR
 *   l4d_remove_pipebombs  0   1 = strip pipe bombs from the map. 0 = off.
 *
 * Default 0 so the plugin is inert. cfg/Reloadables/server_custom_convars.cfg
 * pins it to 0 on every map in every mode and rotoblin_lite_4v4_map.cfg turns it
 * on, because cvars persist across config loads and would otherwise follow you
 * into the next mode -- 4v4 Classic and Pub want their pipes.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION  "1.0-2026/8/19"
#define REMOVE_DELAY    0.1     // rotoblin.itemcontrol.sp:34
#define SWEEP_DELAY     0.5

ConVar g_hCvarEnable;
bool   g_bEnable;

public Plugin myinfo =
{
	name        = "[L4D1] Remove Pipe Bombs",
	author      = "volence",
	description = "Strips pipe bombs while leaving molotovs alone, which Rotoblin's all-or-nothing throwable cvar cannot do",
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
	CreateConVar("l4d_remove_pipebombs_version", PLUGIN_VERSION, "Remove Pipe Bombs version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_hCvarEnable = CreateConVar("l4d_remove_pipebombs", "0",
		"Strip pipe bombs from the map, leaving molotovs alone. [0-Off, 1-On]",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	GetCvars();
	g_hCvarEnable.AddChangeHook(ConVarChanged_Cvars);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

void GetCvars()
{
	g_bEnable = g_hCvarEnable.BoolValue;
}

public void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();

	// Turned on mid-map (an admin loading the Lite config without a map change):
	// clear whatever is already lying around rather than waiting for next round.
	if (g_bEnable)
	{
		SweepPipeBombs();
	}
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bEnable)
	{
		return;
	}

	SweepPipeBombs();
	CreateTimer(SWEEP_DELAY, Timer_Sweep, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_Sweep(Handle timer)
{
	SweepPipeBombs();

	return Plugin_Stop;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_bEnable || entity < 0)
	{
		return;
	}

	if (!IsPipeBomb(classname))
	{
		return;
	}

	// Cannot kill an entity on the frame it is created.
	CreateTimer(REMOVE_DELAY, Timer_RemoveEntity, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_RemoveEntity(Handle timer, any entRef)
{
	int entity = EntRefToEntIndex(entRef);

	if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
	{
		AcceptEntityInput(entity, "Kill");
	}

	return Plugin_Stop;
}

void SweepPipeBombs()
{
	RemoveAllByClassname("weapon_pipe_bomb_spawn");   // the map's baked-in spawner
	RemoveAllByClassname("weapon_pipe_bomb");         // a live pipe already on the ground
}

void RemoveAllByClassname(const char[] classname)
{
	int entity = -1;

	// "Kill" defers deletion to end of frame, so the iteration stays valid.
	while ((entity = FindEntityByClassname(entity, classname)) != -1)
	{
		if (IsValidEntity(entity))
		{
			AcceptEntityInput(entity, "Kill");
		}
	}
}

bool IsPipeBomb(const char[] classname)
{
	return (StrEqual(classname, "weapon_pipe_bomb_spawn", false)
		 || StrEqual(classname, "weapon_pipe_bomb", false));
}
