#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <sdktools>

#define PLUGIN_VERSION "2.0-riverside2"

public Plugin myinfo =
{
	name = "[L4D] No M2 Movement Block",
	author = "Forgetest",
	description = "Enable free movement on SI when M2-ing.",
	version = PLUGIN_VERSION,
	url = "https://github.com/Target5150/MoYu_Server_Stupid_Plugins"
}

#define GAMEDATA_FILE "l4d_no_m2_movement_block"

int CTerrorGameMovement_m_pPlayer;
int CTerrorGameMovement_CMoveData;
int CMoveData_m_nButtons;
int CMoveData_m_flSideMove;

methodmap CMoveData
{
	public CMoveData(Address pTerrorGameMovement) {
		return view_as<CMoveData>(LoadFromAddress(view_as<Address>(pTerrorGameMovement) + view_as<Address>(CTerrorGameMovement_CMoveData), NumberType_Int32));
	}
	
	property int m_nButtons {
		public get() { return LoadFromAddress(view_as<Address>(this) + view_as<Address>(CMoveData_m_nButtons), NumberType_Int32); }
		public set(int nButtons) { StoreToAddress(view_as<Address>(this) + view_as<Address>(CMoveData_m_nButtons), nButtons, NumberType_Int32); }
	}
	
	property float m_flSideMove {
		public get() { return view_as<float>(LoadFromAddress(view_as<Address>(this) + view_as<Address>(CMoveData_m_flSideMove), NumberType_Int32)); }
		public set(float flSideMove) { StoreToAddress(view_as<Address>(this) + view_as<Address>(CMoveData_m_flSideMove), view_as<int>(flSideMove), NumberType_Int32); }
	}
}

ArrayList g_aResetM2TimerList;   // userid, swing end time, weapon ref

// riverside2: zeroing the claw's attack timer also hides the swing from
// CTerrorPlayer::UpdateZombieSounds, so human SI never played their scratch growl.
// The timer has to stay zeroed (it is networked and the client predicts the movement
// block from it), so the plugin plays the growl itself the way the game does: while the
// swing runs and the player's attack vocal timer has expired, emit the class's Attack
// sound and restart that timer for 0.2 s.
int g_iAttackSoundTimer = -1;
#define ATTACK_SOUND_INTERVAL 0.2

// riverside1: player entity address per client (stable from put-in-server to disconnect), so the
// per-usercmd lookup below compares an array instead of calling 4 natives per client
Address g_pClientAddress[MAXPLAYERS + 1];

enum
{
	PATCH_CROUCH = (1 << 0),
	PATCH_SIDEMOVE = (1 << 1)
}
ConVar g_cvPatchFlag;
ConVar g_cvGrowl;   // riverside2: 0 keeps the scratches silent, as before
int g_iPatchFlag;

public void OnPluginStart()
{
	Handle conf = LoadGameConfigFile(GAMEDATA_FILE);
	if (!conf) SetFailState("Missing gamedata \""...GAMEDATA_FILE..."\"");
	
	CTerrorGameMovement_m_pPlayer = GameConfGetOffset(conf, "CTerrorGameMovement::m_pPlayer");
	if (CTerrorGameMovement_m_pPlayer == -1) SetFailState("Missing offset \"CTerrorGameMovement::m_pPlayer\"");
	
	CTerrorGameMovement_CMoveData = GameConfGetOffset(conf, "CTerrorGameMovement::CMoveData");
	if (CTerrorGameMovement_CMoveData == -1) SetFailState("Missing offset \"CTerrorGameMovement::CMoveData\"");
	
	CMoveData_m_nButtons = GameConfGetOffset(conf, "CMoveData::m_nButtons");
	if (CMoveData_m_nButtons == -1) SetFailState("Missing offset \"CMoveData::m_nButtons\"");
	
	CMoveData_m_flSideMove = GameConfGetOffset(conf, "CMoveData::m_flSideMove");
	if (CMoveData_m_flSideMove == -1) SetFailState("Missing offset \"CMoveData::m_flSideMove\"");
	
	Handle hDetour = DHookCreateFromConf(conf, "CTerrorGameMovement::PlayerMove");
	if (!hDetour) SetFailState("Missing detour setting \"CTerrorGameMovement::PlayerMove\"");
	
	if (!DHookEnableDetour(hDetour, false, OnPlayerMove_Pre))
		SetFailState("Failed to pre-detour \"CTerrorGameMovement::PlayerMove\"");
	
	delete conf;

	conf = LoadGameConfigFile("l4d_no_m2_sounds");
	if (conf)
	{
		g_iAttackSoundTimer = GameConfGetOffset(conf, "CTerrorPlayer::m_attackSoundTimer");
		delete conf;
	}
	if (g_iAttackSoundTimer == -1) LogError("l4d_no_m2_sounds gamedata missing: SI scratch growls stay silent");
	
	g_aResetM2TimerList = new ArrayList(3);
	
	CreateConVar("l4d_no_m2_movement_block_version", PLUGIN_VERSION, "No M2 Movement Block Version", FCVAR_DONTRECORD|FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_SPONLY);
	g_cvPatchFlag = CreateConVar("l4d_no_m2_movement_block_enable", "3", "Plugin enable flags.\n1 = Crouch Patch, 2 = Side-move Patch, 3 = Both.", FCVAR_SPONLY|FCVAR_NOTIFY, true, 0.0, true, 3.0);
	g_cvPatchFlag.AddChangeHook(OnConVarChanged);
	g_cvGrowl = CreateConVar("l4d_no_m2_movement_block_growl", "1", "1 = play the special infected scratch growl the game skips because of this plugin (stock behaviour), 0 = silent scratches", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_iPatchFlag = g_cvPatchFlag.IntValue;

	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i)) OnClientPutInServer(i);
	}
}

