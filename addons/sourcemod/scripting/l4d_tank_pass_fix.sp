#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <dhooks>

#define PLUGIN_VERSION "0.6"

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
 *
 * 0.2: a passed tank is not left stuck. ZombieManager::ReplaceTank hands the
 * old tank's origin to Spawn, which can bring the new tank up inside a prop:
 * match 949 (NM1, both halves) passed a tank climbing the storage-room box
 * stack (z 80, already inside it) and the new one came up at z 16 inside the
 * boxes, frozen until CGameMovement::CheckStuck warped it onto the nearest
 * teammate 5 s later, 400 to 580 units away. Every alive tank's last clear,
 * on-ground spot is kept (5 Hz). One frame after a pass, a new tank whose hull
 * is blocked goes to the old tank's spot if that is clear, else to the old
 * tank's last clear spot from the past 10 s within 256 u, else the engine's
 * WarpToValidPositionIfStuck gets a try. l4d_tank_pass_fix_unstick 0 only logs.
 *
 * 0.3: any stuck tank, not only a passed one. Replays 09-20 to 11-04: 11
 * tanks frozen 5+ s and then warped by CheckStuck onto a teammate, often one
 * fighting the survivors (match 980 Ria Daed 3: 5.8 s frozen after a roof
 * drop, then 3098 u onto a smoker 32 u from a survivor). A tank the engine
 * has in its stuck state (m_StuckLast > 0) whose origin has not moved for
 * 1 s goes back to its last clear spot (<= 10 s, <= 256 u), else gets the
 * engine warp; nothing found leaves it to the stock 5 s warp. A pass hands
 * the old tank's trail to the new one, so a tank passed while stuck (match
 * 920 DT4) is covered too. l4d_tank_pass_fix_unstick 0 logs these as well.
 *
 * 0.4: the hull test no longer counts players as solid. 0.2/0.3 skipped only
 * the tank itself, so a pass with a survivor, a teammate or the old tank's
 * own body touching the new tank read as "stuck": 34 post-pass stuck lines
 * 11-03..11-15, 27 "STILL STUCK" (24 not moved at all), and none followed by
 * a frozen line (the engine's own stuck counter) within 90 s. The effect was
 * a harmless teleport in place, but the log was noise and a real stuck pass
 * could be sent to the engine warp for the wrong reason. Movement against
 * players is the engine's business; this plugin only cares about the world,
 * props, clips and blockers. The stuck and frozen lines now name what the
 * hull hit (hit=world or the entity's classname) so a stray blocker shows up.
 *
 * 0.5: the tank lottery steal guard. Valve's CTerrorPlayer::PlayerZombieAbortControl (an infected player's
 * USE press, PlayerUse, or the z_abort command) compares the director's m_iTankLotteryWinner, a CLIENT
 * INDEX (Director::CreateTanks), with the presser's USER ID. If they match it hands the presser the first
 * live, non-ghost tank BOT (PlayerCollector(infected, alive, bots, tank), ReplaceWithBot + TakeOverBot),
 * clears the winner and skips the director's m_iTankPassedCount++. Reported: DT2 final 2026-11-22,
 * Riverside #5, l4d_tank_control picked fran (index 5) and fauxf6r (userid 5) took it; the refill then
 * read "passed count now 1". The engine's own check (l4d-source PlayerZombieAbortControl.cpp:17) is the
 * real fix, held with the other Valve bug fixes.
 *
 * When a press can take it (round replays at 10 Hz, confirmed on the bot rig, tools/tankfixrig): the offered
 * tank waits in stasis as a ghost (m_isGhost 1) and the collector skips it, but it stops being a ghost about
 * 3.0 s after the offer (rig: +3.01 to +3.10 s) while the handoff comes at about +3.11 s and the winner
 * index stays set the whole draw. In that last ~0.1 s the colliding player's E or z_abort takes it: the
 * incident (take minus offer 3.01-3.11 s) and the rig (z_abort at +3.07 s, E the frame the ghost flag
 * dropped, both taken, pass count skipped). Earlier in the draw a press collects nothing. The same press
 * also works whenever another live non-ghost tank bot is out while a winner index is set: the "stale
 * winner" (the winner left the infected team before the handoff; CreateTanks releases the tank to the AI
 * and keeps the index, so the colliding player can take the AI tank at any later time) and an older AI tank
 * while another lottery draws (the steal takes the old tank, clears the winner, and the offered tank stays
 * with the AI). All reproduced on the rig.
 *
 * The guard drops IN_USE from the usercmd (OnPlayerRunCmd) and blocks z_abort for an infected player only
 * when the press would be that steal: a live non-ghost tank bot exists and the presser's userid equals the
 * pending winner (terror_player_manager m_pendingTankPlayerIndex, which CTerrorPlayerResource copies from
 * m_iTankLotteryWinner every resource think). That networked copy can be up to one think late after the
 * draw, so from a bot tank's offer (L4D_OnTryOfferingTankBot_Post) until entry + selection time + 1 s,
 * while it still reads 0, any infected player whose userid is the client index of another infected player
 * is blocked too. Everyone else's E (GhostWarp's survivor cycling, the stock ghost warp) keeps working.
 * A press held through the block stays blocked until released, so letting go of the strip cannot turn
 * into a fresh press. One line per window per client and kind in tank_pass_fix.log ("lottery winner"
 * inside the offer window, "stale winner" after it). l4d_tank_pass_fix_steal_guard 0 logs the same lines
 * and blocks nothing.
 *
 * 0.6: no "take the tank now" at all (owner, 2026-11-22). A DHooks detour on PlayerZombieAbortControl
 * (gamedata l4d_tank_pass_fix.txt) supercedes the call whenever the director's m_iTankLotteryWinner equals
 * the caller's userid, i.e. exactly when Valve would run the takeover branch. That branch is all the call
 * does in that case (Valve returns from it whether or not a tank was found; the ghost warp and the cull
 * branch only run when the comparison fails), so superceding it changes nothing else, and the only callers
 * are PlayerUse (E) and the z_abort command: the director's own handoff (CreateTanks ->
 * TakeOverZombieBot) never goes through it. E and z_abort input are left alone, so GhostWarp's E and the
 * stock ghost warp keep working for everyone else. Each superceded call is logged ("takeover blocked",
 * with the tank it would have taken or "nothing to take"). l4d_tank_pass_fix_no_takeover 0 logs and lets
 * Valve's code run. If the detour or the offset is not available the 0.5 input guard runs instead.
 */

