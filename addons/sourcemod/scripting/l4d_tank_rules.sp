#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.2"

#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3
#define ZC_TANK				5	// L4D1 m_zombieClass of the tank

// How often the tank check runs. Spawns and deaths also recheck on the next
// frame, so this only bounds how late a missed transition is noticed.
#define CHECK_INTERVAL		0.25
// Same windows as l4d_saferoom_lock: a tank that vanishes without dying still
// counts this long, and a tank_frustrated pass is in progress this long.
#define TANK_GRACE			3.0
#define TANK_PASS_WINDOW	5.0
// WeaponCanUse fires every tick while E is held on a gun.
#define HINT_COOLDOWN		3.0

// ForEachTerrorPlayer<CalcAndSetVersusMaxFlowDistance>+0xd0 is "jbe keep
// stored", taken when a survivor's current flow is not past their stored
// furthest flow. As an unconditional jmp the stored value is always kept, so
// every survivor's distance freezes. The spec has the disassembly.
#define BYTE_KEEP_IF_BEHIND	0x76	// jbe rel8
#define BYTE_ALWAYS_KEEP	0xEB	// jmp rel8

// l4d_tank_rules_weapons
#define SWAP_OFF			0
#define SWAP_LOCK			1
#define SWAP_ONE			2
#define SWAP_EMPTY			3

ConVar g_hCvarRush, g_hCvarWeapons;

Address g_pPatch = Address_Null;	// patch site, Address_Null when not found
bool g_bRoundLive;					// between round_start and round_end
bool g_bTankAlive;
float g_fTankGraceUntil;			// game time until which a vanished tank still counts
float g_fTankPassUntil;				// game time until which a tank pass is in progress
int g_iSwapUser;					// userid that used this tank's one swap, 0 = unused
int g_iNotices;						// freeze notices printed, for sm_tankrules_status
char g_sPendingSwap[MAXPLAYERS + 1][32];	// class a mode 2 swap was allowed for, until it is equipped
char g_sPendingEmpty[MAXPLAYERS + 1][32];	// class a mode 3 pickup was allowed for, until it is equipped
float g_fLastHint[MAXPLAYERS + 1];

static const char g_sPrimaries[][] =
{
	"weapon_smg", "weapon_pumpshotgun", "weapon_rifle", "weapon_autoshotgun", "weapon_hunting_rifle"
};

