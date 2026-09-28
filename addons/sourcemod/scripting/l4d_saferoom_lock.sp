#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.2"

#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3

// SF_DOOR_IGNORE_USE. CBasePropDoor::ObjectCaps and CBasePropDoor::Use both
// read this bit live, so setting it after spawn stops a player's USE on the
// spot. The door's Lock input (m_bLocked) is a different mechanism, not used.
#define SF_DOOR_IGNORE_USE	32768

// m_eDoorState
#define DOOR_STATE_CLOSED	0
#define DOOR_STATE_OPENING	1
#define DOOR_STATE_OPEN		2
#define DOOR_STATE_CLOSING	3

// l4d_saferoom_lock_door_state
#define HOLD_OPEN			0
#define HOLD_CLOSED			1

#define SOUND_LOCK			"doors/default_locked.wav"

// How often the boss check runs. Also the worst case delay before the door
// locks behind a tank that just spawned; kills unlock the door immediately
// through the death events below, so the wait is never felt on the way out.
#define CHECK_INTERVAL		1.0

// A tank that vanishes without dying still holds the door this long. Passing
// the tank to another player can leave a moment with no live tank, and a team
// already inside must not get to close the door in that gap.
#define TANK_GRACE			3.0
// A tank_frustrated pass is treated as in progress this long, so a death that
// belongs to the pass does not count as the tank being killed.
#define TANK_PASS_WINDOW	5.0

ConVar g_hCvarEnable, g_hCvarTank, g_hCvarWitch, g_hCvarForceOpen, g_hCvarDoorState;
bool g_bCvarEnable, g_bCvarTank, g_bCvarWitch;
int g_iCvarForceOpen, g_iCvarDoorState;

bool g_bHooked;
int g_iZombieClassTank;

int g_iDoor;			// entity reference of the end saferoom door, 0 when unknown
int g_iDoorFlags;		// the door's own spawnflags, as found
bool g_bDoorLocked;		// true while we are holding the door shut
bool g_bGaveUp;			// force open time elapsed, stay unlocked for the rest of the round
int g_iRoundSeconds;
float g_fLastUse[MAXPLAYERS + 1];
int g_iRoundStart, g_iPlayerSpawn;
Handle g_hCheckTimer;
float g_fTankGraceUntil;	// game time until which a vanished tank still counts as alive
float g_fTankPassUntil;		// game time until which a tank pass is in progress

