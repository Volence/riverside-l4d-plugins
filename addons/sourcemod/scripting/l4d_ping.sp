#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "3.7"

// Marker sprite — a stock $ignorez material drawn as an env_sprite billboard. With
// force-transmit it shows through most walls (L4D1 has no working glow/instructor marker).
#define MARKER_SPRITE "materials/vgui/icon_arrow_down.vmt"

// Every marker entity carries this targetname so the orphan sweep can find and
// kill markers whose bookkeeping was lost (see SweepOrphanMarkers).
#define MARKER_TARGETNAME "l4dping_marker"

enum PingKind
{
    Ping_Location = 0,
    Ping_Item,       // consumables / throwables (medkit, pills, molotov, pipe bomb)
    Ping_Weapon,     // guns
    Ping_Enemy       // special infected / witch
}

#define MAX_PINGS 64

enum struct PingData
{
    bool  active;
    int   ownerUserId;   // pinger's userid (survives client index reuse)
    int   team;          // 2 = survivors, 3 = infected
    PingKind kind;
    int   entRef;        // enemy target as an entity reference, else INVALID_ENT_REFERENCE
    int   markerRef;     // info_target anchor entity, else INVALID_ENT_REFERENCE
    // One env_sprite PER VIEWER, indexed by client. m_flSpriteScale is a networked
    // property with a single value for all clients, so a shared sprite can only ever
    // be sized for one viewer's distance -- whoever was nearest decided how big it
    // looked for everybody. Each teammate gets their own sprite, transmitted only to
    // them and scaled to their own distance.
    int   viewerSprite[MAXPLAYERS + 1];
    float pos[3];        // current marker position
    float spawnTime;     // GetGameTime() at creation
    float lastLosTime;   // last time pinger had LOS (enemy only)
    bool  frozen;        // enemy marker frozen at last-seen
    int   color[4];      // RGBA (a=unused) used for the sprite color
    char  label[64];
}

PingData g_Pings[MAX_PINGS];
GlobalForward g_hOnPing;   // L4DPing_OnPing(client, pos[3], kind, target)
float g_LastPingTime[MAXPLAYERS + 1];
int g_MarkerTeam[2049];   // per-entity-index: which team may receive (see) this marker
int g_MarkerViewer[2049]; // per-entity-index: the ONE client allowed to see it (0 = any teammate)

// Tank zombie-class differs by engine; resolved in AskPluginLoad2.
int g_iZombieClass_Tank = 5;   // L4D1 = 5, L4D2 = 8

// ---- CVars ----
ConVar g_cvEnable;
ConVar g_cvLifetime;
ConVar g_cvCooldown;
ConVar g_cvLosGrace;
ConVar g_cvFollow;
ConVar g_cvAssistInfected;
ConVar g_cvMaxActive;
ConVar g_cvTeams;     // 0 = both teams, 1 = survivors only
ConVar g_cvAimAssist; // aim-assist cone (degrees) for pinging visible special infected
ConVar g_cvAimRange;  // max range aim-assist will reach to snap onto a target
ConVar g_cvSize;      // apparent marker size; auto-scaled by distance to stay constant
ConVar g_cvSound;
ConVar g_cvChat;      // print the "X pinged a Y" chat callout (sound is separate)
ConVar g_cvHint;      // one-time per-connect "how to bind the ping key" hint
ConVar g_cvHintKey;   // key name suggested in that hint
ConVar g_cvDebug;

