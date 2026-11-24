#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.2"
#define GAMEDATA "l4d_baseline_keep"

// Fixes a stock L4D1 engine bug that leaves special infected invisible to one survivor.
// Root cause and bench proof: research/anti-esp-2026-11-12/invisible-si-deep-dive-2026-11-15.md
// and baseline-keep-build-2026-11-15.md (engine.so md5 9ee78e2fd274e0639e3aae704f2d7b1f).
//
// CBaseClient::SendSnapshot (0x915f8) sends an uncompressed update whenever it has no delta frame
// for the client's last acked tick, and then also frees the per-client entity baselines. That is
// right when m_nDeltaTick is -1 (the client asked for a full update and freed its own baselines, or
// the slot was just connected, inactivated or cleared). It is wrong when the acked frame merely fell
// out of the frame history (a client that stalled for more than sv_maxclientframes snapshots): the
// client keeps its baselines, the two sides disagree, and an entity that later enters the client's
// snapshot is decoded from a stale per-entity baseline (a stale ghost baseline hides a live infected).
//
// Sites 1 and 2 (SendSnapshot): free the baselines only when m_nDeltaTick == -1.
//   +0x580 (0x91b78), 15 bytes:
//     was  8B 86 EC 00 00 00 89 44 24 28 8B 06 89 34 24
//     now  83 BE EC 00 00 00 FF   cmp dword [esi+0xec],-1
//          0F 85 rel32            jne +0x11b   ; frame missing, client kept its baselines: keep ours
//          EB rel8                jmp +0x5c0   ; -1: release m_pLastSnapshot, FreeBaselines, as stock
//   +0x60D (0x91c05), 5 bytes: the DevMsg whose reason text is no longer formatted on the -1 path
//     was  8B 06 89 34 24
//     now  E9 rel32            jmp +0x11b
//
// Site 3 (1.1, CBaseClient::UpdateAcknowledgedFramecount 0x904ca): after that full update the server
// waits for its ack (m_nForceWaitForTick). If the client acks -1 meanwhile (it forced a full update
// itself: "connection problem" after 4 s without packets, record, cl_fullupdate) and reliable data is
// still pending, stock only sets m_nDeltaTick = -1, which the ack of the awaited tick then overwrites:
// nothing is freed. Stock got away with it because it had freed when it sent the update; with sites 1
// and 2 it must free here.
//   +0x172 (0x9063c), 12 bytes:
//     was  C7 86 EC 00 00 00 FF FF FF FF   mov dword [esi+0xec],-1
//          EB B7                           jmp +0x135
//     now  83 8E EC 00 00 00 FF            or  dword [esi+0xec],-1   ; same store
//          E9 rel32                        jmp +0x81  ; stock "forced immediate" tail: release
//                                                     ; m_pLastSnapshot, FreeBaselines, empty baseline,
//                                                     ; DevMsg, return 1. The wait is left as it is.
//
// Every byte touched, every jump target and the code the patched jumps run through are checked against
// the original first. Any difference: nothing is written. Patch order site 3, 2, 1; restore 1, 2, 3
// (site 3 alone is stock plus a harmless extra free). Restored on l4d_baseline_keep_enable 0 and unload.

#define SITES 3

// patch sites (orig bytes), relative to their function
static const char g_sOrig[SITES][] = {
	"8B86EC000000894424288B06893424",
	"8B06893424",
	"C786EC000000FFFFFFFFEBB7"
};