public Plugin myinfo =
{
	name = "[L4D1] Tank Rules",
	author = "Riverside",
	description = "While a tank is alive: survivor distance points are frozen, and primary swaps can be limited or cost a reload.",
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
	g_hCvarRush		= CreateConVar("l4d_tank_rules_rush", "1",
						"Freeze survivor distance points while a tank is alive. [0-Off,1-On]",
						FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarWeapons	= CreateConVar("l4d_tank_rules_weapons", "0",
						"Primary swaps while a tank is alive. [0-Allowed,1-Nobody may swap to a different primary,2-Only one survivor may, once per tank,3-Allowed but the new gun starts with an empty clip]",
						FCVAR_NOTIFY, true, 0.0, true, 3.0);

	RegAdminCmd("sm_tankrules_status", Cmd_Status, ADMFLAG_GENERIC, "Print l4d_tank_rules state.");

	g_hCvarRush.AddChangeHook(ConVarChanged_Rush);

	HookEvent("round_start",		Event_RoundStart,		EventHookMode_PostNoCopy);
	HookEvent("round_end",			Event_RoundEnd,			EventHookMode_PostNoCopy);
	HookEvent("map_transition",		Event_RoundEnd,			EventHookMode_PostNoCopy);
	HookEvent("mission_lost",		Event_RoundEnd,			EventHookMode_PostNoCopy);
	HookEvent("finale_win",			Event_RoundEnd,			EventHookMode_PostNoCopy);
	HookEvent("tank_spawn",			Event_TankSpawn,		EventHookMode_PostNoCopy);
	HookEvent("player_death",		Event_PlayerDeath);
	HookEvent("tank_frustrated",	Event_TankFrustrated,	EventHookMode_PostNoCopy);

	FindPatchSite();

	// Loaded mid round (late load, or a reload): the round is already running.
	g_bRoundLive = true;

	UpdateTank();
	CreateTimer(CHECK_INTERVAL, Timer_Check, _, TIMER_REPEAT);

	for( int i = 1; i <= MaxClients; i++ )
		if( IsClientInGame(i) ) OnClientPutInServer(i);
}

public void OnPluginEnd()
{
	SetFrozen(false);
}

public void OnMapEnd()
{
	g_bRoundLive = false;
	ResetTankState();
	SetFrozen(false);
}

// ---------------------------------------------------------------------------
// Patch site
// ---------------------------------------------------------------------------

void FindPatchSite()
{
	GameData gd = new GameData("l4d_tank_rules");
	if( gd == null )
	{
		LogError("Missing gamedata l4d_tank_rules.txt; no-rush is off.");
		return;
	}

	Address fn = gd.GetAddress("CalcAndSetVersusMaxFlowDistance");
	int offset = gd.GetOffset("keep_stored_jbe");
	delete gd;

	if( fn == Address_Null || offset == -1 )
	{
		LogError("Could not find ForEachTerrorPlayer<CalcAndSetVersusMaxFlowDistance>; no-rush is off.");
		return;
	}

	Address site = fn + view_as<Address>(offset);
	int b = LoadFromAddress(site, NumberType_Int8) & 0xFF;

	// A copy of this plugin that died without OnPluginEnd can leave the jmp
	// behind. Nothing else writes this byte, so take it back either way. The
	// rest of the site must match too: an unrelated EB elsewhere must never be
	// turned into a jbe.
	if( (b != BYTE_KEEP_IF_BEHIND && b != BYTE_ALWAYS_KEEP) || !SiteContextMatches(site) )
	{
		LogError("Unexpected bytes at CalcAndSetVersusMaxFlowDistance+%d (0x%02X); engine build differs, no-rush is off.", b, offset);
		return;
	}

	g_pPatch = site;
	WriteSite(BYTE_KEEP_IF_BEHIND);
	LogMessage("No-rush patch site found at CalcAndSetVersusMaxFlowDistance+%d.", offset);
}

// The jump's rel8 (0x20, to the keep-stored path) and, 12 bytes on, the store
// it skips: fsts 0x2b74(%ebp), d9 95 74 2b 00 00.
bool SiteContextMatches(Address site)
{
	static const int context[] = { 0xD9, 0x95, 0x74, 0x2B, 0x00, 0x00 };

	if( (LoadFromAddress(site + view_as<Address>(1), NumberType_Int8) & 0xFF) != 0x20 ) return false;

	for( int i = 0; i < sizeof(context); i++ )
	{
		if( (LoadFromAddress(site + view_as<Address>(12 + i), NumberType_Int8) & 0xFF) != context[i] ) return false;
	}

	return true;
}

int ReadSite()
{
	if( g_pPatch == Address_Null ) return -1;
	return LoadFromAddress(g_pPatch, NumberType_Int8) & 0xFF;
}

void WriteSite(int value)
{
	if( g_pPatch == Address_Null ) return;
	if( ReadSite() == value ) return;
	StoreToAddress(g_pPatch, value, NumberType_Int8);
}

void SetFrozen(bool frozen)
{
	WriteSite(frozen ? BYTE_ALWAYS_KEEP : BYTE_KEEP_IF_BEHIND);
}

public void ConVarChanged_Rush(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyFreeze();
}

// Frozen while a tank lives in a live round and the rule is on.
void ApplyFreeze()
{
	if( !g_hCvarRush.BoolValue )
	{
		SetFrozen(false);
		return;
	}

	// From round end to the next round start the byte stays as it was. Incapped
	// survivors count as alive to the engine, so one lying past the frozen mark
	// would be paid for it by a score recompute after an unfreeze here.
	if( !g_bRoundLive ) return;

	if( g_bTankAlive )
	{
		SetFrozen(true);
		return;
	}

	// The tank is gone but nobody is standing: the round is being lost, and
	// until round_end the engine still pays incapped survivors their current
	// flow. Keep the freeze until someone stands up or the next round starts.
	if( !IsSurvivorStanding() ) return;

	SetFrozen(false);
}

bool IsSurvivorStanding()
{
	for( int i = 1; i <= MaxClients; i++ )
	{
		if( !IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i) ) continue;
		if( GetEntProp(i, Prop_Send, "m_isIncapacitated") ) continue;
		if( GetEntProp(i, Prop_Send, "m_isHangingFromLedge") ) continue;
		return true;
	}

	return false;
}