public Plugin myinfo =
{
    name        = "L4D1 Ping System",
    author      = "Riverside",
    description = "Overwatch-style team ping system for competitive L4D1",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/Volence/riverside-l4d-plugins"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion ev = GetEngineVersion();
    if (ev == Engine_Left4Dead)
        g_iZombieClass_Tank = 5;
    else if (ev == Engine_Left4Dead2)
        g_iZombieClass_Tank = 8;
    else
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 1/2.");
        return APLRes_Failure;
    }
    // For other plugins (the practice park): drop a real ping for a team.
    CreateNative("L4DPing_Create", Native_Create);
    g_hOnPing = new GlobalForward("L4DPing_OnPing", ET_Ignore, Param_Cell, Param_Array, Param_Cell, Param_Cell);
    RegPluginLibrary("l4d_ping");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvEnable    = CreateConVar("l4d_ping_enable",     "1",   "Enable the ping system.", _, true, 0.0, true, 1.0);
    g_cvLifetime  = CreateConVar("l4d_ping_lifetime",   "6.0", "Seconds a ping marker lasts.", _, true, 0.5);
    g_cvCooldown  = CreateConVar("l4d_ping_cooldown",   "1.0", "Per-player seconds between pings.", _, true, 0.0);
    g_cvLosGrace  = CreateConVar("l4d_ping_los_grace",  "1.0", "Seconds of lost LOS before an enemy ping freezes.", _, true, 0.0);
    // Off by default since 3.5 (2026-09-23): the follow uses the engine's line
    // of sight, which passes through foliage a player cannot see through, so a
    // ping on an infected behind trees kept tracking it and gave away where it
    // went. With 0 the marker stays where the infected was when pinged.
    // Off by default since 3.6: the assist cone checks line of sight with the
    // same engine trace, so a survivor aiming near a tree snapped onto the
    // infected hidden behind it. Items, weapons and the witch still snap, and
    // aiming straight at an infected still pings it.
    g_cvAssistInfected = CreateConVar("l4d_ping_assist_infected", "0", "1 = a survivor's aim-assist also snaps onto special infected (can find them behind foliage). 0 = only items, weapons and the witch.", _, true, 0.0, true, 1.0);
    g_cvFollow    = CreateConVar("l4d_ping_follow",     "0",   "1 = an enemy ping follows the infected while the pinger has line of sight (passes through foliage). 0 = it stays where the infected was when pinged.", _, true, 0.0, true, 1.0);
    g_cvMaxActive = CreateConVar("l4d_ping_max_active", "8",   "Max active pings per team.", _, true, 1.0, true, 32.0);
    g_cvTeams     = CreateConVar("l4d_ping_teams",      "0",   "0 = both teams may ping, 1 = survivors only.", _, true, 0.0, true, 1.0);
    g_cvAimAssist = CreateConVar("l4d_ping_aim_assist", "8.0", "Aim-assist cone in degrees for pinging a visible special infected (0 = off).", _, true, 0.0, true, 45.0);
    g_cvAimRange  = CreateConVar("l4d_ping_aim_range",  "6000", "Max distance aim-assist will reach to snap onto a target.", _, true, 100.0);
    g_cvSize      = CreateConVar("l4d_ping_size",       "0.6", "Apparent marker size (auto-scaled by distance so it stays about constant).", _, true, 0.1, true, 3.0);
    g_cvSound     = CreateConVar("l4d_ping_sound",      "ui/alert_clink.wav", "Sound played to the team on a ping (empty = silent).");
    g_cvChat      = CreateConVar("l4d_ping_chat",       "0",   "1 = also print a chat callout on each ping. The marker and sound are unaffected; this is just the text.", _, true, 0.0, true, 1.0);
    g_cvHint      = CreateConVar("l4d_ping_hint",       "1",   "1 = tell each player once per connect how to bind the ping key. Servers cannot push binds to clients, so without this a new player has no way to discover the feature.", _, true, 0.0, true, 1.0);
    g_cvHintKey   = CreateConVar("l4d_ping_hint_key",   "mouse3", "Key suggested in the bind hint.");
    g_cvDebug     = CreateConVar("l4d_ping_debug",      "0",   "1 = print debug info to the pinger's console.", _, true, 0.0, true, 1.0);

    RegConsoleCmd("sm_ping", Cmd_Ping, "Ping whatever you are aiming at.");

    HookEvent("round_start", Event_RoundReset, EventHookMode_PostNoCopy);
    HookEvent("round_end",   Event_RoundReset, EventHookMode_PostNoCopy);
    HookEvent("player_team", Event_PlayerTeam);

    // Do NOT add TIMER_FLAG_NO_MAPCHANGE here. That flag destroys the timer on
    // every map change, and OnPluginStart runs only once, so the timer was gone
    // for the rest of the session after the first map load -- taking lifetime
    // expiry, the orphan sweep, enemy tracking and distance scaling with it.
    // That is the real cause of "pings stay forever": nothing was expiring them.
    // It hid during testing because `sm plugins reload` re-runs OnPluginStart.
    CreateTimer(0.1, Timer_Render, _, TIMER_REPEAT);

    AutoExecConfig(true, "l4d_ping");

}

public void OnMapStart()
{
    PrecacheModel(MARKER_SPRITE, true);

    char snd[PLATFORM_MAX_PATH];
    g_cvSound.GetString(snd, sizeof snd);
    if (snd[0] != '\0')
        PrecacheSound(snd, true);

    // Clear any stale pings from a previous map (marker entities are already gone).
    for (int i = 0; i < MAX_PINGS; i++)
        g_Pings[i].active = false;
}

public Action Timer_Render(Handle timer)
{
    for (int i = 0; i < MAX_PINGS; i++)
    {
        if (!g_Pings[i].active)
            continue;

        // Expire by lifetime. The `now < spawnTime` arm matters: GetGameTime()
        // resets on a round restart, which makes the elapsed subtraction go
        // negative and the marker live forever. Treat a backwards clock as
        // expired rather than trusting the delta.
        float now = GetGameTime();
        if (now < g_Pings[i].spawnTime || now - g_Pings[i].spawnTime >= g_cvLifetime.FloatValue)
        {
            DeactivatePing(i);
            continue;
        }

        // Enemy pings: follow the target while the pinger has LOS, then freeze.
        if (g_Pings[i].kind == Ping_Enemy && !g_Pings[i].frozen)
        {
            int target = GetLivingTarget(i);
            if (target == -1)
            {
                DeactivatePing(i);
                continue;
            }

            int owner = GetClientOfUserId(g_Pings[i].ownerUserId);
            if (owner > 0 && PingerHasLOS(owner, target))
            {
                float tpos[3];
                GetEntPropVector(target, Prop_Send, "m_vecOrigin", tpos);
                g_Pings[i].pos = tpos;
                g_Pings[i].lastLosTime = GetGameTime();
                UpdateMarkerPos(i);
            }
            else if (GetGameTime() - g_Pings[i].lastLosTime >= g_cvLosGrace.FloatValue)
            {
                g_Pings[i].frozen = true;
            }
        }

        // Auto-scale by distance so the marker's on-screen size stays about constant.
        UpdateMarkerScale(i);
    }

    SweepOrphanMarkers();
    return Plugin_Continue;
}