ConVar g_cvEnabled, g_cvLottery, g_cvUnstick, g_cvStealGuard, g_cvLotteryEntry, g_cvNoTakeover;
bool g_bDetour;				// 0.6: the PlayerZombieAbortControl detour is on (the 0.5 input guard stands down)
int g_iWinnerOffset = -1;	// Director::m_iTankLotteryWinner
float g_fLastTakeoverLog[MAXPLAYERS + 1];
float g_fLastHumanOffer = -1000.0;
char g_sLog[PLATFORM_MAX_PATH];

#define CLEAR_SPOT_MAX_AGE 10.0
#define CLEAR_SPOT_MAX_DIST 256.0  // a tank teleported since then (a plugin, a warp) has no usable trail
float g_vClearSpot[MAXPLAYERS + 1][3];
float g_fClearSpotAt[MAXPLAYERS + 1];

#define STUCK_TICKS 5  // 5 Hz checks: 1 s frozen in the engine's stuck state
float g_vLastPos[MAXPLAYERS + 1][3];
int g_iStuckTicks[MAXPLAYERS + 1];

// 0.5 steal guard
float g_fOfferAt = -1000.0, g_fOfferUntil = -1000.0;	// the last bot tank offer and its fallback window
int g_iOfferSerial;										// one per offer: a blocked client logs once per offer
int g_iLoggedKey[MAXPLAYERS + 1][2];					// [client][0 = USE, 1 = z_abort]: last logged window
bool g_bUseHeld[MAXPLAYERS + 1];						// a blocked USE still held down
bool g_bUseDown[MAXPLAYERS + 1];						// IN_USE was down (and let through) last usercmd