// ---------------------------------------------------------------------------
// Tank tracking (from l4d_saferoom_lock 1.2)
// ---------------------------------------------------------------------------

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundLive = true;
	ResetTankState();
	// Survivors may not be standing yet, which ApplyFreeze reads as a wipe in
	// progress; a new round always starts unfrozen.
	SetFrozen(false);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundLive = false;
	ResetTankState();
}

void ResetTankState()
{
	g_bTankAlive = false;
	g_fTankGraceUntil = 0.0;
	g_fTankPassUntil = 0.0;
	g_iSwapUser = 0;
	for( int i = 0; i <= MaxClients; i++ )
	{
		g_sPendingSwap[i][0] = '\0';
		// Game time restarts with the map, so an old stamp could mute hints.
		g_fLastHint[i] = 0.0;
	}
	ApplyFreeze();
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	RequestFrame(Frame_UpdateTank);
}

// A tank that really died drops its grace at once. A death during a tank pass
// keeps it, so the pass is not a kill.
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if( client < 1 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED ) return;
	if( GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_TANK ) return;

	if( GetGameTime() >= g_fTankPassUntil )
		g_fTankGraceUntil = 0.0;

	// The dead tank is still a live client inside its own death event.
	RequestFrame(Frame_UpdateTank);
}

public void Event_TankFrustrated(Event event, const char[] name, bool dontBroadcast)
{
	g_fTankPassUntil = GetGameTime() + TANK_PASS_WINDOW;
	g_fTankGraceUntil = GetGameTime() + TANK_GRACE;
}

public void Frame_UpdateTank()
{
	UpdateTank();
}

public Action Timer_Check(Handle timer)
{
	UpdateTank();
	return Plugin_Continue;
}

void UpdateTank()
{
	bool alive = g_bRoundLive && IsTankAlive();

	if( alive && !g_bTankAlive )
	{
		// A new tank fight gets a fresh swap and one notice. A pass never gets
		// here: the grace keeps the old tank alive across it.
		g_iSwapUser = 0;
		if( g_hCvarRush.BoolValue && g_pPatch != Address_Null )
		{
			// !cur keeps counting live flow while the score holds, so say why.
			PrintToChatAll("\x04[Tank]\x01 Survivor distance points are frozen until the tank dies.");
			g_iNotices++;
		}
		for( int i = 0; i <= MaxClients; i++ )
			g_sPendingSwap[i][0] = '\0';
	}

	g_bTankAlive = alive;
	ApplyFreeze();
}

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
		if( GetEntProp(i, Prop_Send, "m_zombieClass") != ZC_TANK ) continue;

		return true;
	}

	return false;
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