// Kill any marker entity that no active ping still points at.
//
// Belt and braces for the "marker stayed forever" bug. The per-ping lifetime
// check only runs for slots that are still `active`, so any path that clears a
// slot without calling RemoveMarker -- a round restart, a team switch, a client
// index reused after a disconnect -- strands the entity with nothing tracking
// it. Every marker carries MARKER_TARGETNAME, so we can find strays directly
// rather than relying on the bookkeeping being correct.
void SweepOrphanMarkers()
{
    int ent = INVALID_ENT_REFERENCE;
    while ((ent = FindEntityByClassname(ent, "env_sprite")) != INVALID_ENT_REFERENCE)
        KillIfOrphan(ent);

    ent = INVALID_ENT_REFERENCE;
    while ((ent = FindEntityByClassname(ent, "info_target")) != INVALID_ENT_REFERENCE)
        KillIfOrphan(ent);
}

void KillIfOrphan(int ent)
{
    if (ent <= MaxClients || !IsValidEntity(ent))
        return;

    char name[64];
    GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof name);
    if (!StrEqual(name, MARKER_TARGETNAME))
        return;

    int ref = EntIndexToEntRef(ent);
    for (int i = 0; i < MAX_PINGS; i++)
    {
        if (!g_Pings[i].active)
            continue;
        if (g_Pings[i].markerRef == ref)
            return;
        for (int c = 0; c <= MaxClients; c++)
            if (g_Pings[i].viewerSprite[c] == ref)
                return;
    }

    g_MarkerTeam[ent] = 0;
    RemoveEntity(ent);
}

// Scale the glow prop's model proportionally to the distance to the nearest same-team
// viewer, so the outline's apparent (on-screen) size stays roughly constant with range.
void UpdateMarkerScale(int idx)
{
    // Each viewer's own sprite is scaled to THAT viewer's distance, so the marker
    // holds a constant apparent size on every screen independently.
    for (int c = 1; c <= MaxClients; c++)
    {
        int spr = EntRefToEntIndex(g_Pings[idx].viewerSprite[c]);
        if (spr <= MaxClients || !IsValidEntity(spr) || !HasEntProp(spr, Prop_Send, "m_flSpriteScale"))
            continue;
        if (!IsClientInGame(c) || IsFakeClient(c))
            continue;

        float cp[3];
        GetClientEyePosition(c, cp);
        float dist = GetVectorDistance(cp, g_Pings[idx].pos);

        float scale = dist * (g_cvSize.FloatValue / 300.0);   // constant apparent size
        if (scale < 0.15) scale = 0.15;
        if (scale > 8.0)  scale = 8.0;
        SetEntPropFloat(spr, Prop_Send, "m_flSpriteScale", scale);
    }
}

// Tell the player why a ping was refused. Every rejection used to be a silent
// Plugin_Handled, which is indistinguishable from "my key isn't bound" -- that
// cost real debugging time when a teammate reported pings "not working".
void PingRefused(int client, const char[] reason)
{
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
        PrintToChat(client, "\x04[Ping]\x01 %s", reason);
}

public Action Cmd_Ping(int client, int args)
{
    if (!g_cvEnable.BoolValue)
    {
        PingRefused(client, "Ping system is disabled on this server.");
        return Plugin_Handled;
    }

    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (!IsPlayerAlive(client))
    {
        PingRefused(client, "You must be alive to ping.");
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);
    if (team != 2 && team != 3)   // spectators/lobby cannot ping
    {
        PingRefused(client, "Spectators cannot ping.");
        return Plugin_Handled;
    }

    float now = GetGameTime();
    if (now - g_LastPingTime[client] < g_cvCooldown.FloatValue)
    {
        PingRefused(client, "Ping is on cooldown.");
        return Plugin_Handled;
    }

    float pos[3];
    int hitEnt = GetAimTarget(client, pos);

    char label[64];
    PingKind kind;
    int targetEnt;
    ClassifyHit(client, hitEnt, label, sizeof label, kind, targetEnt);

    // Aim-assist: if we'd otherwise ping bare ground, snap to a nearby visible
    // special infected, item or weapon within the aim cone.
    if (kind == Ping_Location)
        FindAimedTarget(client, kind, label, sizeof label, targetEnt, pos);

    // Survivors-only mode: infected pings are ignored.
    if (g_cvTeams.IntValue == 1 && team != 2)
    {
        PingRefused(client, "Only survivors can ping on this server (l4d_ping_teams 1).");
        return Plugin_Handled;
    }

    // One ping per player: drop the pinger's previous ping first.
    RemovePlayerPings(client);

    int slot = CreatePing(client, pos, kind, targetEnt, label);
    if (slot == -1)
    {
        PingRefused(client, "No free ping slots right now, try again.");
        return Plugin_Handled;
    }

    g_LastPingTime[client] = now;

    AnnouncePing(client, kind, label);

    // Tell other plugins (the practice park moves a trainer's source here).
    Call_StartForward(g_hOnPing);
    Call_PushCell(client);
    Call_PushArray(pos, 3);
    Call_PushCell(view_as<int>(kind));
    Call_PushCell(targetEnt);
    Call_Finish();

    if (g_cvDebug.BoolValue)
        PrintToConsole(client, "[ping] created slot=%d kind=%d label=%s", slot, kind, label);

    return Plugin_Handled;
}