public void OnClientPutInServer(int client)
{
	g_pClientAddress[client] = GetEntityAddress(client);
}

public void OnClientDisconnect(int client)
{
	g_pClientAddress[client] = Address_Null;
}

void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iPatchFlag = g_cvPatchFlag.IntValue;
}

MRESReturn OnPlayerMove_Pre(Address pThis)
{
	if (!g_iPatchFlag) return MRES_Ignored;
	
	int client = L4D_GetSIFromAddress(CTerrorGameMovement_GetPlayer(pThis));
	if (client == -1 || !IsPlayerAlive(client))
		return MRES_Ignored;

	if (IsFakeClient(client) || GetClientTeam(client) != 3)
		return MRES_Ignored;
	
	if (GetEntProp(client, Prop_Send, "m_zombieClass") == 5)
		return MRES_Ignored;
	
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon == -1)
		return MRES_Ignored;
	
	float flM2Time = GetEntPropFloat(weapon, Prop_Send, "m_attackTimer", 1);
	if (flM2Time > GetGameTime())
	{
		int userid = GetClientUserId(client);
		int index = g_aResetM2TimerList.FindValue(userid);
		if (index == -1)
			index = g_aResetM2TimerList.Push(userid);
		g_aResetM2TimerList.Set(index, flM2Time, 1);
		g_aResetM2TimerList.Set(index, EntIndexToEntRef(weapon), 2);
		
		SetEntPropFloat(weapon, Prop_Send, "m_attackTimer", 0.0, 1);
		
		CMoveData mv = CMoveData(pThis);
		if (~g_iPatchFlag & PATCH_CROUCH)
		{
			mv.m_nButtons &= 0xFFFFFFFB;
		}
		if (~g_iPatchFlag & PATCH_SIDEMOVE)
		{
			mv.m_flSideMove = 0.0;
		}
	}
	
	return MRES_Ignored;
}

public void OnGameFrame()
{
	float fNow = GetGameTime();
	for (int i = 0; i < g_aResetM2TimerList.Length; ++i)
	{
		float fSetTime = g_aResetM2TimerList.Get(i, 1);
		if (fNow < fSetTime)
		{
			int client = GetClientOfUserId(g_aResetM2TimerList.Get(i, 0));
			if (client && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 3)
				AttackVocal(client, fNow);
			continue;
		}
		
		// riverside2: write the timer back to the claw that swung, not whatever is active now
		// (an SI who took the tank within the swing would have had the tank claw's timer set)
		int weapon = EntRefToEntIndex(g_aResetM2TimerList.Get(i, 2));
		if (weapon != INVALID_ENT_REFERENCE)
		{
			SetEntPropFloat(weapon, Prop_Send, "m_attackTimer", fSetTime, 1);
		}
		
		g_aResetM2TimerList.Erase(i--);
	}
}

// The attack branch of CTerrorPlayer::UpdateZombieSounds, for a swing the game can no longer see.
void AttackVocal(int client, float fNow)
{
	if (g_iAttackSoundTimer == -1 || !g_cvGrowl.BoolValue) return;
	if (GetEntDataFloat(client, g_iAttackSoundTimer + 8) >= fNow) return;
	char sound[32];
	switch (GetEntProp(client, Prop_Send, "m_zombieClass"))
	{
		case 1: sound = "SmokerZombie.Attack";
		case 2: sound = "BoomerZombie.Attack";
		case 3: sound = "PlayerZombie.Attack";
		default: return;
	}
	EmitGameSoundToAll(sound, client);
	SetEntDataFloat(client, g_iAttackSoundTimer + 4, ATTACK_SOUND_INTERVAL);
	SetEntDataFloat(client, g_iAttackSoundTimer + 8, fNow + ATTACK_SOUND_INTERVAL);
}

Address CTerrorGameMovement_GetPlayer(Address pObj)
{
	return view_as<Address>(LoadFromAddress(pObj + view_as<Address>(CTerrorGameMovement_m_pPlayer), NumberType_Int32));
}

// Thanks "L4D_GetClientFromAddress" from left4dhooks
int L4D_GetSIFromAddress(Address addy)
{
	if (addy != Address_Null)
	{
		for (int i = 1; i <= MaxClients; ++i)
		{
			if (g_pClientAddress[i] == addy && IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == 3)
			{
				return i;
			}
		}
	}
	return -1;
}
