#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <multicolors>
#include <l4d_lib>

#define DEBUG_MODE              0

#define TEAM_SPECTATOR          1
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

#define SEQ_FLIGHT_BILL_LOUIS   544
#define SEQ_FLIGHT_FRANCIS      545
#define SEQ_FLIGHT_ZOEY         526

#define TIMER_CHECKPUNCH        0.025   // interval for checking 'flight' of punched survivors
#define TIME_CHECK_UNTIL        0.5     // try this long to find a stuck-position, then assume it's OK

enum eTankWeapon
{
    TANKWEAPON
}

new     bool:       g_bLateLoad                                 = false;

new     Float:      g_fPlayerPunch          [MAXPLAYERS + 1];                           // when was the last tank punch on this player?
new     bool:       g_bPlayerFlight         [MAXPLAYERS + 1];                           // is a player in (potentially stuckable) punched flight?
new     Float:      g_fPlayerStuck          [MAXPLAYERS + 1];                           // when did the (potential) 'stuckness' occur?
new     Float:      g_fPlayerLocation       [MAXPLAYERS + 1][3];                        // where was the survivor last during the flight?

new     Handle:     g_hCvarDeStuckTime                          = INVALID_HANDLE;       // convar: how long to wait and de-stuckify a punched player
new modelnum[MAXPLAYERS + 1];
static bool:TankPounchClient[MAXPLAYERS + 1];
new     Handle:     g_hPunchTimer           [MAXPLAYERS + 1];                           // riverside1: the one live check timer per survivor, older ones stop themselves

// riverside2: a punch that leaves its victim inside the world puts him back where he really was (match 505, 2026-10-05)
#define WATCH_TIME              1.0     // keep checking a punched survivor this long after the hit
ConVar  g_hCvarSolidFix;
float   g_vPreSwing             [MAXPLAYERS + 1][3];                                       // real origin before the swing's lag compensation
float   g_vLastClear            [MAXPLAYERS + 1][3];                                       // last origin his hull fit at, since the hit
bool    g_bHitThisSwing         [MAXPLAYERS + 1];
float   g_fWatchUntil           [MAXPLAYERS + 1];
// riverside4: one move of each kind per punch. The game's own movement never carries a survivor
// into something that really blocks him, so a second "stuck" in the same flight is a false alarm;
// looping the move every tick froze him in mid air while gravity built up (match 614, p4rty took
// 30 fall damage after 87 moves through a hanging plant)
#define COLLISION_GROUP_DEBRIS              1   // Source SDK values, not in the SourceMod includes
#define COLLISION_GROUP_DEBRIS_TRIGGER      2
#define COLLISION_GROUP_INTERACTIVE_DEBRIS  3
#define COLLISION_GROUP_WEAPON              11
#define COLLISION_GROUP_PUSHAWAY            17
bool    g_bFixed                [MAXPLAYERS + 1];
bool    g_bWarped               [MAXPLAYERS + 1];
char    g_sFixLog               [PLATFORM_MAX_PATH];

public Plugin:myinfo = 
{
    name =          "Tank Punch Ceiling Stuck Fix",
    author =        "Tabun, Visor, HarryPotter",
    description =   "Fixes the problem where tank-punches get a survivor stuck in the roof,L4D1 windows signature by Harry",
    version =       "0.6-2024/1/2-riverside5",
    url =           "nope"
}

public APLRes:AskPluginLoad2( Handle:plugin, bool:late, String:error[], errMax)
{
	CreateNative("IsTankPounchClient", Native_IsTankPounchClient);
	g_bLateLoad = late;
	return APLRes_Success;
}

public Native_IsTankPounchClient(Handle:plugin, numParams)
{
   new num1 = GetNativeCell(1);
   return TankPounchClient[num1];
}

ConVar sv_lagcompensationforcerestore;