// Sound + optional chat callout to every human on the pinger's team.
// The chat line is off by default (l4d_ping_chat): with a group all pinging at
// once it buries the actual conversation, and the marker plus the sound already
// carry the information.
void AnnouncePing(int client, PingKind kind, const char[] label)
{
    bool chat = g_cvChat.BoolValue;

    char msg[128];
    if (chat)
    {
        char pinger[MAX_NAME_LENGTH];
        GetClientName(client, pinger, sizeof pinger);
        switch (kind)
        {
            case Ping_Enemy:    Format(msg, sizeof msg, "%s: %s spotted", pinger, label);
            case Ping_Location: Format(msg, sizeof msg, "%s pinged a location", pinger);
            default:            Format(msg, sizeof msg, "%s pinged a %s", pinger, label);
        }
    }

    int team = GetClientTeam(client);

    char snd[PLATFORM_MAX_PATH];
    g_cvSound.GetString(snd, sizeof snd);
    if (snd[0] != '\0')
        PrecacheSound(snd, true);

    if (snd[0] == '\0' && !chat)
        return;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || IsFakeClient(c))
            continue;
        if (GetClientTeam(c) != team)
            continue;
        if (snd[0] != '\0')
            EmitSoundToClient(c, snd);
        if (chat)
            PrintToChat(c, "\x04[Ping]\x01 %s", msg);
    }
}

// Trace filter: ignore the pinging player only.
public bool TraceFilter_IgnoreSelf(int entity, int contentsMask, any data)
{
    return entity != data;
}

// Trace the client's aim. Fills endPos with the hit point, returns the hit
// entity index (0 = world / nothing, >0 = an entity), or -1 if the trace failed.
int GetAimTarget(int client, float endPos[3])
{
    float eyePos[3], eyeAng[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);

    Handle tr = TR_TraceRayFilterEx(eyePos, eyeAng, MASK_SHOT, RayType_Infinite,
                                    TraceFilter_IgnoreSelf, client);
    int hit = -1;
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(endPos, tr);
        hit = TR_GetEntityIndex(tr);
        if (hit < 0) hit = 0;
    }
    else
    {
        endPos = eyePos;
    }
    delete tr;
    return hit;
}

// Aim-assist: find the best pingable thing (special infected, witch, item or weapon)
// nearest the client's aim line within the cone, that the client can see. On success
// returns the entity and fills outKind/outLabel/outTarget/outPos; otherwise -1.
int FindAimedTarget(int client, PingKind &outKind, char[] outLabel, int labelLen, int &outTarget, float outPos[3])
{
    float cone = g_cvAimAssist.FloatValue;
    if (cone <= 0.0)
        return -1;

    float eye[3], ang[3], fwd[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);

    float bestDot = Cosine(DegToRad(cone));  // inside the cone => dot > bestDot
    int best = -1;

    // Ghosts are only pingable by their own team, who can actually see them.
    bool pingerIsSurvivor = (GetClientTeam(client) == 2);

    // Infected players/bots. Not for survivors unless l4d_ping_assist_infected.
    bool assistInfected = !pingerIsSurvivor || g_cvAssistInfected.BoolValue;
    for (int c = 1; assistInfected && c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || GetClientTeam(c) != 3 || !IsPlayerAlive(c))
            continue;
        if (pingerIsSurvivor && IsGhostInfected(c))
            continue;
        float d = AimDotToEntity(eye, fwd, c, true);
        if (d > bestDot && PingerHasLOS(client, c))
        {
            bestDot = d;
            best = c;
        }
    }

    // World entities: witches + items/weapons.
    bool dummy;
    char scratch[64], cls[64];
    int maxe = GetMaxEntities();
    for (int e = MaxClients + 1; e < maxe; e++)
    {
        if (!IsValidEntity(e))
            continue;
        GetEntityClassname(e, cls, sizeof cls);
        if (!StrEqual(cls, "witch") && !GetItemInfo(cls, scratch, sizeof scratch, dummy))
            continue;
        float d = AimDotToEntity(eye, fwd, e, false);
        if (d > bestDot && PingerHasLOS(client, e))
        {
            bestDot = d;
            best = e;
        }
    }

    if (best == -1)
        return -1;

    GetEntityClassname(best, cls, sizeof cls);
    if ((best >= 1 && best <= MaxClients) || StrEqual(cls, "witch"))
    {
        outKind = Ping_Enemy;
        outTarget = best;
        GetEnemyLabel(best, outLabel, labelLen);
    }
    else
    {
        bool isWeapon;
        GetItemInfo(cls, outLabel, labelLen, isWeapon);
        outKind = isWeapon ? Ping_Weapon : Ping_Item;
        outTarget = 0;
    }

    if (best >= 1 && best <= MaxClients)
        GetClientEyePosition(best, outPos);
    else
        GetEntPropVector(best, Prop_Send, "m_vecOrigin", outPos);
    return best;
}