// code the patched paths jump to or run through, verified before any write (function, offset key, hex)
// SendSnapshot +0x115: je into the block (0F 84 rel32 -> +0x580), +0x11b: resume target,
// +0x58f..+0x60c: the untouched rest of the stock reset block, +0x62f: its jmp back to +0x11b.
// UpdateAcknowledgedFramecount +0x16c: je 0x90529 just before site 3 (site 3 is fall-through only),
// +0x81..+0xfd: the "forced immediate" tail site 3 jumps to, through its ret.
static const char g_sCtxSnapResume[] = "8B83BCFBFFFF";
static const char g_sCtxSnapJe[] = "0F8465040000";
static const char g_sCtxSnapRest[] = "FF501C8B4C2428894C24108944240C8D83C4E7F6FF89442408C7442404800000008D44246C89442428890424E8C90419008B86F800000085C07412890424E81E6D1000C786F8000000000000008B06893424FF9000010000C744240800080000C7442404000000008B8338FBFFFF8B00890424E8096F1000898600010000";
static const char g_sCtxSnapBack[] = "E9E7FAFFFF";
static const char g_sCtxAckJe[] = "0F84EDFEFFFF";
// Valve build 26742533 (2026-11-24, engine.so md5 of sha256 44ba797f...): the same two functions at the same
// addresses, same sites and offsets; only call rel32s (+0x70, callees moved) and GOT-relative .rodata leas (+0x80,
// .rodata grew) inside the context differ. Either build's context is accepted.
static const char g_sCtxSnapRestB26742533[] = "FF501C8B4C2428894C24108944240C8D8344E8F6FF89442408C7442404800000008D44246C89442428890424E8390519008B86F800000085C07412890424E88E6D1000C786F8000000000000008B06893424FF9000010000C744240800080000C7442404000000008B8338FBFFFF8B00890424E8796F1000898600010000";
static const char g_sCtxAckTailB26742533[] = "8B86F800000085C07412890424E8FB831000C786F8000000000000008B06893424FF9000010000C744240800080000C7442404000000008B8338FBFFFF8B00890424E8E68510008986000100008B06893424FF501C8D931DE4F6FF89542408894424048D8388E7F6FF890424E8C444F8FFB80100000083C4105B5E5FC3";
static const char g_sCtxAckTail[] = "8B86F800000085C07412890424E88B831000C786F8000000000000008B06893424FF9000010000C744240800080000C7442404000000008B8338FBFFFF8B00890424E8768510008986000100008B06893424FF501C8D939DE3F6FF89542408894424048D8308E7F6FF890424E8C444F8FFB80100000083C4105B5E5FC3";

int g_iOrig[SITES][16];
int g_iNew[SITES][16];
int g_iLen[SITES];
Address g_pSite[SITES];

Address g_pSnap = Address_Null;
Address g_pAck = Address_Null;
int g_iOffSite1, g_iOffSite2, g_iOffResume, g_iOffFree, g_iOffAckSite, g_iOffAckFree;

bool g_bPatched;
bool g_bBroken;      // bytes were neither original nor ours at some point: never write again
int g_iPatchCount;
int g_iRestoreCount;

ConVar g_hEnable;

public Plugin myinfo =
{
	name = "[L4D1] Baseline Keep",
	author = "Malevolence",
	description = "Engine fix: keep entity baselines on a server-initiated full update (invisible special infected after a client stall).",
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
	CreateConVar("l4d_baseline_keep_version", PLUGIN_VERSION, "Baseline Keep version", FCVAR_DONTRECORD);
	g_hEnable = CreateConVar("l4d_baseline_keep_enable", "1",
		"1: free a client's entity baselines only when it asked for a full update (engine fix). 0: stock engine behaviour.",
		FCVAR_NONE, true, 0.0, true, 1.0);

	GameData gd = new GameData(GAMEDATA);
	if( gd == null ) SetFailState("Missing gamedata \"%s\"", GAMEDATA);
	g_pSnap = gd.GetAddress("SendSnapshot");
	g_pAck = gd.GetAddress("UpdateAcknowledgedFramecount");
	g_iOffSite1 = gd.GetOffset("site_free_check");
	g_iOffSite2 = gd.GetOffset("site_devmsg");
	g_iOffResume = gd.GetOffset("target_resume");
	g_iOffFree = gd.GetOffset("target_free");
	g_iOffAckSite = gd.GetOffset("site_ack_wait");
	g_iOffAckFree = gd.GetOffset("target_ack_free");
	delete gd;

	if( g_pSnap == Address_Null ) SetFailState("Could not find CBaseClient::SendSnapshot");
	if( g_pAck == Address_Null ) SetFailState("Could not find CBaseClient::UpdateAcknowledgedFramecount");
	if( g_iOffSite1 <= 0 || g_iOffSite2 <= 0 || g_iOffResume <= 0 || g_iOffFree <= 0 || g_iOffAckSite <= 0 || g_iOffAckFree <= 0 )
		SetFailState("Missing or bad offsets in gamedata \"%s\"", GAMEDATA);

	g_pSite[0] = g_pSnap + view_as<Address>(g_iOffSite1);
	g_pSite[1] = g_pSnap + view_as<Address>(g_iOffSite2);
	g_pSite[2] = g_pAck + view_as<Address>(g_iOffAckSite);
	for( int s = 0; s < SITES; s++ ) g_iLen[s] = ParseHex(g_sOrig[s], g_iOrig[s]);

	BuildPatch();

	char why[160];
	if( !CheckLayout(why, sizeof(why)) )
	{
		g_bBroken = true;
		SetFailState("Engine code differs from the expected build (%s); not patching. Check engine.so md5 (expected 9ee78e2fd274e0639e3aae704f2d7b1f, or Valve build 26742533).", why);
	}

	// A previous copy left its patch in place (should not happen: OnPluginEnd restores). Own it.
	if( AllSitesAre(true) )
	{
		g_bPatched = true;
		LogMessage("The engine already carries this patch; taking ownership.");
	}

	g_hEnable.AddChangeHook(OnEnableChanged);
	Apply(g_hEnable.BoolValue);

	RegAdminCmd("sm_baselinekeep_status", Cmd_Status, ADMFLAG_RCON, "Show the l4d_baseline_keep engine patch state");
}