public OnPluginStart()
{
    LoadTranslations("Roto2-AZ_mod.phrases");

    sv_lagcompensationforcerestore = FindConVar("sv_lagcompensationforcerestore");

    if (g_bLateLoad) {
        for (new i = 1; i < MaxClients+1; i++) {
            if (IsClientInGame(i)) {
                SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
            }
        }
    }
    
    // cvars
    g_hCvarSolidFix = CreateConVar("sm_punchstuckfix_solid", "1", "1: a survivor a tank punch leaves inside the world is moved back to his last clear position. 0: off.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sFixLog, sizeof(g_sFixLog), "logs/tank_punch_stuck.log");
    g_hCvarDeStuckTime = CreateConVar(      "sm_punchstuckfix_unstucktime",     "1.0",      "How many seconds to wait before detecting and unstucking a punched motionless player.", FCVAR_NOTIFY, true, 0.05, false);
	
    // hooks
    HookEvent("round_start", RoundStart_Event, EventHookMode_PostNoCopy);
    HookEvent("player_bot_replace", OnBotSwap);
    HookEvent("bot_player_replace", OnBotSwap);
    HookEvent("player_spawn", OnPlayerSpawn);
}


/* --------------------------------------
 *      General hooks / events
 * -------------------------------------- */

public OnClientPutInServer(client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
    // riverside3 (audit B2): the next player in this slot must not inherit a watch
    g_fWatchUntil[client] = 0.0;
    g_bHitThisSwing[client] = false;
    g_bFixed[client] = false;
    g_bWarped[client] = false;
}

public OnMapStart()
{
    setCleanSlate();
}

public Action: RoundStart_Event (Handle:event, const String:name[], bool:dontBroadcast)
{
    setCleanSlate();
    for(new i = 1; i <= MaxClients; i++) 
    {
        TankPounchClient[i] = false;
    }
}


/* --------------------------------------
 *     GOT MY EYES ON YOU, PUNCH
 * -------------------------------------- */

Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (damagetype != DMG_CLUB || !IsTankWeapon(inflictor)) {
        return Plugin_Continue;
    }

    if (!IsClientAndInGame(victim) || GetClientTeam(victim) != TEAM_SURVIVOR ) {
        return Plugin_Continue;
    }

    PrintDebug("IsTankWeapon - victim: (%N) %d, attacker: (%N) %d, inflictor: %d, damage: %f, damagetype: %d", victim, victim, attacker, attacker, inflictor, damage, damagetype);

    // tank punched survivor, check the result
    g_fPlayerPunch[victim] = GetTickedTime();
    g_bPlayerFlight[victim] = false;
    g_fPlayerStuck[victim] = 0.0;
    g_fPlayerLocation[victim][0] = 0.0;
    g_fPlayerLocation[victim][1] = 0.0;
    g_fPlayerLocation[victim][2] = 0.0;

    static char sModel[31];
    GetEntPropString(victim, Prop_Data, "m_ModelName", sModel, sizeof(sModel));

    switch(sModel[29])
    {
        case 'v'://bill (survivor_namvet)
        {
            modelnum[victim] = 1;
        }
        case 'n'://zoey (survivor_teenangst)
        {
            modelnum[victim] = 2;
        }
        case 'e'://francis (survivor_biker)
        {
            modelnum[victim] = 3;
        }
        case 'a'://louis (survivor_manager)
        {
            modelnum[victim] = 4;
        }
    }
        
    g_hPunchTimer[victim] = CreateTimer(TIMER_CHECKPUNCH, Timer_CheckPunch, GetClientUserId(victim), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

Action Timer_CheckPunch(Handle hTimer, int userid)
{
    int client = GetClientOfUserId(userid);
    // stop the timer when we no longer have a proper client
    if (!IsclientAndInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) { return Plugin_Stop; }

    // riverside1: a newer punch started its own timer (40 Hz timers used to stack per punch)
    if (hTimer != g_hPunchTimer[client]) { return Plugin_Stop; }

    // stop the time if we're passed the time for checking
    // riverside1: was "&& g_fPlayerStuck", which is never set, so a punch without a flight (pinned survivor) ran
    // until map change and flagged any later death as "punched"; a flight still runs until it lands (5 s cap)
    float fSincePunch = GetTickedTime() - g_fPlayerPunch[client];
    if (fSincePunch > TIME_CHECK_UNTIL && (!g_bPlayerFlight[client] || fSincePunch > 5.0))
    {
        g_fPlayerPunch[client] = 0.0;
        g_bPlayerFlight[client] = false;
        g_fPlayerStuck[client] = 0.0;
        
        return Plugin_Stop;
    }

    // get current animation frame and location of survivor
    new iSeq = GetEntProp(client, Prop_Send, "m_nSequence");
    PrintDebug("[test] %N - %d", client, iSeq);

    // if the player is not in flight, check if they are
    if ( IsPlayerAlive(client) && (( iSeq == SEQ_FLIGHT_BILL_LOUIS && (modelnum[client] == 1 || modelnum[client] == 4) 
    || (iSeq == SEQ_FLIGHT_FRANCIS && modelnum[client] == 3 ) 
    || (iSeq == SEQ_FLIGHT_ZOEY && modelnum[client] == 2) ) ) )
    {
        new Float: vOrigin[3];
        GetEntPropVector(client, Prop_Send, "m_vecOrigin", vOrigin);
        
        if (!g_bPlayerFlight[client])
        {
            // if the player is not detected as in punch-flight, they are now
            g_bPlayerFlight[client] = true;
            g_fPlayerLocation[client] = vOrigin;

            PrintDebug("[test] %i - flight start [seq:%4i][loc:%.f %.f %.f]", client, iSeq, vOrigin[0], vOrigin[1], vOrigin[2]);
        }
        else
        {
            // if the player is in punch-flight, check location / difference to detect stuckness
            if (GetVectorDistance(g_fPlayerLocation[client], vOrigin) == 0.0) {
                
                // are we /still/ in the same position? (ie. if stucktime is recorded)
                if (g_fPlayerStuck[client])
                {
                    g_fPlayerStuck[client] = GetTickedTime();    
                }
                else
                {
                    if (GetTickedTime() - g_fPlayerStuck[client] > GetConVarFloat(g_hCvarDeStuckTime))
                    {
                        // time passed, player is stuck! fix.
                        //LogMessage("<TankPunchStuck> %N - stuckness FIX triggered!", client);
                        
                        g_fPlayerPunch[client] = 0.0;
                        g_bPlayerFlight[client] = false;
                        g_fPlayerStuck[client] = 0.0;

                        /*
                        CTerrorPlayer_WarpToValidPositionIfStuck(client);
                        decl String:clientName[128];
                        GetClientName(client,clientName,128);
                        CPrintToChatAll("%t","l4d_tankpunchstuckfix", clientName);
                        }
                        */
                        return Plugin_Stop;
                    }
                }
            }
            else
            {
                // if we were detected as stuck, undetect
                if (g_fPlayerStuck[client])
                {
                    g_fPlayerStuck[client] = 0.0;
                }
            }
        }
    }
    else if (!IsPlayerAlive(client))
    {
        TankPounchClient[client] = true;
        return Plugin_Stop;
    }
    else if ( IsIncapacitated(client) || GetEntProp(client, Prop_Send, "m_isHangingFromLedge") ||
        ( iSeq == SEQ_FLIGHT_BILL_LOUIS+1 && (modelnum[client] == 1 || modelnum[client] == 4) ) 
        || (iSeq == SEQ_FLIGHT_FRANCIS+1 && modelnum[client] == 3)  
        || (iSeq == SEQ_FLIGHT_ZOEY+1 && modelnum[client] == 2) )
    {
        if (g_bPlayerFlight[client])
        {
            // landing frame, so not stuck
            g_fPlayerPunch[client] = 0.0;
            g_bPlayerFlight[client] = false;
            g_fPlayerStuck[client] = 0.0;

            PrintDebug("[test] %i - flight end (natural)", client);
        }
        
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

/* --------------------------------------
 *     Shared function(s)
 * -------------------------------------- */

stock bool:IsclientAndInGame(index)
{
    return (index > 0 && index <= MaxClients && IsClientInGame(index));
}


stock setCleanSlate()
{
    new i, maxplayers = MaxClients;
    for (i = 1; i <= maxplayers; i++)
    {
        g_fPlayerPunch[i] = 0.0;
        g_bPlayerFlight[i] = false;
        g_fPlayerStuck[i] = 0.0;
        g_fPlayerLocation[i][0] = 0.0;
        g_fPlayerLocation[i][1] = 0.0;
        g_fPlayerLocation[i][2] = 0.0;
        // riverside3 (audit B2): game time restarts with the map, so a deadline from the last
        // map would keep this slot watched against the old map's coordinates
        g_fWatchUntil[i] = 0.0;
        g_bHitThisSwing[i] = false;
        g_bFixed[i] = false;
        g_bWarped[i] = false;
    }
}

public PrintDebug(const String:Message[], any:...)
{
    #if DEBUG_MODE
        decl String:DebugBuff[256];
        VFormat(DebugBuff, sizeof(DebugBuff), Message, 2);
        PrintToChatAll(DebugBuff);
    #endif
}

stock void CTerrorPlayer_WarpToValidPositionIfStuck(int client)
{
	L4D_WarpToValidPositionIfStuck(client);
}

public Action:OnBotSwap(Handle:event, const String:name[], bool:dontBroadcast) 
{
	new bot = GetClientOfUserId(GetEventInt(event, "bot"));
	new player = GetClientOfUserId(GetEventInt(event, "player"));
	if (IsClientIndex(bot) && IsClientIndex(player)) 
	{
		if (StrEqual(name, "player_bot_replace")) 
		{
			TankPounchClient[bot] = TankPounchClient[player];
			TankPounchClient[player] = false;
			
		}
		else 
		{
			TankPounchClient[player] = TankPounchClient[bot];
			TankPounchClient[bot] = false;
		}
	}
	return Plugin_Continue;
}

public Action:OnPlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(client && IsClientInGame(client))
	{
		TankPounchClient[client] = false;
	}
}

bool:IsClientIndex(client)
{
	return (client > 0 && client <= MaxClients);
}

bool IsTankWeapon(int entity)
{
	if (entity >= MaxClients + 1 && IsValidEntity(entity)) {
		char eName[32];
		GetEntityClassname(entity, eName, sizeof(eName));
		return (strcmp("weapon_tank_claw", eName) == 0/* || strcmp("tank_rock", eName) == 0*/);
	}

	return false;
}

public void L4D_TankClaw_DoSwing_Pre(int tank, int claw)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bHitThisSwing[i] = false;
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			GetClientAbsOrigin(i, g_vPreSwing[i]);
	}
}

public void L4D_TankClaw_OnPlayerHit_Post(int tank, int claw, int player)
{
	sv_lagcompensationforcerestore.BoolValue = false;
	if (player > 0 && player <= MaxClients) g_bHitThisSwing[player] = true;
}

public void L4D_TankClaw_DoSwing_Post(int tank, int claw)
{
	sv_lagcompensationforcerestore.BoolValue = true;

	// lag compensation has restored everyone by now: anyone this swing hit must fit where he is
	if (!g_hCvarSolidFix.BoolValue) return;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bHitThisSwing[i]) continue;
		g_bHitThisSwing[i] = false;
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i)) continue;
		g_vLastClear[i] = g_vPreSwing[i];
		g_fWatchUntil[i] = GetGameTime() + WATCH_TIME;
		g_bFixed[i] = false;
		g_bWarped[i] = false;
		CheckPunchedSolid(i, "swing");
	}
}