// Dot product between the aim direction and the direction to an entity's center.
// Returns -2.0 if out of range / degenerate (never selected).
float AimDotToEntity(const float eye[3], const float fwd[3], int ent, bool useEye)
{
    float tp[3];
    if (useEye)
        GetClientEyePosition(ent, tp);
    else
    {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", tp);
        tp[2] += 40.0;
    }

    float dir[3];
    SubtractVectors(tp, eye, dir);
    float dist = GetVectorLength(dir);
    if (dist > g_cvAimRange.FloatValue || dist < 1.0)
        return -2.0;

    NormalizeVector(dir, dir);
    return GetVectorDotProduct(fwd, dir);
}

// True if this client is a ghost-state infected (picking a spawn, invisible to
// survivors). Ghosts count as "alive" on team 3, so every IsPlayerAlive-based
// filter lets them through -- which let survivors ping them: aim-assist snapped
// to the ghost, and PingerHasLOS passed because ghosts are non-solid, so the
// trace sails through and lands in the "nothing blocked the ray" branch.
// A tracked marker on an invisible enemy is a wallhack on spawn positions.
bool IsGhostInfected(int ent)
{
    if (ent < 1 || ent > MaxClients)
        return false;
    if (!HasEntProp(ent, Prop_Send, "m_isGhost"))
        return false;
    return GetEntProp(ent, Prop_Send, "m_isGhost", 1) != 0;
}

// True if `client` has clear line of sight to `targetEnt`.
bool PingerHasLOS(int client, int targetEnt)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return false;

    float eyePos[3], targetPos[3];
    GetClientEyePosition(client, eyePos);
    GetEntPropVector(targetEnt, Prop_Send, "m_vecOrigin", targetPos);
    targetPos[2] += 40.0; // aim at torso/center, not feet

    Handle tr = TR_TraceRayFilterEx(eyePos, targetPos, MASK_SHOT, RayType_EndPoint,
                                    TraceFilter_IgnoreSelf, client);
    bool clear = false;
    if (TR_DidHit(tr))
        clear = (TR_GetEntityIndex(tr) == targetEnt);
    else
        clear = true; // nothing blocked the ray at all
    delete tr;
    return clear;
}

// Resolve a ping's target entity index, or -1 if gone/dead.
int GetLivingTarget(int idx)
{
    int ent = EntRefToEntIndex(g_Pings[idx].entRef);
    if (ent == INVALID_ENT_REFERENCE || ent <= 0 || !IsValidEntity(ent))
        return -1;

    if (ent >= 1 && ent <= MaxClients)
    {
        if (!IsClientInGame(ent) || !IsPlayerAlive(ent))
            return -1;
        // If a survivor-team marker is somehow tracking a ghost (e.g. the
        // target died and re-ghosted within the marker's lifetime), expire it
        // rather than keep painting an invisible enemy.
        if (g_Pings[idx].team == 2 && IsGhostInfected(ent))
            return -1;
    }
    else
    {
        if (HasEntProp(ent, Prop_Data, "m_iHealth") && GetEntProp(ent, Prop_Data, "m_iHealth") <= 0)
            return -1;
    }
    return ent;
}

// Human-readable name for an L4D1 special-infected zombie class.
void GetZombieClassName(int zclass, char[] out, int maxlen)
{
    if (zclass == g_iZombieClass_Tank) { strcopy(out, maxlen, "Tank"); return; }
    switch (zclass)
    {
        case 1: strcopy(out, maxlen, "Smoker");
        case 2: strcopy(out, maxlen, "Boomer");
        case 3: strcopy(out, maxlen, "Hunter");
        default: strcopy(out, maxlen, "Special Infected");
    }
}

// Label for an enemy entity (witch or infected player).
void GetEnemyLabel(int ent, char[] out, int maxlen)
{
    char cls[64];
    GetEntityClassname(ent, cls, sizeof cls);
    if (StrEqual(cls, "witch"))
    {
        strcopy(out, maxlen, "Witch");
        return;
    }
    if (ent >= 1 && ent <= MaxClients)
    {
        GetZombieClassName(GetEntProp(ent, Prop_Send, "m_zombieClass"), out, maxlen);
        return;
    }
    strcopy(out, maxlen, "Special Infected");
}