public Plugin myinfo =
{
	name = "Tank Pass Fix",
	author = "Malevolence",
	description = "Stops a passed tank being taken off its new owner by a duplicate lottery, unsticks tanks, and skips Valve's E/z_abort tank takeover",
	version = PLUGIN_VERSION,
	url = "https://riversidepug.com"
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d_tank_pass_fix", "1", "1 = block a duplicate human-tank offer inside one lottery of the last, 0 = log only.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvUnstick = CreateConVar("l4d_tank_pass_fix_unstick", "1", "1 = a passed tank that comes up stuck goes to the old tank's spot or the nearest free one, 0 = log only.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvStealGuard = CreateConVar("l4d_tank_pass_fix_steal_guard", "1", "1 = an infected player whose userid equals the tank lottery winner's client index cannot take a tank bot with E or z_abort (Valve's userid/index mix-up), 0 = log only.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvLottery = FindConVar("director_tank_lottery_selection_time");
	g_cvLotteryEntry = FindConVar("director_tank_lottery_entry_time");
	g_cvNoTakeover = CreateConVar("l4d_tank_pass_fix_no_takeover", "1", "1 = Valve's E / z_abort tank takeover (PlayerZombieAbortControl, lottery winner index == userid) is skipped for everyone, 0 = log only.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AddCommandListener(Cmd_ZAbort, "z_abort");
	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/tank_pass_fix.log");
	SetupDetour();
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

void SetupDetour()
{
	// new GameData throws on a missing file, which would take the whole plugin down: look first
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "gamedata/l4d_tank_pass_fix.txt");
	GameData gd = FileExists(path) ? new GameData("l4d_tank_pass_fix") : null;
	if (gd == null)
	{
		LogToFileEx(g_sLog, "takeover block: no gamedata l4d_tank_pass_fix.txt, using the 0.5 input guard");
		return;
	}
	g_iWinnerOffset = gd.GetOffset("Director::m_iTankLotteryWinner");
	DynamicDetour d = DynamicDetour.FromConf(gd, "CTerrorPlayer::PlayerZombieAbortControl");
	delete gd;
	if (d == null || g_iWinnerOffset <= 0 || !d.Enable(Hook_Pre, Detour_AbortControl))
	{
		LogToFileEx(g_sLog, "takeover block: detour or offset unavailable, using the 0.5 input guard");
		return;
	}
	g_bDetour = true;
	LogToFileEx(g_sLog, "takeover block: PlayerZombieAbortControl detour on (winner offset %d)", g_iWinnerOffset);
}

int LotteryWinner()
{
	Address dir = L4D_GetPointer(POINTER_DIRECTOR);
	if (dir == Address_Null || g_iWinnerOffset <= 0) return -1;
	return LoadFromAddress(dir + view_as<Address>(g_iWinnerOffset), NumberType_Int32);
}

MRESReturn Detour_AbortControl(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || GetClientTeam(client) != 3)
		return MRES_Ignored;	// Valve returns at once for anyone not infected
	int winner = LotteryWinner();
	if (winner <= 0 || winner != GetClientUserId(client))
		return MRES_Ignored;	// Valve's comparison fails: ghost warp / cull branch, untouched
	bool block = g_cvNoTakeover.BoolValue;
	int tank = LiveTankBot();
	// E is edge-triggered; z_abort can be spammed: at most one line per client per 0.5 s
	float now = GetGameTime();
	if (now - g_fLastTakeoverLog[client] >= 0.5)
	{
		g_fLastTakeoverLog[client] = now;
		char who[MAX_NAME_LENGTH] = "?", what[64] = "nothing to take";
		if (winner <= MaxClients && IsClientInGame(winner)) GetClientName(winner, who, sizeof(who));
		if (tank > 0) Format(what, sizeof(what), "would have taken tank bot #%d", tank);
		LogToFileEx(g_sLog, "takeover %s: \"%N\" userid=%d = lottery winner index %d \"%s\", %s, t=%.2f (%.2f s after the offer)",
			block ? "blocked" : "allowed (log only)", client, GetClientUserId(client), winner, who, what, now, now - g_fOfferAt);
	}
	return block ? MRES_Supercede : MRES_Ignored;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_fLastHumanOffer = -1000.0;
	g_fOfferUntil = -1000.0;
}

