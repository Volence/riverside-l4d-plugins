#if defined _l4d_ping_included
 #endinput
#endif
#define _l4d_ping_included

#define L4DPING_LOCATION 0
#define L4DPING_ITEM     1
#define L4DPING_WEAPON   2
#define L4DPING_ENEMY    3

/**
 * Drop a ping as if `client` had made it (team-scoped marker, colour by kind).
 * @return ping slot, or -1 when pings are off or it failed.
 */
native int L4DPing_Create(int client, const float pos[3], int kind, int target, const char[] label, bool announce);

/**
 * A player made a ping (after it was created and announced).
 */
forward void L4DPing_OnPing(int client, const float pos[3], int kind, int target);

public SharedPlugin __pl_l4d_ping =
{
	name = "l4d_ping",
	file = "l4d_ping.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d_ping_SetNTVOptional()
{
	MarkNativeAsOptional("L4DPing_Create");
}
#endif