// Friendly label for a pingable item/weapon classname. Returns false if neither.
// Sets isWeapon for guns. Substring matching so L4D1 "weapon_X_spawn" world-pickup
// names and minor naming variants all classify correctly.
bool GetItemInfo(const char[] classname, char[] out, int maxlen, bool &isWeapon)
{
    isWeapon = false;

    // Consumables / throwables (checked first so a "pills"/"kit" never falls to a gun).
    if (StrContains(classname, "pain_pills") != -1 || StrContains(classname, "painpills") != -1) { strcopy(out, maxlen, "Pills");     return true; }
    if (StrContains(classname, "first_aid")  != -1 || StrContains(classname, "medkit")    != -1) { strcopy(out, maxlen, "Medkit");    return true; }
    if (StrContains(classname, "molotov")    != -1)                                              { strcopy(out, maxlen, "Molotov");   return true; }
    if (StrContains(classname, "pipe_bomb")  != -1 || StrContains(classname, "pipebomb")  != -1) { strcopy(out, maxlen, "Pipe Bomb"); return true; }

    // Guns.
    if (StrContains(classname, "pistol")        != -1) { strcopy(out, maxlen, "Pistol");        isWeapon = true; return true; }
    if (StrContains(classname, "hunting_rifle") != -1) { strcopy(out, maxlen, "Hunting Rifle"); isWeapon = true; return true; }
    if (StrContains(classname, "autoshotgun")   != -1) { strcopy(out, maxlen, "Auto Shotgun");  isWeapon = true; return true; }
    if (StrContains(classname, "shotgun")       != -1) { strcopy(out, maxlen, "Shotgun");       isWeapon = true; return true; }
    if (StrContains(classname, "rifle")         != -1) { strcopy(out, maxlen, "Assault Rifle"); isWeapon = true; return true; }
    if (StrContains(classname, "smg")           != -1) { strcopy(out, maxlen, "SMG");           isWeapon = true; return true; }

    // Any other weapon_* -> treat as a gun, with a tidied-up label.
    if (strncmp(classname, "weapon_", 7) == 0)
    {
        strcopy(out, maxlen, classname[7]);
        ReplaceString(out, maxlen, "_spawn", "");
        ReplaceString(out, maxlen, "_", " ");
        isWeapon = true;
        return true;
    }
    return false;
}

// Classify what the aim hit. Fills kind, label, and (for enemies) targetEnt.
void ClassifyHit(int pinger, int hitEnt, char[] label, int labelLen, PingKind &kind, int &targetEnt)
{
    targetEnt = 0;
    kind = Ping_Location;
    strcopy(label, labelLen, "Location");

    if (hitEnt <= 0)
        return;

    char classname[64];
    GetEntityClassname(hitEnt, classname, sizeof classname);

    // Witch.
    if (StrEqual(classname, "witch"))
    {
        kind = Ping_Enemy;
        targetEnt = hitEnt;
        strcopy(label, labelLen, "Witch");
        return;
    }

    // Infected player/bot (team 3). A ghost is never an enemy target for a
    // survivor pinger -- see IsGhostInfected. (Unlikely the trace ever hits a
    // non-solid ghost directly, but belt and braces; the ping then falls back
    // to a plain Location at the trace end.)
    if (hitEnt >= 1 && hitEnt <= MaxClients && IsClientInGame(hitEnt) && GetClientTeam(hitEnt) == 3)
    {
        if (GetClientTeam(pinger) == 2 && IsGhostInfected(hitEnt))
            return;
        kind = Ping_Enemy;
        targetEnt = hitEnt;
        GetEnemyLabel(hitEnt, label, labelLen);
        return;
    }

    // Item / weapon.
    bool isWeapon;
    if (GetItemInfo(classname, label, labelLen, isWeapon))
    {
        kind = isWeapon ? Ping_Weapon : Ping_Item;
        return;
    }
    // Otherwise stays a Location ping.
}

// Context colors (RGBA; alpha unused).
void GetKindColor(PingKind kind, int color[4])
{
    switch (kind)
    {
        case Ping_Enemy:  { color[0]=255; color[1]=40;  color[2]=40;  color[3]=255; } // red
        case Ping_Weapon: { color[0]=40;  color[1]=120; color[2]=255; color[3]=255; } // blue
        case Ping_Item:   { color[0]=60;  color[1]=230; color[2]=90;  color[3]=255; } // green
        default:          { color[0]=235; color[1]=235; color[2]=235; color[3]=255; } // white (location)
    }
}