public void OnClientDisconnect(int client)
{
	g_fLastTakeoverLog[client] = 0.0;
	g_bUseHeld[client] = g_bUseDown[client] = false;
	g_iLoggedKey[client][0] = g_iLoggedKey[client][1] = 0;
}

public void OnMapStart()
{
	g_fLastHumanOffer = -1000.0;
	g_fOfferAt = g_fOfferUntil = -1000.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bUseHeld[i] = g_bUseDown[i] = false;
		g_fClearSpotAt[i] = -1000.0;
		g_iStuckTicks[i] = 0;
	}
	CreateTimer(0.2, Timer_ClearSpots, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ClearSpots(Handle timer)
{
	float pos[3];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 3 || !IsPlayerAlive(i) || GetEntProp(i, Prop_Send, "m_zombieClass") != 5
			|| GetEntProp(i, Prop_Send, "m_isGhost"))
		{
			g_iStuckTicks[i] = 0;
			continue;
		}
		GetClientAbsOrigin(i, pos);
		CheckStuckTank(i, pos);
		if (!(GetEntityFlags(i) & FL_ONGROUND))
			continue;
		if (HullBlocked(i, pos))
			continue;
		g_vClearSpot[i] = pos;
		g_fClearSpotAt[i] = GetGameTime();
	}
	return Plugin_Continue;
}