public void OnPluginEnd()
{
	if( g_bPatched ) Unpatch();
}

void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Apply(convar.BoolValue);
}

void Apply(bool on)
{
	if( on ) Patch();
	else Unpatch();
}

void BuildPatch()
{
	// site 1: cmp dword [esi+0xec],-1 ; jne rel32 -> resume ; jmp rel8 -> free path
	int n[] = { 0x83,0xBE,0xEC,0x00,0x00,0x00,0xFF, 0x0F,0x85 };
	for( int i = 0; i < sizeof(n); i++ ) g_iNew[0][i] = n[i];
	PutInt32(g_iNew[0], 9, g_iOffResume - (g_iOffSite1 + 13));
	g_iNew[0][13] = 0xEB;
	g_iNew[0][14] = (g_iOffFree - (g_iOffSite1 + 15)) & 0xFF;

	// site 2: jmp rel32 -> resume
	g_iNew[1][0] = 0xE9;
	PutInt32(g_iNew[1], 1, g_iOffResume - (g_iOffSite2 + 5));

	// site 3: or dword [esi+0xec],-1 ; jmp rel32 -> forced-immediate tail
	int m[] = { 0x83,0x8E,0xEC,0x00,0x00,0x00,0xFF, 0xE9 };
	for( int i = 0; i < sizeof(m); i++ ) g_iNew[2][i] = m[i];
	PutInt32(g_iNew[2], 8, g_iOffAckFree - (g_iOffAckSite + 12));
}

void PutInt32(int[] buf, int at, int value)
{
	buf[at]     = value & 0xFF;
	buf[at + 1] = (value >> 8) & 0xFF;
	buf[at + 2] = (value >> 16) & 0xFF;
	buf[at + 3] = (value >>> 24) & 0xFF;
}

int ParseHex(const char[] hex, int[] out)
{
	int n = strlen(hex) / 2;
	for( int i = 0; i < n; i++ )
	{
		char b[3];
		b[0] = hex[i * 2]; b[1] = hex[i * 2 + 1]; b[2] = '\0';
		out[i] = StringToInt(b, 16);
	}
	return n;
}

bool MatchHex(Address p, const char[] hex)
{
	int n = strlen(hex) / 2;
	for( int i = 0; i < n; i++ )
	{
		char b[3];
		b[0] = hex[i * 2]; b[1] = hex[i * 2 + 1]; b[2] = '\0';
		if( Byte(p + view_as<Address>(i)) != StringToInt(b, 16) ) return false;
	}
	return true;
}

bool CheckLayout(char[] why, int maxlen)
{
	int rel8 = g_iOffFree - (g_iOffSite1 + 15);
	if( rel8 < 0 || rel8 > 127 ) { FormatEx(why, maxlen, "free target out of rel8 range (%d)", rel8); return false; }

	// SendSnapshot: the je into the block (6 bytes before the resume target) must land on site 1
	Address je = g_pSnap + view_as<Address>(g_iOffResume - 6);
	if( !MatchHex(je, g_sCtxSnapJe) || g_iOffResume + 0x465 != g_iOffSite1 )
		{ strcopy(why, maxlen, "SendSnapshot je into the block"); return false; }
	if( !MatchHex(g_pSnap + view_as<Address>(g_iOffResume), g_sCtxSnapResume) )
		{ strcopy(why, maxlen, "SendSnapshot resume target"); return false; }
	// the rest of the stock block from the end of site 1 up to site 2 (the -1 path runs through it),
	// which starts with the free target
	if( g_iOffSite1 + 15 + strlen(g_sCtxSnapRest) / 2 != g_iOffSite2 || g_iOffFree != g_iOffSite1 + 15 + 0x31
		|| !(MatchHex(g_pSnap + view_as<Address>(g_iOffSite1 + 15), g_sCtxSnapRest)
			|| MatchHex(g_pSnap + view_as<Address>(g_iOffSite1 + 15), g_sCtxSnapRestB26742533)) )
		{ strcopy(why, maxlen, "SendSnapshot reset block"); return false; }
	if( !MatchHex(g_pSnap + view_as<Address>(g_iOffSite2 + 0x22), g_sCtxSnapBack) )
		{ strcopy(why, maxlen, "SendSnapshot jmp back"); return false; }

	// UpdateAcknowledgedFramecount: site 3 is reached only by falling through the je before it; the
	// target is the stock forced-immediate tail, verified through its ret
	if( !MatchHex(g_pAck + view_as<Address>(g_iOffAckSite - 6), g_sCtxAckJe) )
		{ strcopy(why, maxlen, "UpdateAcknowledgedFramecount je before site 3"); return false; }
	if( !MatchHex(g_pAck + view_as<Address>(g_iOffAckFree), g_sCtxAckTail)
		&& !MatchHex(g_pAck + view_as<Address>(g_iOffAckFree), g_sCtxAckTailB26742533) )
		{ strcopy(why, maxlen, "UpdateAcknowledgedFramecount reset tail"); return false; }

	if( AllSitesAre(false) || AllSitesAre(true) ) return true;
	char st[SITES][12];
	for( int s = 0; s < SITES; s++ ) SiteState(s, st[s], sizeof(st[]));
	FormatEx(why, maxlen, "site bytes: 1 %s, 2 %s, 3 %s", st[0], st[1], st[2]);
	return false;
}