public Action Cmd_Status(int client, int args)
{
	int b = ReadSite();
	ReplyToCommand(client, "[tank_rules] site=%s byte=0x%02X rush=%d weapons=%d round_live=%d tank_alive=%d swap_user=%d distance=%d notices=%d",
		g_pPatch == Address_Null ? "missing" : "ok", b < 0 ? 0 : b,
		g_hCvarRush.IntValue, g_hCvarWeapons.IntValue,
		g_bRoundLive, g_bTankAlive, g_iSwapUser,
		GameRules_GetProp("m_iVersusDistance"), g_iNotices);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Primary swap limit
// ---------------------------------------------------------------------------

public void OnClientPutInServer(int client)
{
	g_sPendingSwap[client][0] = '\0';
	g_sPendingEmpty[client][0] = '\0';
	g_fLastHint[client] = 0.0;
	SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
	SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
}

bool IsPrimary(const char[] cls)
{
	for( int i = 0; i < sizeof(g_sPrimaries); i++ )
		if( StrEqual(cls, g_sPrimaries[i]) ) return true;
	return false;
}

public Action OnWeaponCanUse(int client, int weapon)
{
	int mode = g_hCvarWeapons.IntValue;
	if( mode == SWAP_OFF || !g_bTankAlive ) return Plugin_Continue;
	if( client < 1 || client > MaxClients || !IsClientInGame(client) ) return Plugin_Continue;
	if( GetClientTeam(client) != TEAM_SURVIVOR ) return Plugin_Continue;
	if( weapon <= MaxClients || !IsValidEntity(weapon) ) return Plugin_Continue;

	char cls[32];
	GetEntityClassname(weapon, cls, sizeof(cls));
	if( !IsPrimary(cls) ) return Plugin_Continue;

	int held = GetPlayerWeaponSlot(client, 0);

	// The same gun is an ammo top up, which other plugins own.
	if( held != -1 )
	{
		char heldCls[32];
		GetEntityClassname(held, heldCls, sizeof(heldCls));
		if( StrEqual(cls, heldCls) ) return Plugin_Continue;
	}

	// Any other primary, empty handed included, comes up with an empty clip.
	// Emptied once it is really equipped, like the mode 2 count.
	if( mode == SWAP_EMPTY )
	{
		strcopy(g_sPendingEmpty[client], sizeof(g_sPendingEmpty[]), cls);
		return Plugin_Continue;
	}

	// Empty handed: take anything, and from then on that is the gun.
	if( held == -1 ) return Plugin_Continue;

	if( mode == SWAP_ONE && g_iSwapUser == 0 )
	{
		// Counted only once the gun is really equipped: a weapon limit plugin
		// can still refuse this pickup after us.
		strcopy(g_sPendingSwap[client], sizeof(g_sPendingSwap[]), cls);
		return Plugin_Continue;
	}

	ShowBlockedHint(client, mode);
	return Plugin_Handled;
}

public void OnWeaponEquipPost(int client, int weapon)
{
	if( g_sPendingEmpty[client][0] != '\0' )
	{
		if( g_bTankAlive && weapon > MaxClients && IsValidEntity(weapon) )
		{
			char cls[32];
			GetEntityClassname(weapon, cls, sizeof(cls));
			if( StrEqual(cls, g_sPendingEmpty[client]) )
			{
				// Next frame, so a clip the game fills after the equip is caught.
				DataPack dp = new DataPack();
				dp.WriteCell(GetClientUserId(client));
				dp.WriteCell(EntIndexToEntRef(weapon));
				RequestFrame(Frame_EmptyClip, dp);
			}
		}

		g_sPendingEmpty[client][0] = '\0';
	}

	if( g_sPendingSwap[client][0] == '\0' ) return;

	if( g_bTankAlive && g_iSwapUser == 0 && weapon > MaxClients && IsValidEntity(weapon) )
	{
		char cls[32];
		GetEntityClassname(weapon, cls, sizeof(cls));
		if( StrEqual(cls, g_sPendingSwap[client]) )
			g_iSwapUser = GetClientUserId(client);
	}

	g_sPendingSwap[client][0] = '\0';
}

// The rounds go back to the reserve, so the swap costs a full reload and no ammo.
public void Frame_EmptyClip(DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	int weapon = EntRefToEntIndex(dp.ReadCell());
	delete dp;

	if( client == 0 || weapon == INVALID_ENT_REFERENCE ) return;
	if( GetPlayerWeaponSlot(client, 0) != weapon ) return;

	int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	if( clip <= 0 ) return;

	int type = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if( type >= 0 )
		SetEntProp(client, Prop_Send, "m_iAmmo", GetEntProp(client, Prop_Send, "m_iAmmo", _, type) + clip, _, type);
	SetEntProp(weapon, Prop_Send, "m_iClip1", 0);

	PrintHintText(client, "Swapped during the tank: reload before you can shoot.");
}

void ShowBlockedHint(int client, int mode)
{
	float now = GetGameTime();
	if( now < g_fLastHint[client] + HINT_COOLDOWN ) return;
	g_fLastHint[client] = now;

	if( mode == SWAP_LOCK )
	{
		PrintHintText(client, "You can't swap primaries while the tank is alive.");
		return;
	}

	int user = GetClientOfUserId(g_iSwapUser);
	if( user > 0 && IsClientInGame(user) )
		PrintHintText(client, "Your team's tank swap was used by %N.", user);
	else
		PrintHintText(client, "Your team's tank swap was already used.");
}