// The engine's CheckStuck counts m_StuckLast up on every failed nudge and
// zeroes it once the player is free; after 5 s of it the player is warped
// onto the nearest teammate. Act after 1 s with the tank's own trail instead.
void CheckStuckTank(int client, const float pos[3])
{
	bool frozen = GetVectorDistance(pos, g_vLastPos[client]) < 1.0;
	g_vLastPos[client] = pos;
	if (!frozen || GetEntProp(client, Prop_Data, "m_StuckLast") <= 0 || GetEntityMoveType(client) != MOVETYPE_WALK)
	{
		g_iStuckTicks[client] = 0;
		return;
	}
	if (++g_iStuckTicks[client] < STUCK_TICKS)
		return;
	g_iStuckTicks[client] = 0;

	char hit[32] = "none";
	if (HullBlocked(client, pos))
		HitName(hit, sizeof(hit));
	bool haveClear = GetGameTime() - g_fClearSpotAt[client] <= CLEAR_SPOT_MAX_AGE
		&& GetVectorDistance(g_vClearSpot[client], pos) <= CLEAR_SPOT_MAX_DIST
		&& !HullBlocked(client, g_vClearSpot[client]);

	if (!g_cvUnstick.BoolValue)
	{
		LogToFileEx(g_sLog, "frozen \"%N\" at=%.1f %.1f %.1f stucklast=%d clear=%d hit=%s (log only)",
			client, pos[0], pos[1], pos[2], GetEntProp(client, Prop_Data, "m_StuckLast"), haveClear, hit);
		return;
	}

	char via[16];
	float zero[3];
	if (haveClear)
	{
		via = "last clear";
		TeleportEntity(client, g_vClearSpot[client], NULL_VECTOR, zero);
	}
	else
	{
		via = "engine warp";
		L4D_WarpToValidPositionIfStuck(client);
	}

	float to[3];
	GetClientAbsOrigin(client, to);
	g_vLastPos[client] = to;
	LogToFileEx(g_sLog, "frozen \"%N\" at=%.1f %.1f %.1f hit=%s -> %.1f %.1f %.1f via %s%s",
		client, pos[0], pos[1], pos[2], hit, to[0], to[1], to[2], via, HullBlocked(client, to) ? " STILL STUCK" : "");
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

// ---- 0.5: tank lottery steal guard (see the header) ----

public void L4D_OnTryOfferingTankBot_Post(int tank_index, bool enterStasis)
{
	if (tank_index < 1 || tank_index > MaxClients || !IsClientInGame(tank_index) || !IsFakeClient(tank_index))
		return;	// a human (frustrated) tank: the takeover only ever takes a bot
	float entry = g_cvLotteryEntry != null ? g_cvLotteryEntry.FloatValue : 0.1;
	float selection = g_cvLottery != null ? g_cvLottery.FloatValue : 3.0;
	g_fOfferAt = GetGameTime();
	g_fOfferUntil = g_fOfferAt + entry + selection + 1.0;
	g_iOfferSerial++;
}

int PendingWinner()
{
	static bool s_bChecked, s_bHave;
	int res = GetPlayerResourceEntity();
	if (res == -1) return -1;
	if (!s_bChecked)
	{
		s_bChecked = true;
		s_bHave = HasEntProp(res, Prop_Send, "m_pendingTankPlayerIndex");
		if (!s_bHave) LogToFileEx(g_sLog, "steal guard: terror_player_manager has no m_pendingTankPlayerIndex, using the offer window only");
	}
	return s_bHave ? GetEntProp(res, Prop_Send, "m_pendingTankPlayerIndex") : -1;
}

// What PlayerZombieAbortControl's PlayerCollector(infected, alive, bots, tank) finds: a live tank bot that is
// not a ghost. The tank on offer is in stasis and a ghost (m_isGhost 1) for the whole lottery, so it is not
// collected; it is once the draw releases it to the AI, or when another tank is already out as an AI.
int LiveTankBot()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i)
			&& GetEntProp(i, Prop_Send, "m_zombieClass") == 5 && !GetEntProp(i, Prop_Send, "m_isGhost"))
			return i;
	}
	return 0;
}

/**
 * Would this infected player's PlayerZombieAbortControl take the tank bot right now? Returns the winner's
 * client index it collides with (0 = no), and why in reason.
 */
int StealTarget(int client, char[] reason, int len)
{
	if (g_bDetour) return 0;	// 0.6: the detour skips the takeover itself
	if (LiveTankBot() == 0) return 0;
	int uid = GetClientUserId(client);
	int pending = PendingWinner();
	bool inWindow = GetGameTime() < g_fOfferUntil;
	if (pending > 0)
	{
		if (uid != pending) return 0;
		strcopy(reason, len, inWindow ? "lottery winner" : "stale winner");
		return pending;
	}
	// the networked copy may still read 0 right after the draw: anyone who could collide with an entrant
	if (!inWindow || uid > MaxClients) return 0;
	if (!IsClientInGame(uid) || GetClientTeam(uid) != 3) return 0;
	if (IsPlayerAlive(uid) && GetEntProp(uid, Prop_Send, "m_zombieClass") == 5) return 0;	// a live tank cannot win
	strcopy(reason, len, pending == 0 ? "possible winner, draw not networked yet" : "possible winner");
	return uid;
}