public Plugin myinfo =
{
	name = "[L4D1/2] Saferoom Boss Lock",
	author = "Riverside",
	description = "Keeps the end saferoom door locked while a tank or a witch is still alive.",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();

	if( test == Engine_Left4Dead )
	{
		g_iZombieClassTank = 5;
	}
	else if( test == Engine_Left4Dead2 )
	{
		g_iZombieClassTank = 8;
	}
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hCvarEnable		= CreateConVar("l4d_saferoom_lock", "1",
							"Keep the end saferoom door locked while a boss is alive. [0-Disable,1-Enable]",
							FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarTank			= CreateConVar("l4d_saferoom_lock_tank", "1",
							"A live tank locks the end saferoom door. [0-Disable,1-Enable]",
							FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarWitch		= CreateConVar("l4d_saferoom_lock_witch", "1",
							"A live witch locks the end saferoom door. [0-Disable,1-Enable]",
							FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarForceOpen	= CreateConVar("l4d_saferoom_lock_force_open", "0",
							"Unlock the door anyway this many seconds into the round, even if a boss is alive. (0=never)",
							FCVAR_NOTIFY, true, 0.0);
	g_hCvarDoorState	= CreateConVar("l4d_saferoom_lock_door_state", "0",
							"Where the door is held while a boss is alive. [0-Open, cannot be closed. 1-Closed, cannot be opened; left open if a survivor is already inside]",
							FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvarEnable.AddChangeHook(ConVarChanged_Allowed);
	g_hCvarTank.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarWitch.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarForceOpen.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarDoorState.AddChangeHook(ConVarChanged_Cvars);

	IsAllowed();
}

public void OnConfigsExecuted()
{
	IsAllowed();
}

public void OnMapStart()
{
	PrecacheSound(SOUND_LOCK);
}

public void OnMapEnd()
{
	ResetRound();
}

public void OnPluginEnd()
{
	ResetRound();
}

void GetCvars()
{
	g_bCvarTank = g_hCvarTank.BoolValue;
	g_bCvarWitch = g_hCvarWitch.BoolValue;
	g_iCvarForceOpen = g_hCvarForceOpen.IntValue;
	g_iCvarDoorState = g_hCvarDoorState.IntValue;
}

public void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

public void ConVarChanged_Allowed(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsAllowed();
}

void IsAllowed()
{
	GetCvars();
	bool bAllow = g_hCvarEnable.BoolValue;

	if( !g_bCvarEnable && bAllow )
	{
		g_bCvarEnable = true;
		HookEvents();
		// Round start already went by if the cvar was flipped on mid round, or
		// if the plugin was loaded late, so start checking right away instead
		// of sitting idle until the next round.
		StartChecking();
	}
	else if( g_bCvarEnable && !bAllow )
	{
		g_bCvarEnable = false;
		UnHookEvents();
		ResetRound();
	}
}

void HookEvents()
{
	if( g_bHooked ) return;
	g_bHooked = true;

	HookEvent("round_start",	Event_RoundStart);
	HookEvent("player_spawn",	Event_PlayerSpawn,	EventHookMode_PostNoCopy);
	HookEvent("player_death",	Event_PlayerDeath);
	HookEvent("tank_frustrated",	Event_TankFrustrated,	EventHookMode_PostNoCopy);
	HookEvent("witch_killed",	Event_BossDeath,	EventHookMode_PostNoCopy);
	HookEvent("round_end",		Event_RoundEnd);
	HookEvent("map_transition",	Event_RoundEnd);
	HookEvent("mission_lost",	Event_RoundEnd);
	HookEvent("finale_win",		Event_RoundEnd,		EventHookMode_PostNoCopy);
}

void UnHookEvents()
{
	if( !g_bHooked ) return;
	g_bHooked = false;

	UnhookEvent("round_start",		Event_RoundStart);
	UnhookEvent("player_spawn",		Event_PlayerSpawn,	EventHookMode_PostNoCopy);
	UnhookEvent("player_death",		Event_PlayerDeath);
	UnhookEvent("tank_frustrated",	Event_TankFrustrated,	EventHookMode_PostNoCopy);
	UnhookEvent("witch_killed",		Event_BossDeath,	EventHookMode_PostNoCopy);
	UnhookEvent("round_end",		Event_RoundEnd);
	UnhookEvent("map_transition",	Event_RoundEnd);
	UnhookEvent("mission_lost",		Event_RoundEnd);
	UnhookEvent("finale_win",		Event_RoundEnd,		EventHookMode_PostNoCopy);
}

// ---------------------------------------------------------------------------
// Round lifecycle
// ---------------------------------------------------------------------------

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();

	if( g_iPlayerSpawn == 1 && g_iRoundStart == 0 )
		StartChecking();
	g_iRoundStart = 1;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if( g_iPlayerSpawn == 0 && g_iRoundStart == 1 )
		StartChecking();
	g_iPlayerSpawn = 1;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

// A tank that really died drops its grace at once, so the kill unlocks the
// door right away. A death during a tank pass keeps the grace.
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if( client < 1 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED ) return;
	if( GetEntProp(client, Prop_Send, "m_zombieClass") != g_iZombieClassTank ) return;

	if( GetGameTime() >= g_fTankPassUntil )
		g_fTankGraceUntil = 0.0;

	Event_BossDeath(event, name, dontBroadcast);
}

public void Event_TankFrustrated(Event event, const char[] name, bool dontBroadcast)
{
	g_fTankPassUntil = GetGameTime() + TANK_PASS_WINDOW;
	g_fTankGraceUntil = GetGameTime() + TANK_GRACE;
}

// A tank or witch dying reopens the way out without waiting for the next tick.
public void Event_BossDeath(Event event, const char[] name, bool dontBroadcast)
{
	if( !g_bCvarEnable || !g_bDoorLocked ) return;

	// The dead boss is still a valid entity inside its own death event, so
	// look again on the next frame instead of counting the corpse.
	RequestFrame(Frame_RecheckDoor);
}

public void Frame_RecheckDoor()
{
	UpdateDoor();
}

void StartChecking()
{
	delete g_hCheckTimer;
	g_hCheckTimer = CreateTimer(CHECK_INTERVAL, Timer_Check, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void ResetRound()
{
	delete g_hCheckTimer;

	UnlockDoor();

	g_iDoor = 0;
	g_iDoorFlags = 0;
	g_bDoorLocked = false;
	g_bGaveUp = false;
	g_iRoundSeconds = 0;
	g_fTankGraceUntil = 0.0;
	g_fTankPassUntil = 0.0;
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;

	for( int i = 0; i <= MaxClients; i++ )
		g_fLastUse[i] = 0.0;
}

public Action Timer_Check(Handle timer)
{
	if( !g_bCvarEnable )
	{
		UnlockDoor();
		g_hCheckTimer = null;
		return Plugin_Stop;
	}

	g_iRoundSeconds += RoundToNearest(CHECK_INTERVAL);

	if( !g_bGaveUp && g_iCvarForceOpen > 0 && g_iRoundSeconds >= g_iCvarForceOpen )
	{
		g_bGaveUp = true;
		UnlockDoor();
	}

	UpdateDoor();

	return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Door state
// ---------------------------------------------------------------------------

void UpdateDoor()
{
	if( !g_bCvarEnable || g_bGaveUp ) return;

	int door = GetSaferoomDoor();
	if( door == -1 )
	{
		// The door went away, or this map has no end saferoom (finales).
		g_bDoorLocked = false;
		return;
	}

	bool bBoss = IsBossAlive();

	if( bBoss && !g_bDoorLocked )
	{
		LockDoor();
	}
	else if( !bBoss && g_bDoorLocked )
	{
		UnlockDoor();
	}

	if( g_bDoorLocked )
		HoldDoor(door);
}

// Keeps the locked door where the door_state cvar wants it. Inputs are not
// blocked by the ignore use flag, so this still moves a locked door. Runs on
// every check, so a door that bounced off a player gets pushed again.
void HoldDoor(int door)
{
	int state = GetEntProp(door, Prop_Data, "m_eDoorState");

	if( g_iCvarDoorState == HOLD_OPEN )
	{
		if( state == DOOR_STATE_CLOSED || state == DOOR_STATE_CLOSING )
			AcceptEntityInput(door, "Open");
	}
	else if( state == DOOR_STATE_OPEN || state == DOOR_STATE_OPENING )
	{
		// Closing the door on a team that is already inside would seal the
		// checkpoint and could end the round, so leave it open until they walk out.
		if( !IsSurvivorInSaferoom() )
			AcceptEntityInput(door, "Close");
	}
}

bool IsSurvivorInSaferoom()
{
	for( int i = 1; i <= MaxClients; i++ )
	{
		if( !IsClientInGame(i) ) continue;
		if( GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i) ) continue;
		if( L4D_IsInLastCheckpoint(i) ) return true;
	}

	return false;
}

// Finds the end saferoom door, caching it for the round. Returns -1 when the
// map has none yet, so a late spawning door is picked up on a later tick.
int GetSaferoomDoor()
{
	if( g_iDoor != 0 )
	{
		int cached = EntRefToEntIndex(g_iDoor);
		if( cached != INVALID_ENT_REFERENCE && IsValidEntity(cached) )
			return cached;

		// Door is gone: drop the cache and stop pretending we hold it shut.
		g_iDoor = 0;
		g_iDoorFlags = 0;
		g_bDoorLocked = false;
	}

	int door = L4D_GetCheckpointLast();
	if( door <= 0 || !IsValidEntity(door) )
		return -1;

	g_iDoor = EntIndexToEntRef(door);
	// Keep the door's own flags rather than a hardcoded value, so a custom map
	// with an unusual saferoom door gets its exact flags back on unlock.
	g_iDoorFlags = GetEntProp(door, Prop_Data, "m_spawnflags") & ~SF_DOOR_IGNORE_USE;

	return door;
}

void LockDoor()
{
	int door = EntRefToEntIndex(g_iDoor);
	if( door == INVALID_ENT_REFERENCE || !IsValidEntity(door) ) return;

	SetDoorFlags(door, g_iDoorFlags | SF_DOOR_IGNORE_USE);
	g_bDoorLocked = true;
}

void UnlockDoor()
{
	if( !g_bDoorLocked ) return;
	g_bDoorLocked = false;

	int door = EntRefToEntIndex(g_iDoor);
	if( door == INVALID_ENT_REFERENCE || !IsValidEntity(door) ) return;

	SetDoorFlags(door, g_iDoorFlags);
}

void SetDoorFlags(int door, int flags)
{
	char sFlags[16];
	IntToString(flags, sFlags, sizeof(sFlags));
	DispatchKeyValue(door, "spawnflags", sFlags);
}

// ---------------------------------------------------------------------------
// Boss detection
// ---------------------------------------------------------------------------

bool IsBossAlive()
{
	return (g_bCvarTank && IsTankAlive()) || (g_bCvarWitch && IsWitchAlive());
}

// Every tank is a client in both games, AI tanks included, so a client scan
// covers them all. A versus tank that is still a ghost waiting to spawn is
// not on the field yet and does not hold the door. A tank that just vanished
// without dying still counts for TANK_GRACE seconds.
bool IsTankAlive()
{
	if( FindLiveTank() )
	{
		g_fTankGraceUntil = GetGameTime() + TANK_GRACE;
		return true;
	}

	return GetGameTime() < g_fTankGraceUntil;
}

bool FindLiveTank()
{
	for( int i = 1; i <= MaxClients; i++ )
	{
		if( !IsClientInGame(i) ) continue;
		if( GetClientTeam(i) != TEAM_INFECTED ) continue;
		if( !IsPlayerAlive(i) ) continue;
		if( GetEntProp(i, Prop_Send, "m_isGhost") ) continue;
		if( GetEntProp(i, Prop_Send, "m_zombieClass") != g_iZombieClassTank ) continue;

		return true;
	}

	return false;
}

bool IsWitchAlive()
{
	int entity = -1;
	while( (entity = FindEntityByClassname(entity, "witch")) != INVALID_ENT_REFERENCE )
	{
		// A witch entity with no health is not a live witch. The director can
		// leave one of these at the map origin (seen on a coop test server), and
		// counting it would hold the door shut for the whole round.
		if( IsValidEntity(entity) && GetEntProp(entity, Prop_Data, "m_iHealth") > 0 )
			return true;
	}

	return false;
}

// ---------------------------------------------------------------------------
// Player feedback
// ---------------------------------------------------------------------------

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if( !g_bCvarEnable || !g_bDoorLocked ) return Plugin_Continue;
	if( !(buttons & IN_USE) ) return Plugin_Continue;
	if( client < 1 || client > MaxClients || !IsClientInGame(client) ) return Plugin_Continue;
	if( GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client) ) return Plugin_Continue;
	if( GetGameTime() < g_fLastUse[client] ) return Plugin_Continue;

	int door = EntRefToEntIndex(g_iDoor);
	if( door == INVALID_ENT_REFERENCE ) return Plugin_Continue;
	if( GetClientAimTarget(client, false) != door ) return Plugin_Continue;

	g_fLastUse[client] = GetGameTime() + 1.0;	// avoid spamming sound and hints

	bool bTank = g_bCvarTank && IsTankAlive();
	bool bWitch = g_bCvarWitch && IsWitchAlive();

	char sLocked[48];
	if( g_iCvarDoorState == HOLD_OPEN )
		strcopy(sLocked, sizeof(sLocked), "The saferoom door can't be closed.");
	else
		strcopy(sLocked, sizeof(sLocked), "The saferoom is locked.");

	if( bTank && bWitch )
		PrintHintText(client, "%s\nThe Tank and the Witch are still alive.", sLocked);
	else if( bTank )
		PrintHintText(client, "%s\nThe Tank is still alive.", sLocked);
	else if( bWitch )
		PrintHintText(client, "%s\nThe Witch is still alive.", sLocked);
	else
		PrintHintText(client, "%s", sLocked);

	EmitSoundToAll(SOUND_LOCK, door, SNDCHAN_AUTO, SNDLEVEL_AIRCRAFT, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL, -1, NULL_VECTOR, NULL_VECTOR, true, 0.0);

	return Plugin_Continue;
}