public void OnGameFrame()
{
	float now = GetGameTime();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_fWatchUntil[i] == 0.0) continue;
		// riverside3 (audit B1): a pinned survivor is held by the infected, not flying; stop
		// watching him so a pounce or pull inside the window is never snapped back
		if (now > g_fWatchUntil[i] || !IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i)
			|| GetEntPropEnt(i, Prop_Send, "m_pounceAttacker") > 0 || GetEntPropEnt(i, Prop_Send, "m_tongueOwner") > 0)
		{
			g_fWatchUntil[i] = 0.0;
			continue;
		}
		CheckPunchedSolid(i, "flight");
	}
}

void CheckPunchedSolid(int client, const char[] when)
{
	if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge")) return;
	float pos[3];
	GetClientAbsOrigin(client, pos);
	int hit;
	if (!HullInWorld(client, pos, hit))
	{
		g_vLastClear[client] = pos;
		return;
	}
	char map[64], what[160];
	GetCurrentMap(map, sizeof(map));
	DescribeHit(hit, what, sizeof(what));
	int lastHit;
	if (g_bFixed[client] || g_bWarped[client])
	{
		// riverside4: he was already moved once this punch and is "stuck" again, so whatever the
		// trace hits is not stopping his movement; stop watching instead of pinning him every tick
		g_fWatchUntil[client] = 0.0;
		LogToFileEx(g_sFixLog, "GIVEUP map=%s survivor=\"%N\" when=%s at=%.1f %.1f %.1f hit=%s",
			map, client, when, pos[0], pos[1], pos[2], what);
	}
	else if (!HullInWorld(client, g_vLastClear[client], lastHit))
	{
		g_bFixed[client] = true;
		TeleportEntity(client, g_vLastClear[client], NULL_VECTOR, NULL_VECTOR);   // velocity kept, the fling carries on
		LogToFileEx(g_sFixLog, "FIX map=%s survivor=\"%N\" when=%s stuck=%.1f %.1f %.1f moved_to=%.1f %.1f %.1f ducked=%d hit=%s",
			map, client, when, pos[0], pos[1], pos[2], g_vLastClear[client][0], g_vLastClear[client][1], g_vLastClear[client][2],
			GetEntProp(client, Prop_Send, "m_bDucked"), what);
	}
	else
	{
		g_bWarped[client] = true;
		L4D_WarpToValidPositionIfStuck(client);
		GetClientAbsOrigin(client, g_vLastClear[client]);
		LogToFileEx(g_sFixLog, "WARP map=%s survivor=\"%N\" when=%s stuck=%.1f %.1f %.1f warped_to=%.1f %.1f %.1f moved=%d hit=%s",
			map, client, when, pos[0], pos[1], pos[2], g_vLastClear[client][0], g_vLastClear[client][1], g_vLastClear[client][2],
			GetVectorDistance(pos, g_vLastClear[client]) > 0.1, what);
	}
}