// Find a free slot. If the per-team cap is reached, expire that team's oldest
// ping and reuse its slot. Always returns a usable slot.
int FindPingSlot(int team)
{
    int used = 0, free = -1;
    int oldest = -1;
    float oldestTime = 0.0;

    for (int i = 0; i < MAX_PINGS; i++)
    {
        if (!g_Pings[i].active)
        {
            if (free == -1) free = i;
            continue;
        }
        if (g_Pings[i].team == team)
        {
            used++;
            if (oldest == -1 || g_Pings[i].spawnTime < oldestTime)
            {
                oldest = i;
                oldestTime = g_Pings[i].spawnTime;
            }
        }
    }

    if (used >= g_cvMaxActive.IntValue && oldest != -1)
    {
        DeactivatePing(oldest);
        return oldest;
    }
    return free;
}

// Deactivate any active pings owned by a client (one ping per player).
void RemovePlayerPings(int client)
{
    int uid = GetClientUserId(client);
    for (int i = 0; i < MAX_PINGS; i++)
        if (g_Pings[i].active && g_Pings[i].ownerUserId == uid)
            DeactivatePing(i);
}

// Create and store a ping (and its marker). Returns the slot, or -1 on failure.
int CreatePing(int client, const float pos[3], PingKind kind, int targetEnt, const char[] label)
{
    int team = GetClientTeam(client);
    int slot = FindPingSlot(team);
    if (slot == -1)
        return -1;

    g_Pings[slot].active      = true;
    g_Pings[slot].ownerUserId = GetClientUserId(client);
    g_Pings[slot].team        = team;
    g_Pings[slot].kind        = kind;
    g_Pings[slot].entRef      = (targetEnt > 0) ? EntIndexToEntRef(targetEnt) : INVALID_ENT_REFERENCE;
    g_Pings[slot].pos         = pos;
    g_Pings[slot].spawnTime   = GetGameTime();
    g_Pings[slot].lastLosTime = GetGameTime();
    // Frozen from the start unless following is on: see l4d_ping_follow.
    g_Pings[slot].frozen      = !g_cvFollow.BoolValue;
    GetKindColor(kind, g_Pings[slot].color);
    strcopy(g_Pings[slot].label, sizeof PingData::label, label);

    g_Pings[slot].markerRef = SpawnMarker(slot, pos, g_Pings[slot].color, team);
    return slot;
}

// Spawn the ping marker: one shared info_target anchor plus ONE env_sprite per
// teammate, each transmitted only to its owner. Returns the anchor's reference
// and fills g_Pings[slot].viewerSprite[].
//
// Why per-viewer: m_flSpriteScale is networked with a single value for every
// client, so a shared sprite can only be sized correctly for one viewer. The
// old code scaled to whoever was nearest, which made the marker tiny for
// everyone else the moment one teammate stood next to it.
int SpawnMarker(int slot, const float pos[3], const int color[4], int team)
{
    for (int c = 0; c <= MaxClients; c++)
        g_Pings[slot].viewerSprite[c] = INVALID_ENT_REFERENCE;

    // Anchor: parenting the sprites to an info_target makes SetTransmit reliable
    // and lets an enemy-follow move all sprites by moving one entity.
    int anchor = CreateEntityByName("info_target");
    if (anchor <= 0)
        return INVALID_ENT_REFERENCE;
    DispatchKeyValue(anchor, "targetname", MARKER_TARGETNAME);
    DispatchSpawn(anchor);
    TeleportEntity(anchor, pos, NULL_VECTOR, NULL_VECTOR);
    g_MarkerTeam[anchor] = team;
    g_MarkerViewer[anchor] = 0;          // anchor goes to the whole team
    SDKHook(anchor, SDKHook_SetTransmit, Hook_MarkerTransmit);

    if (!IsModelPrecached(MARKER_SPRITE))
        PrecacheModel(MARKER_SPRITE, true);

    char col[32];
    Format(col, sizeof col, "%d %d %d", color[0], color[1], color[2]);

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || IsFakeClient(c) || GetClientTeam(c) != team)
            continue;

        int spr = CreateEntityByName("env_sprite");
        if (spr <= 0)
            continue;

        DispatchKeyValue(spr, "targetname", MARKER_TARGETNAME);
        DispatchKeyValue(spr, "spawnflags", "1");        // start visible
        DispatchKeyValue(spr, "model", MARKER_SPRITE);
        DispatchKeyValue(spr, "rendercolor", col);       // must precede renderamt
        DispatchKeyValue(spr, "renderamt", "255");
        DispatchKeyValue(spr, "scale", "0.5");
        DispatchKeyValue(spr, "fademindist", "-1");
        TeleportEntity(spr, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(spr);

        g_MarkerTeam[spr] = team;
        g_MarkerViewer[spr] = c;         // only this client ever receives it
        SDKHook(spr, SDKHook_SetTransmit, Hook_MarkerTransmit);

        SetVariantString("!activator");
        AcceptEntityInput(spr, "SetParent", anchor, anchor);

        g_Pings[slot].viewerSprite[c] = EntIndexToEntRef(spr);
    }

    return EntIndexToEntRef(anchor);
}