void LogSteal(int client, int kind, int target, const char[] reason, bool block)
{
	// once per client and kind per offer window, and once more for a stale winner after that window
	int key = g_iOfferSerial * 2 + (GetGameTime() < g_fOfferUntil ? 0 : 1) + 1;
	if (g_iLoggedKey[client][kind] == key) return;
	g_iLoggedKey[client][kind] = key;
	char who[MAX_NAME_LENGTH] = "?";
	if (target > 0 && target <= MaxClients && IsClientInGame(target)) GetClientName(target, who, sizeof(who));
	LogToFileEx(g_sLog, "steal guard: %s %s from \"%N\" userid=%d%s = %s index %d \"%s\" t=%.2f (%.2f s after the offer)",
		block ? "BLOCKED" : "would block (log only)", kind == 0 ? "USE" : "z_abort", client, GetClientUserId(client),
		IsFakeClient(client) ? " (bot)" : "", reason, target, who, GetGameTime(), GetGameTime() - g_fOfferAt);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3])
{
	if (!(buttons & IN_USE))
	{
		g_bUseHeld[client] = g_bUseDown[client] = false;
		return Plugin_Continue;
	}
	if (g_bUseHeld[client])	// still holding a press we dropped: no fresh press when the guard lets go
	{
		buttons &= ~IN_USE;
		return Plugin_Changed;
	}
	if (g_bUseDown[client] || GetClientTeam(client) != 3)
		return Plugin_Continue;	// only a new press reaches PlayerZombieAbortControl (PlayerUse: m_afButtonPressed)
	g_bUseDown[client] = true;
	char reason[48];
	int target = StealTarget(client, reason, sizeof(reason));
	if (target == 0) return Plugin_Continue;
	bool block = g_cvStealGuard.BoolValue;
	LogSteal(client, 0, target, reason, block);
	if (!block) return Plugin_Continue;
	buttons &= ~IN_USE;
	g_bUseHeld[client] = true;
	g_bUseDown[client] = false;
	return Plugin_Changed;
}

public Action Cmd_ZAbort(int client, const char[] command, int argc)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || GetClientTeam(client) != 3)
		return Plugin_Continue;
	char reason[48];
	int target = StealTarget(client, reason, sizeof(reason));
	if (target == 0) return Plugin_Continue;
	bool block = g_cvStealGuard.BoolValue;
	LogSteal(client, 1, target, reason, block);
	return block ? Plugin_Handled : Plugin_Continue;
}

public void L4D_OnReplaceTank(int tank, int newtank)
{
	char a[MAX_NAME_LENGTH] = "?", b[MAX_NAME_LENGTH] = "?";
	if (tank > 0 && tank <= MaxClients && IsClientInGame(tank)) GetClientName(tank, a, sizeof(a));
	if (newtank > 0 && newtank <= MaxClients && IsClientInGame(newtank)) GetClientName(newtank, b, sizeof(b));
	LogToFileEx(g_sLog, "replace %d \"%s\" -> %d \"%s\" t=%.2f", tank, a, newtank, b, GetGameTime());

	// Valve's handoff loop also calls ReplaceTank(winner, winner) right after the
	// real pass; by then the winner already stands on the dropped spot, so only
	// the first call carries the old tank's origin.
	if (tank == newtank || tank < 1 || tank > MaxClients || !IsClientInGame(tank) || !IsPlayerAlive(tank))
		return;
	if (newtank < 1 || newtank > MaxClients || !IsClientInGame(newtank))
		return;

	float from[3];
	GetClientAbsOrigin(tank, from);
	bool haveClear = GetGameTime() - g_fClearSpotAt[tank] <= CLEAR_SPOT_MAX_AGE;
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(newtank));
	dp.WriteFloat(from[0]);
	dp.WriteFloat(from[1]);
	dp.WriteFloat(from[2]);
	dp.WriteCell(haveClear);
	dp.WriteFloat(g_vClearSpot[tank][0]);
	dp.WriteFloat(g_vClearSpot[tank][1]);
	dp.WriteFloat(g_vClearSpot[tank][2]);
	// the new tank carries on the old one's trail
	g_vClearSpot[newtank] = g_vClearSpot[tank];
	g_fClearSpotAt[newtank] = g_fClearSpotAt[tank];
	g_iStuckTicks[newtank] = 0;
	g_fClearSpotAt[tank] = -1000.0;
	RequestFrame(Frame_Unstick, dp);
}