bool HullInWorld(int client, const float pos[3], int &hit)
{
	float mins[3], maxs[3];
	GetEntPropVector(client, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(client, Prop_Send, "m_vecMaxs", maxs);
	// riverside3 (audit B1): without CONTENTS_MONSTER, so commons or a witch standing in his
	// hull do not count as "inside the world" (the collision ports let commons walk into a
	// pinned survivor on purpose)
	Handle tr = TR_TraceHullFilterEx(pos, pos, mins, maxs, MASK_PLAYERSOLID & ~CONTENTS_MONSTER, TraceFilter_PlayerBlockers);
	bool solid = TR_StartSolid(tr);
	hit = TR_GetEntityIndex(tr);
	delete tr;
	return solid;
}

// riverside4: only what a survivor's movement collides with. Debris (hanging plants, small physics
// junk), interactive debris, dropped weapons and pushaway props let a player walk through them, and
// counting them as world is what kept p4rty pinned in airport01's greenhouse (match 614)
bool TraceFilter_PlayerBlockers(int entity, int contentsMask)
{
	if (entity <= MaxClients) return entity == 0;
	// riverside5: dropping CONTENTS_MONSTER does not drop commons in L4D1 (they trace as solid,
	// collision group 5), so a common overlapping a flung survivor read as "inside the world":
	// 119 of 138 logged moves 10-11..10-12 were hit=infected (up to 32 units)
	char cls[16];
	GetEntityClassname(entity, cls, sizeof(cls));
	if (StrEqual(cls, "infected") || StrEqual(cls, "witch")) return false;
	if (!HasEntProp(entity, Prop_Send, "m_CollisionGroup")) return true;
	switch (GetEntProp(entity, Prop_Send, "m_CollisionGroup"))
	{
		case COLLISION_GROUP_DEBRIS, COLLISION_GROUP_DEBRIS_TRIGGER, COLLISION_GROUP_INTERACTIVE_DEBRIS,
			COLLISION_GROUP_WEAPON, COLLISION_GROUP_PUSHAWAY:
			return false;
	}
	return true;
}

void DescribeHit(int ent, char[] buf, int len)
{
	if (ent == 0) { strcopy(buf, len, "world"); return; }
	if (ent < 0 || !IsValidEntity(ent)) { strcopy(buf, len, "?"); return; }
	char cls[64], model[96];
	GetEntityClassname(ent, cls, sizeof(cls));
	if (HasEntProp(ent, Prop_Data, "m_ModelName")) GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
	int cg = HasEntProp(ent, Prop_Send, "m_CollisionGroup") ? GetEntProp(ent, Prop_Send, "m_CollisionGroup") : -1;
	FormatEx(buf, len, "%s:%s:cg%d", cls, model, cg);
}