// Scope the marker: per-viewer sprites go to exactly one client, the shared
// anchor goes to the owning team.
public Action Hook_MarkerTransmit(int entity, int client)
{
    if (g_MarkerViewer[entity] != 0)
        return (client == g_MarkerViewer[entity]) ? Plugin_Continue : Plugin_Handled;
    if (g_MarkerTeam[entity] != 0 && GetClientTeam(client) != g_MarkerTeam[entity])
        return Plugin_Handled;
    return Plugin_Continue;
}

// Move a ping's marker to the ping's current position (enemy follow). If the marker
// is parented to the target entity, parenting handles following, so skip the teleport.
void UpdateMarkerPos(int idx)
{
    int ent = EntRefToEntIndex(g_Pings[idx].markerRef);
    if (ent <= MaxClients || !IsValidEntity(ent))
        return;
    if (GetEntPropEnt(ent, Prop_Data, "m_hMoveParent") > 0)
        return;   // parented — follows automatically
    TeleportEntity(ent, g_Pings[idx].pos, NULL_VECTOR, NULL_VECTOR);
}

// Remove a ping's marker entities (glow overlay + host), if any.
void RemoveMarker(int idx)
{
    for (int c = 0; c <= MaxClients; c++)
    {
        int glow = EntRefToEntIndex(g_Pings[idx].viewerSprite[c]);
        if (glow > MaxClients && IsValidEntity(glow))
        {
            g_MarkerTeam[glow] = 0;
            g_MarkerViewer[glow] = 0;
            RemoveEntity(glow);
        }
        g_Pings[idx].viewerSprite[c] = INVALID_ENT_REFERENCE;
    }
    int host = EntRefToEntIndex(g_Pings[idx].markerRef);
    if (host > MaxClients && IsValidEntity(host))
    {
        // Must stay inside this guard: EntRefToEntIndex returns -1 for a stale
        // reference, and g_MarkerViewer[-1] would be an out-of-bounds write.
        g_MarkerTeam[host] = 0;
        g_MarkerViewer[host] = 0;
        RemoveEntity(host);
    }
    g_Pings[idx].markerRef = INVALID_ENT_REFERENCE;
}

// Deactivate a ping and clean up its marker.
void DeactivatePing(int idx)
{
    RemoveMarker(idx);
    g_Pings[idx].active = false;
}

void ClearAllPings()
{
    for (int i = 0; i < MAX_PINGS; i++)
        if (g_Pings[i].active)
            DeactivatePing(i);
}

// Tell each player once per connect how to bind the ping key.
//
// sm_ping is registered for everyone via RegConsoleCmd, but a *bind* is
// client-side and a server cannot push one (cl_restrict_server_commands). So
// without this hint the feature is undiscoverable: a new player has no reason
// to know the command exists. Fires once, a few seconds after they are in game
// so it is not buried by the connect spam.
public void OnClientPutInServer(int client)
{
    if (client <= 0 || IsFakeClient(client) || !g_cvHint.BoolValue)
        return;
    CreateTimer(8.0, Timer_BindHint, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_BindHint(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client) || !g_cvHint.BoolValue)
        return Plugin_Stop;

    char key[32];
    g_cvHintKey.GetString(key, sizeof key);

    PrintToChat(client, "\x04[Ping]\x01 This server has a team ping system.");
    PrintToChat(client, "\x04[Ping]\x01 Bind it once in console: \x05bind %s \"sm_ping\"", key);
    return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
    int userid = GetClientUserId(client);
    for (int i = 0; i < MAX_PINGS; i++)
    {
        if (g_Pings[i].active && g_Pings[i].ownerUserId == userid)
            DeactivatePing(i);
    }
    g_LastPingTime[client] = 0.0;
}

public void Event_RoundReset(Event event, const char[] name, bool dontBroadcast)
{
    ClearAllPings();
}

// Drop a player's pings when they change team. The marker is scoped to the team
// it was made for, so once the owner leaves that team it is a stranded object
// their old teammates keep seeing with nobody able to clear it.
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
        RemovePlayerPings(client);
}


// native int L4DPing_Create(int client, const float pos[3], int kind, int target, const char[] label, bool announce)
//
// A ping as if `client` had made it: same marker, colour, lifetime and team
// scoping as a player's ping. kind is PingKind (0 location, 1 item, 2 weapon,
// 3 enemy); target, when > 0, is the entity an enemy ping is about. announce
// plays the ping sound and chat line to the team like a real ping. Returns
// the ping slot or -1. The cooldown and per-player limit do not apply: the
// calling plugin paces itself.
public int Native_Create(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (!g_cvEnable.BoolValue || client <= 0 || client > MaxClients || !IsClientInGame(client))
        return -1;
    float pos[3];
    GetNativeArray(2, pos, sizeof pos);
    PingKind kind = view_as<PingKind>(GetNativeCell(3));
    int target = GetNativeCell(4);
    char label[64];
    GetNativeString(5, label, sizeof label);
    bool announce = GetNativeCell(6);
    if (target > 0 && !IsValidEntity(target))
        target = 0;
    int slot = CreatePing(client, pos, kind, target, label);
    if (slot != -1 && announce)
        AnnouncePing(client, kind, label);
    return slot;
}
