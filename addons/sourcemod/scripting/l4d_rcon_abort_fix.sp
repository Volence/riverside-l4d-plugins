// l4d_rcon_abort_fix: stops one RCON connection's close from stranding another connection's requests.
//
// Stock L4D1 engine bug (R1 in the engine rebuild's docs/engine/rcon.md, engine.so sha256 0d3f61c2...):
// CRConServer::RunFrame clears a "socket closed" byte at this+0x5c once per frame (0x1ae1c3),
// CRConServer::OnSocketClosed sets it on ANY close, and after each request (0x1ae972) RunFrame
// leaves the whole frame if it is set, without consuming the request. A close of a newer
// connection earlier in the same frame therefore strands an older connection's buffered requests:
// they wait for new bytes, then the first one runs a second time. Seen in production as
// "rcon exec timeout" when two rcon jobs overlapped on one server.
//
// The fix clears the byte right before every request. The byte exists to stop RunFrame touching a
// socket that the request itself closed (an rcon_password change, a failed send to the requester);
// during a request only the requester's own socket, or all of them, can close, so that protection
// stays and only the false positive goes.
//
// Where it hooks: SV_RedirectStart, whose ONLY caller is RunFrame (0x1ae92c), immediately before
// CServerRemoteAccess::WriteDataRequest (0x1ae962) with nothing but argument setup between them.
// The 0.1 test build hooked WriteDataRequest itself, but every rcon command runs INSIDE that
// function, so unloading the plugin from an rcon command freed code the engine was about to return
// through and crashed the server. SV_RedirectStart has already returned when the command runs, so
// loading, unloading and reloading over rcon are safe.
//
// Fails safe: the plugin checks that the engine.so code is the build it was written for (the two
// instructions that use the byte, and that the two calls above are where they should be). If
// anything differs it logs why and attaches nothing, and the server runs stock RCON.
//
// Does NOT fix: the double close after a failed send (R2), the listener leak, the 1 KB request cap.
// rcon_password re-sets closing every connection (R3) is l4d_rcon_password_fix.
#include <sourcemod>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"
#define TAG "[l4d_rcon_abort_fix]"
#define RD_SOCKET 3

public Plugin myinfo =
{
	name = "L4D RCON abort fix",
	author = "Malevolence",
	description = "Stops one RCON connection's close from stranding another connection's requests",
	version = PLUGIN_VERSION,
	url = ""
};

Address g_pClosedFlag;   // &g_RCONServer + 0x5c

public void OnPluginStart()
{
	GameData gd = new GameData("l4d_rcon_abort_fix.games");
	if (gd == null)
		SetFailState("gamedata l4d_rcon_abort_fix.games missing; not attached, RCON runs stock");
	char why[160];
	if (!CheckEngine(gd, why, sizeof(why)))
	{
		delete gd;
		SetFailState("%s; not attached, RCON runs stock", why);
	}
	DynamicDetour d = DynamicDetour.FromConf(gd, "SV_RedirectStart");
	delete gd;
	if (d == null || !d.Enable(Hook_Pre, Detour_RedirectStart))
		SetFailState("could not detour SV_RedirectStart; not attached, RCON runs stock");

	CreateConVar("l4d_rcon_abort_fix_version", PLUGIN_VERSION, "L4D RCON abort fix version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	LogMessage("%s %s attached", TAG, PLUGIN_VERSION);
}

bool CheckEngine(GameData gd, char[] why, int maxlen)
{
	int off = gd.GetOffset("CRConServer::m_bSocketClosedThisFrame");
	int atClear = gd.GetOffset("RunFrame_ClearFlag");     // movb $0x0,0x5c(%esi)   c6 46 5c 00
	int atTest = gd.GetOffset("RunFrame_TestFlag");       // cmpb $0x0,0x5c(%eax)   80 78 5c 00
	int atRedirect = gd.GetOffset("RunFrame_CallRedirectStart");
	int atRequest = gd.GetOffset("RunFrame_CallWriteDataRequest");
	if (off <= 0 || off > 0x7f || atClear <= 0 || atTest <= 0 || atRedirect <= 0 || atRequest <= atRedirect)
	{
		strcopy(why, maxlen, "gamedata offsets missing or invalid");
		return false;
	}
	Address runFrame = gd.GetAddress("CRConServer::RunFrame");
	Address redirect = gd.GetAddress("SV_RedirectStart");
	Address request = gd.GetAddress("CServerRemoteAccess::WriteDataRequest");
	Address server = gd.GetAddress("g_RCONServer");
	if (runFrame == Address_Null || redirect == Address_Null || request == Address_Null || server == Address_Null)
	{
		strcopy(why, maxlen, "an engine.so symbol was not found");
		return false;
	}
	if (!Bytes4(runFrame + view_as<Address>(atClear), 0xc6, 0x46, off, 0x00)
		|| !Bytes4(runFrame + view_as<Address>(atTest), 0x80, 0x78, off, 0x00))
	{
		strcopy(why, maxlen, "CRConServer::RunFrame does not use the closed flag where expected (different engine.so)");
		return false;
	}
	if (CallTarget(runFrame + view_as<Address>(atRedirect)) != redirect
		|| CallTarget(runFrame + view_as<Address>(atRequest)) != request)
	{
		strcopy(why, maxlen, "CRConServer::RunFrame does not call SV_RedirectStart then WriteDataRequest where expected");
		return false;
	}
	g_pClosedFlag = server + view_as<Address>(off);
	return true;
}

bool Bytes4(Address a, int b0, int b1, int b2, int b3)
{
	return LoadFromAddress(a, NumberType_Int8) == b0
		&& LoadFromAddress(a + view_as<Address>(1), NumberType_Int8) == b1
		&& LoadFromAddress(a + view_as<Address>(2), NumberType_Int8) == b2
		&& LoadFromAddress(a + view_as<Address>(3), NumberType_Int8) == b3;
}

// Target of an `e8 rel32` call at a, or Address_Null if a is not one.
Address CallTarget(Address a)
{
	if (LoadFromAddress(a, NumberType_Int8) != 0xe8)
		return Address_Null;
	int rel = LoadFromAddress(a + view_as<Address>(1), NumberType_Int32);
	return a + view_as<Address>(5 + rel);
}

// void SV_RedirectStart(redirect_t target, const netadr_t *addr): RunFrame calls it with
// RD_SOCKET right before running one rcon request.
public MRESReturn Detour_RedirectStart(DHookParam hParams)
{
	if (hParams.Get(1) == RD_SOCKET)
		StoreToAddress(g_pClosedFlag, 0, NumberType_Int8);
	return MRES_Ignored;
}