bool SiteIs(int s, bool patched)
{
	for( int i = 0; i < g_iLen[s]; i++ )
	{
		if( Byte(g_pSite[s] + view_as<Address>(i)) != (patched ? g_iNew[s][i] : g_iOrig[s][i]) ) return false;
	}
	return true;
}

bool AllSitesAre(bool patched)
{
	for( int s = 0; s < SITES; s++ ) if( !SiteIs(s, patched) ) return false;
	return true;
}

void SiteState(int s, char[] out, int maxlen)
{
	if( SiteIs(s, false) ) strcopy(out, maxlen, "original");
	else if( SiteIs(s, true) ) strcopy(out, maxlen, "patched");
	else strcopy(out, maxlen, "UNKNOWN");
}

void Patch()
{
	if( g_bPatched || g_bBroken ) return;
	if( !AllSitesAre(false) )
	{
		g_bBroken = true;
		LogError("Engine bytes changed since load (another patch?); NOT patching, plugin inert.");
		return;
	}
	for( int s = SITES - 1; s >= 0; s-- ) WriteSite(s, true);
	g_bPatched = true;
	g_iPatchCount++;
	LogMessage("Patched CBaseClient::SendSnapshot (%X) and UpdateAcknowledgedFramecount (%X): entity baselines are freed only when the client asked for a full update.", g_pSnap, g_pAck);
}

void Unpatch()
{
	if( !g_bPatched ) return;
	if( !AllSitesAre(true) )
	{
		g_bBroken = true;
		g_bPatched = false;
		LogError("The engine no longer holds this plugin's patch (someone else wrote there); NOT restoring.");
		return;
	}
	for( int s = 0; s < SITES; s++ ) WriteSite(s, false);
	g_bPatched = false;
	g_iRestoreCount++;
	LogMessage("Restored the original engine bytes (stock behaviour).");
}

void WriteSite(int s, bool patched)
{
	for( int i = 0; i < g_iLen[s]; i++ )
	{
		StoreToAddress(g_pSite[s] + view_as<Address>(i), patched ? g_iNew[s][i] : g_iOrig[s][i], NumberType_Int8);
	}
}

Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "[baseline_keep] %s | enable %d | patched %d | broken %d | applied %d restored %d",
		PLUGIN_VERSION, g_hEnable.IntValue, g_bPatched, g_bBroken, g_iPatchCount, g_iRestoreCount);
	static const char names[SITES][] = { "SendSnapshot+0x%X", "SendSnapshot+0x%X", "UpdateAckFramecount+0x%X" };
	int offs[SITES];
	offs[0] = g_iOffSite1; offs[1] = g_iOffSite2; offs[2] = g_iOffAckSite;
	for( int s = 0; s < SITES; s++ )
	{
		char where[48], hex[40], st[12];
		FormatEx(where, sizeof(where), names[s], offs[s]);
		hex[0] = '\0';
		for( int i = 0; i < g_iLen[s]; i++ ) Format(hex, sizeof(hex), "%s%02X", hex, Byte(g_pSite[s] + view_as<Address>(i)));
		SiteState(s, st, sizeof(st));
		ReplyToCommand(client, "[baseline_keep] %s (%X): %s (%s)", where, g_pSite[s], hex, st);
	}
	return Plugin_Handled;
}

int Byte(Address p)
{
	return LoadFromAddress(p, NumberType_Int8) & 0xFF;
}