void Frame_Unstick(DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	float from[3], clear[3];
	from[0] = dp.ReadFloat();
	from[1] = dp.ReadFloat();
	from[2] = dp.ReadFloat();
	bool haveClear = dp.ReadCell();
	clear[0] = dp.ReadFloat();
	clear[1] = dp.ReadFloat();
	clear[2] = dp.ReadFloat();
	delete dp;

	if (client == 0 || !IsPlayerAlive(client) || GetClientTeam(client) != 3 || GetEntProp(client, Prop_Send, "m_zombieClass") != 5)
		return;

	float at[3];
	GetClientAbsOrigin(client, at);
	if (!HullBlocked(client, at))
		return;
	char hit[32];
	HitName(hit, sizeof(hit));

	if (!g_cvUnstick.BoolValue)
	{
		LogToFileEx(g_sLog, "stuck \"%N\" at=%.1f %.1f %.1f old=%.1f %.1f %.1f hit=%s (log only)", client, at[0], at[1], at[2], from[0], from[1], from[2], hit);
		return;
	}

	char via[16];
	float zero[3];
	if (!HullBlocked(client, from))
	{
		via = "old spot";
		TeleportEntity(client, from, NULL_VECTOR, zero);
	}
	else if (haveClear && GetVectorDistance(clear, from) <= CLEAR_SPOT_MAX_DIST && !HullBlocked(client, clear))
	{
		via = "last clear";
		TeleportEntity(client, clear, NULL_VECTOR, zero);
	}
	else
	{
		via = "engine warp";
		TeleportEntity(client, from, NULL_VECTOR, zero);
		L4D_WarpToValidPositionIfStuck(client);
	}

	float to[3];
	GetClientAbsOrigin(client, to);
	LogToFileEx(g_sLog, "stuck \"%N\" at=%.1f %.1f %.1f old=%.1f %.1f %.1f hit=%s -> %.1f %.1f %.1f via %s%s",
		client, at[0], at[1], at[2], from[0], from[1], from[2], hit, to[0], to[1], to[2],
		via, HullBlocked(client, to) ? " STILL STUCK" : "");
}

// What a human infected's movement collides with (CTerrorGameMovement::
// PlayerSolidMask for team 3, less the 0x80000000 bit whose meaning is not
// known): no survivor-only PLAYERCLIP, plus MONSTERCLIP and the infected-only
// team blockers.
#define MASK_INFECTED_MOVE 0x0202520B
int g_iLastHit = -1;

bool HullBlocked(int client, const float pos[3])
{
	float mins[3], maxs[3];
	GetClientMins(client, mins);
	GetClientMaxs(client, maxs);
	TR_TraceHullFilter(pos, pos, mins, maxs, MASK_INFECTED_MOVE, TraceFilter_Solid, client);
	bool blocked = TR_DidHit() || TR_StartSolid();
	g_iLastHit = blocked ? TR_GetEntityIndex() : -1;
	return blocked;
}

// What the last blocked HullBlocked hit: "world" or the entity's classname.
void HitName(char[] buf, int len)
{
	if (g_iLastHit <= 0)
		strcopy(buf, len, "world");
	else if (IsValidEntity(g_iLastHit))
		GetEntityClassname(g_iLastHit, buf, len);
	else
		Format(buf, len, "#%d", g_iLastHit);
}

// World, props, clips and blockers only: no players (the tank itself, its
// teammates, survivors, the old tank's body after a pass), which a tank is not
// stuck in, and no weapon spawns, which movement walks through.
bool TraceFilter_Solid(int entity, int mask, int self)
{
	if (entity >= 1 && entity <= MaxClients)
		return false;
	if (entity > MaxClients && IsValidEntity(entity))
	{
		char cls[16];
		GetEntityClassname(entity, cls, sizeof(cls));
		if (strncmp(cls, "weapon_", 7) == 0)
			return false;
	}
	return true;
}
